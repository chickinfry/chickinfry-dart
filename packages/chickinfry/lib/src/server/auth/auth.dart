import 'dart:convert';

import 'package:pointycastle/digests/sha256.dart';

import '../../errors.dart';
import '../application.dart';
import '../database.dart' show DatabaseConnection, DatabaseError, Filter, Value;
import 'email.dart';
import 'password.dart';
import 'policy.dart';
import 'private/database.dart';

part 'cleanup.dart';

final class Authentication {
  Authentication(
    this._connection,
    this._policy, {
    this.userCreating,
    this.userCreated,
  }) : _db = Database(_connection);

  final DatabaseConnection _connection;
  final Database _db;
  final SessionPolicy _policy;
  final Future<void> Function(DatabaseConnection, AuthUser)? userCreating;
  final Future<void> Function(AuthUser)? userCreated;

  static Never _fail(String code, int status) =>
      throw OperationError(code, status);

  static String _timestamp(DateTime time) {
    final iso = time.toUtc().toIso8601String();
    return iso.length == 24 ? '${iso.substring(0, 23)}000Z' : iso;
  }

  static String _digest(String value) =>
      hexBytes(SHA256Digest().process(utf8.encode(value)));
  static String _token() => base64Url.encode(randomBytes(32)).substring(0, 43);

  static bool _validToken(String token) {
    if (token.length != 43) return false;
    try {
      final decoded = base64Url.decode('$token=');
      return decoded.length == 32 && base64Url.encode(decoded) == '$token=';
    } on FormatException {
      return false;
    }
  }

  Future<void> _rateLimit(String action, String email) async {
    final key = AppAuthRateLimitsPrimaryKey(
      action: action,
      keyHash: _digest(email),
    );
    final repo = _db.appAuthRateLimits;
    for (var attempt = 0; attempt < 4; attempt++) {
      final row = await repo.findById(key);
      final now = DateTime.now();
      final cutoff = _timestamp(now.add(const Duration(minutes: 15)));
      if (row == null) {
        try {
          await repo.insert(
            AppAuthRateLimitsInsert(
              action: action,
              keyHash: key.keyHash,
              attemptCount: 1,
              expiresAt: cutoff,
            ),
          );
          return;
        } on DatabaseError catch (error) {
          if (error.code != '23505') rethrow;
          continue;
        }
      }
      final expired = !DateTime.parse(row.expiresAt).isAfter(now);
      if (!expired && row.attemptCount >= 10) _fail('rate_limited', 429);
      final updated = await repo.updateIf(
        key,
        (columns) => Filter.and([
          columns.attemptCount.eq(row.attemptCount),
          columns.expiresAt.eq(row.expiresAt),
        ]),
        AppAuthRateLimitsUpdate(
          attemptCount: Value(expired ? 1 : row.attemptCount + 1),
          expiresAt: Value(expired ? cutoff : row.expiresAt),
        ),
      );
      if (updated != null) return;
    }
    _fail('rate_limited', 429);
  }

  static Map<String, Object?> _tokens(
    String access,
    String refresh,
    AppAuthSessionsRow session,
    String familyExpiry,
  ) => {
    'access_token': access,
    'refresh_token': refresh,
    'expires_at': session.expiresAt,
    'refresh_expires_at': familyExpiry,
    'user_id': session.userId,
    'session_id': session.id,
  };

  Future<Map<String, Object?>> _issue(Database db, AppAuthUsersRow user) async {
    final access = _token();
    final refresh = _token();
    final now = DateTime.now();
    final issued = _timestamp(now);
    final (accessExpiry, familyExpiry) = _policy.expirations(now, now);
    final session = await db.appAuthSessions.insert(
      AppAuthSessionsInsert(
        userId: user.id,
        tokenHash: _digest(access),
        userSessionVersion: user.sessionVersion,
        expiresAt: _timestamp(accessExpiry),
        transport: const Value('native'),
        createdAt: Value(issued),
        firstLoginAt: Value(issued),
        lastRenewedAt: Value(issued),
      ),
    );
    final credential = await db.appAuthRefreshTokens.insert(
      AppAuthRefreshTokensInsert(
        sessionId: session.id,
        tokenHash: _digest(refresh),
        expiresAt: _timestamp(familyExpiry),
        createdAt: Value(issued),
      ),
    );
    return _tokens(access, refresh, session, credential.expiresAt);
  }

  Future<Map<String, Object?>> _signup(String email, String password) async {
    await _rateLimit('signup', email);
    final encoded = hashPassword(password);
    late AuthUser public;
    final result = await _connection.transaction((connection) async {
      final db = Database(connection);
      final AppAuthUsersRow user;
      try {
        user = await db.appAuthUsers.insert(
          AppAuthUsersInsert(email: email, passwordHash: Value(encoded)),
        );
      } on DatabaseError catch (error) {
        if (error.code != '23505') rethrow;
        _fail('account_exists', 409);
      }
      public = AuthUser(user.id, user.email, user.createdAt);
      try {
        await userCreating?.call(connection, public);
      } catch (_) {
        _fail('user_creation_failed', 500);
      }
      return _issue(db, user);
    });
    try {
      await userCreated?.call(public);
    } catch (_) {
      _fail('user_created_effect_failed', 500);
    }
    return result;
  }

  Future<Map<String, Object?>> _signin(String email, String password) async {
    await _rateLimit('signin', email);
    final users = await _db.appAuthUsers.findMany(
      where: (c) => c.email.eq(email),
      limit: 1,
    );
    final user = users.firstOrNull;
    if (!verifyPassword(password, user?.passwordHash) ||
        user == null ||
        user.disabledAt != null) {
      _fail('invalid_credentials', 401);
    }
    return _db.transaction((db) => _issue(db, user));
  }

  static Future<AppAuthRefreshTokensRow?> _latest(
    Database db,
    String sessionId,
  ) async => (await db.appAuthRefreshTokens.findMany(
    where: (c) => c.sessionId.eq(sessionId),
    orderBy: (c) => [c.createdAt.desc(), c.id.desc()],
    limit: 1,
  )).firstOrNull;

  static bool _activeUser(AppAuthUsersRow? user, AppAuthSessionsRow session) =>
      user != null &&
      user.disabledAt == null &&
      user.sessionVersion == session.userSessionVersion;

  DateTime? _familyExpiry(
    DateTime now,
    AppAuthSessionsRow session,
    AppAuthRefreshTokensRow? latest,
  ) {
    if (session.revokedAt != null ||
        session.transport != 'native' ||
        latest == null) {
      return null;
    }
    return _policy.familyExpiry(
      now,
      DateTime.parse(session.firstLoginAt ?? session.createdAt),
      DateTime.parse(session.lastRenewedAt ?? latest.createdAt),
      DateTime.parse(latest.expiresAt),
    );
  }

  Future<({Session session, String expiresAt})?> _endpointSession(
    String? authorization,
  ) async {
    if (authorization == null) return null;
    if (!authorization.startsWith('Bearer ') ||
        !_validToken(authorization.substring(7))) {
      _fail('invalid_token', 401);
    }
    final hash = _digest(authorization.substring(7));
    final rows = await _db.appAuthSessions.findMany(
      where: (c) => c.tokenHash.eq(hash),
      limit: 1,
    );
    final candidate = rows.firstOrNull;
    if (candidate == null ||
        candidate.revokedAt != null ||
        candidate.transport != 'native') {
      _fail('invalid_token', 401);
    }
    final key = AppAuthSessionsPrimaryKey(id: candidate.id);
    final session = await _db.transaction((db) async {
      final sessions = db.appAuthSessions;
      final locked = await sessions.updateIf(
        key,
        (c) => Filter.and([c.revokedAt.isNull(), c.tokenHash.eq(hash)]),
        const AppAuthSessionsUpdate(revokedAt: Value(null)),
      );
      if (locked == null) return null;
      final now = DateTime.now();
      final familyExpiry = _familyExpiry(
        now,
        locked,
        await _latest(db, locked.id),
      );
      if (familyExpiry == null) {
        await sessions.update(
          key,
          AppAuthSessionsUpdate(revokedAt: Value(_timestamp(now))),
        );
        return null;
      }
      final accessExpiry = DateTime.parse(locked.expiresAt);
      if (!accessExpiry.isAfter(now)) return null;
      final user = await db.appAuthUsers.findById(
        AppAuthUsersPrimaryKey(id: locked.userId),
      );
      if (!_activeUser(user, locked)) return null;
      return (
        session: Session(locked.id, SessionUser(user!.id, user.email)),
        expiresAt: _timestamp(
          accessExpiry.isBefore(familyExpiry) ? accessExpiry : familyExpiry,
        ),
      );
    });
    return session ?? _fail('invalid_token', 401);
  }

  Future<Map<String, Object?>> _refresh(String token) async {
    if (!_validToken(token)) _fail('invalid_token', 401);
    final rows = await _db.appAuthRefreshTokens.findMany(
      where: (c) => c.tokenHash.eq(_digest(token)),
      limit: 1,
    );
    final candidate = rows.firstOrNull ?? _fail('invalid_token', 401);
    final sessionKey = AppAuthSessionsPrimaryKey(id: candidate.sessionId);
    final refreshKey = AppAuthRefreshTokensPrimaryKey(id: candidate.id);

    final result = await _db.transaction((db) async {
      final sessions = db.appAuthSessions;
      final credentials = db.appAuthRefreshTokens;
      final session = await sessions.updateIf(
        sessionKey,
        (c) => c.revokedAt.isNull(),
        const AppAuthSessionsUpdate(revokedAt: Value(null)),
      );
      if (session == null || session.transport != 'native') return null;
      final now = DateTime.now();
      final issued = _timestamp(now);
      final current = await credentials.findById(refreshKey);
      final user = await db.appAuthUsers.findById(
        AppAuthUsersPrimaryKey(id: session.userId),
      );
      final latest = await _latest(db, session.id);
      if (_familyExpiry(now, session, latest) == null ||
          current == null ||
          current.consumedAt != null ||
          !_activeUser(user, session) ||
          await credentials.updateIf(
                refreshKey,
                (c) => c.consumedAt.isNull(),
                AppAuthRefreshTokensUpdate(consumedAt: Value(issued)),
              ) ==
              null) {
        // Commit revocation before reporting expiry or reuse to the caller.
        await sessions.update(
          sessionKey,
          AppAuthSessionsUpdate(revokedAt: Value(issued)),
        );
        return null;
      }
      final firstLogin = DateTime.parse(
        session.firstLoginAt ?? session.createdAt,
      );
      final (accessExpiry, familyExpiry) = _policy.expirations(now, firstLogin);
      final access = _token();
      final refresh = _token();
      final updated = await sessions.update(
        sessionKey,
        AppAuthSessionsUpdate(
          tokenHash: Value(_digest(access)),
          expiresAt: Value(_timestamp(accessExpiry)),
          firstLoginAt: session.firstLoginAt == null
              ? Value(_timestamp(firstLogin))
              : const Value.absent(),
          lastRenewedAt: Value(issued),
        ),
      );
      final issuedCredential = await credentials.insert(
        AppAuthRefreshTokensInsert(
          sessionId: session.id,
          tokenHash: _digest(refresh),
          expiresAt: _timestamp(familyExpiry),
          createdAt: Value(issued),
        ),
      );
      return _tokens(access, refresh, updated, issuedCredential.expiresAt);
    });
    return result ?? _fail('session_revoked', 401);
  }

  /// Dispatches a selected built-in native authentication operation.
  Future<Map<String, Object?>> handle(
    String operation,
    Context context,
    Map<String, Object?> input,
  ) async {
    void require(List<String> fields) {
      if (input.length != fields.length ||
          fields.any((name) => input[name] is! String)) {
        _fail('invalid_input', 400);
      }
    }

    final Map<String, Object?> result;
    switch (operation) {
      case 'auth.signup':
      case 'auth.signin':
        require(const ['email', 'password']);
        final email = normalizeEmail(input['email'] as String);
        final password = input['password'] as String;
        validatePassword(password);
        result = await (operation == 'auth.signup'
            ? _signup(email, password)
            : _signin(email, password));
      case 'auth.refresh':
        require(const ['refresh_token']);
        result = await _refresh(input['refresh_token'] as String);
      case 'auth.identity':
        require(const ['provider', 'credential']);
        _fail('unsupported_identity_provider', 400);
      case 'auth.session':
      case 'auth.logout':
        require(const []);
        final active =
            await _endpointSession(context.request.headers['authorization']) ??
            _fail('unauthenticated', 401);
        if (operation == 'auth.session') {
          return {
            'id': active.session.user.id,
            'email': active.session.user.email,
            'session_id': active.session.id,
            'expires_at': active.expiresAt,
          };
        }
        await _db.appAuthSessions.updateIf(
          AppAuthSessionsPrimaryKey(id: active.session.id),
          (c) => c.revokedAt.isNull(),
          AppAuthSessionsUpdate(revokedAt: Value(_timestamp(DateTime.now()))),
        );
        return {'status': 'signed_out'};
      default:
        _fail('not_found', 404);
    }
    try {
      await _cleanup(DateTime.now(), result['session_id'] as String);
    } catch (_) {
      await context.log('warn', 'Authentication cleanup failed.');
    }
    return result;
  }
}
