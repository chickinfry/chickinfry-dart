import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'database.dart';
import 'secrets.dart';
import 'storage.dart';
import 'vault.dart';

/// Immutable request metadata excluding hop-by-hop proxy credentials.
final class ServerRequest {
  ServerRequest({
    required this.method,
    required this.uri,
    required Map<String, String> headers,
  }) : headers = Map.unmodifiable({
         // Proxy credentials are hop-by-hop (RFC 9110 11.7.2) and must not reach handlers.
         for (final entry in headers.entries)
           if (entry.key.toLowerCase() != 'proxy-authorization')
             entry.key.toLowerCase(): entry.value,
       });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
}

/// Request context for an application without selected resources.
class Context {
  final ServerRequest request;

  Context(this.request, [ContextLog? log]) : _log = log;

  final ContextLog? _log;

  /// Emits a request-scoped log line through the platform redaction pipeline.
  ///
  /// Logging failures never fail the operation; without a platform binding
  /// (plain tests) the call is dropped. Unknown levels and non-JSON field
  /// values discard the whole record.
  Future<void> log(
    String level,
    String message, [
    Map<String, Object?>? fields,
  ]) async {
    if (!const ['debug', 'info', 'warn', 'error'].contains(level)) return;
    final log = _log;
    if (log == null) return;
    try {
      if (fields != null && !_jsonValue(fields, 1)) return;
      await log(level, message, fields);
    } catch (_) {}
  }

  static bool _jsonValue(Object? value, int depth) {
    if (depth > 64) return false;
    if (value == null || value is bool || value is String) return true;
    if (value is num) return value.isFinite && value.abs() <= 9007199254740991;
    if (value is Map<String, Object?>) {
      return value.values.every((item) => _jsonValue(item, depth + 1));
    }
    if (value is List<Object?>) {
      return value.every((item) => _jsonValue(item, depth + 1));
    }
    return false;
  }
}

/// A business request carrying the host's verified session.
final class AuthenticatedContext<T extends Session?> extends Context {
  AuthenticatedContext._(Context base, T session)
    : auth = (session: session),
      super(base.request, base._log);

  final ({T session}) auth;
}

const _absentHostAuth = Object();

Object? hostAuthFrame(Map<String, Object?> metadata) =>
    metadata.containsKey('auth') ? metadata['auth'] : _absentHostAuth;

Map<String, Object?> decodeHostMetadata(String text) {
  if (text.length > Application.maxRequestBytes ||
      utf8.encode(text).length > Application.maxRequestBytes ||
      Application._validateJson(text) != null) {
    throw const FormatException('Invalid host request metadata.');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Invalid host request metadata.');
  }
  return decoded;
}

/// Forwards one request-scoped log line; level is one of the shared names.
typedef ContextLog = Future<void> Function(
  String level,
  String message,
  Map<String, Object?>? fields,
);

final class ApplicationOptions {
  const ApplicationOptions({this.authHooks});

  final AuthHooks? authHooks;
}

/// Internal response consumed by the platform connection.
final class ServerResponse {
  const ServerResponse(this.status, this.body);
  final int status;
  final String body;
}

/// Executes generated dispatch after validating the shared HTTP boundary.
final class Application {
  Application(
    Map<
      String,
      Future<Map<String, Object?>> Function(Context, Map<String, Object?>)
    >
    operations, {
    this._contextFactory,
    this._setup,
    this._authEnabled = false,
    this._isPublic,
    this._authContextFactory,
  }) : _operations = Map.unmodifiable(operations);

  final Map<
    String,
    Future<Map<String, Object?>> Function(Context, Map<String, Object?>)
  >
  _operations;
  final Context Function(
    ServerRequest,
    DatabaseConnection?,
    SecretValues?,
    ContextLog?,
    Vault?,
    StorageCall?,
  )?
  _contextFactory;
  final Future<ApplicationOptions> Function()? _setup;
  final bool _authEnabled;
  final bool Function(String)? _isPublic;
  final Context Function(Context, Session?, bool)? _authContextFactory;
  Future<ApplicationOptions>? _setupResult;
  static const maxRequestBytes = 4 << 20;
  static final _code = RegExp(r'^[a-z_]{1,64}$');
  static const _statuses = {400, 401, 403, 404, 409, 413, 429, 503};

  /// Called by the platform connection before reporting readiness.
  /// Shares one setup result with [handle], retaining failures without retrying.
  Future<void> prepare({ContextLog? log}) async {
    final setup = _setup;
    if (setup != null) {
      await (_setupResult ??= _capturePrint(log, () async {
        final options = await Future<ApplicationOptions>.sync(setup);
        if (!_authEnabled && options.authHooks != null) {
          throw StateError(
            'Declare auth in auth.yml before registering auth hooks.',
          );
        }
        return options;
      }));
    }
  }

  Future<ServerResponse> handle(
    ServerRequest request,
    Stream<List<int>> body, {
    String? rawUri,
    DatabaseConnection? connection,
    SecretValues? secrets,
    ContextLog? log,
    Vault? vault,
    StorageCall? storage,
    Object? authFrame = _absentHostAuth,
  }) async {
    try {
      try {
        await prepare(log: log);
      } catch (_) {
        return _error('operation_failed', 500);
      }
      final name = request.uri.path.substring(request.uri.path.isEmpty ? 0 : 1);
      final operation = name.startsWith('auth.') ? null : _operations[name];
      if (request.method != 'POST' ||
          request.uri.hasQuery ||
          (rawUri ?? request.uri.toString()).contains('%') ||
          operation == null) {
        return _error('not_found', 404);
      }
      final contentType = request.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != 'application/json') {
        return _error('unsupported_media_type', 415);
      }
      if (!_authEnabled && !identical(authFrame, _absentHostAuth)) {
        return _error('operation_failed', 500);
      }
      final public = _authEnabled && (_isPublic?.call(name) ?? false);
      final session = _authEnabled ? _decodeVerifiedSession(authFrame) : null;
      if (_authEnabled && !public && session == null) {
        return _error('unauthenticated', 401);
      }
      final effectiveRequest = _authEnabled
          ? ServerRequest(
              method: request.method,
              uri: request.uri,
              headers: {
                for (final entry in request.headers.entries)
                  if (entry.key != 'authorization' && entry.key != 'cookie')
                    entry.key: entry.value,
              },
            )
          : request;
      final bytes = BytesBuilder(copy: true);
      final iterator = StreamIterator(body);
      try {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (chunk.length > maxRequestBytes - bytes.length) {
            return _error('request_too_large', 413);
          }
          bytes.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      final Object? input;
      try {
        final source = utf8.decode(bytes.takeBytes());
        final error = _validateJson(source);
        if (error != null) return _error(error, 400);
        input = jsonDecode(source);
      } on FormatException {
        return _error('invalid_json', 400);
      }
      final decoded = input;
      if (decoded is! Map<String, Object?>) {
        return _error('invalid_input', 400);
      }
      final output = await _capturePrint(log, () {
        final base =
            _contextFactory?.call(
              effectiveRequest,
              connection,
              secrets,
              log,
              vault,
              storage,
            ) ??
            Context(effectiveRequest, log);
        final context = !_authEnabled
            ? base
            : _authContextFactory?.call(base, session, public) ??
                  (public
                      ? AuthenticatedContext<Session?>._(base, session)
                      : AuthenticatedContext<Session>._(base, session!));
        return operation(context, decoded);
      });
      return ServerResponse(200, jsonEncode(output));
    } on OperationError catch (error) {
      // Status 501 is reserved for the explicit not_implemented contract.
      if (_code.hasMatch(error.code) &&
          (_statuses.contains(error.status) ||
              (error.status == 501 && error.code == 'not_implemented') ||
              (error.status == 500 &&
                  (error.code == 'user_creation_failed' ||
                      error.code == 'user_created_effect_failed')))) {
        return _error(error.code, error.status);
      }
      return _error('operation_failed', 500);
    } catch (_) {
      return _error('operation_failed', 500);
    }
  }

  /// Called by the host callback entry, outside HTTP dispatch.
  Future<ServerResponse> handleAuthHook(
    Object? frame, {
    DatabaseConnection? connection,
    ContextLog? log,
  }) async {
    final borrowed = connection != null && isBorrowedAuthConnection(connection);
    try {
      if (!_authEnabled) return _error('operation_failed', 500);
      final message = _decodeAuthHook(frame);
      await prepare(log: log);
      final hooks = (await _setupResult)?.authHooks;
      switch (message.kind) {
        case 'userCreating':
          if (!borrowed) return _error('operation_failed', 500);
          try {
            await _capturePrint(log, () async {
              await hooks?.userCreating?.call(connection, message.user);
            });
          } catch (_) {
            return _error('user_creation_failed', 500);
          }
        case 'userCreated':
          if (connection != null) return _error('operation_failed', 500);
          try {
            await _capturePrint(log, () async {
              await hooks?.userCreated?.call(message.user);
            });
          } catch (_) {
            return _error('user_created_effect_failed', 500);
          }
        default:
          return _error('operation_failed', 500);
      }
      return const ServerResponse(200, '{}');
    } catch (_) {
      return _error('operation_failed', 500);
    } finally {
      if (borrowed) connection.close();
    }
  }

  static Future<T> _capturePrint<T>(
    ContextLog? log,
    Future<T> Function() work,
  ) {
    if (log == null) return work();
    return runZoned(
      work,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) {
          unawaited(
            Future<void>.sync(() => log('info', message, null))
                .catchError((Object _) {}),
          );
        },
      ),
    );
  }

  // Check raw values before decoding can discard duplicate object members.
  static String? _validateJson(String source) {
    const value = 0, arrayStart = 1, objectStart = 2;
    const key = 3, colon = 4, afterValue = 5;
    // Each open container needs a closing character, so half the input suffices.
    // The request byte limit bounds this stack to at most 2 MiB.
    final containers = Uint8List(source.length ~/ 2);
    // Key storage is bounded by the body; stop collecting after a structure error.
    final objectKeys = List<Set<String>?>.filled(64, null);
    var invalidInput = false;
    var depth = 0;
    var state = value;
    var index = 0;
    bool at(int unit) =>
        index < source.length && source.codeUnitAt(index) == unit;
    bool digits() {
      final start = index;
      while (index < source.length) {
        final unit = source.codeUnitAt(index);
        if (unit < 0x30 || unit > 0x39) break;
        index++;
      }
      return index > start;
    }

    bool string(bool isKey) {
      final decoded = isKey && !invalidInput ? StringBuffer() : null;
      var highSurrogate = false;
      index++;
      while (index < source.length) {
        var unit = source.codeUnitAt(index++);
        if (unit == 0x22) {
          if (highSurrogate) invalidInput = true;
          if (decoded != null && !invalidInput) {
            if (!objectKeys[depth - 1]!.add(decoded.toString())) {
              invalidInput = true;
            }
          }
          return true;
        }
        if (unit < 0x20) return false;
        if (unit == 0x5c) {
          if (index == source.length) return false;
          final escape = source.codeUnitAt(index++);
          if (escape == 0x75) {
            if (index + 4 > source.length) return false;
            unit = 0;
            for (var digit = 0; digit < 4; digit++) {
              final hex = source.codeUnitAt(index++);
              final value = switch (hex) {
                >= 0x30 && <= 0x39 => hex - 0x30,
                >= 0x41 && <= 0x46 => hex - 0x41 + 10,
                >= 0x61 && <= 0x66 => hex - 0x61 + 10,
                _ => -1,
              };
              if (value < 0) return false;
              unit = unit * 16 + value;
            }
          } else {
            unit = switch (escape) {
              0x22 || 0x5c || 0x2f => escape,
              0x62 => 0x08,
              0x66 => 0x0c,
              0x6e => 0x0a,
              0x72 => 0x0d,
              0x74 => 0x09,
              _ => -1,
            };
            if (unit < 0) return false;
          }
        }
        final lowSurrogate = unit >= 0xdc00 && unit <= 0xdfff;
        if (highSurrogate != lowSurrogate) invalidInput = true;
        highSurrogate = unit >= 0xd800 && unit <= 0xdbff;
        decoded?.writeCharCode(unit);
      }
      return false;
    }

    while (index < source.length) {
      final unit = source.codeUnitAt(index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        index++;
        continue;
      }
      if ((state == arrayStart && unit == 0x5d) ||
          (state == objectStart && unit == 0x7d)) {
        depth--;
        if (depth < 64) objectKeys[depth] = null;
        state = afterValue;
        index++;
        continue;
      }
      if (state == afterValue) {
        if (depth == 0) return 'invalid_json';
        final closing = containers[depth - 1];
        if (unit == closing) {
          depth--;
          if (depth < 64) objectKeys[depth] = null;
        } else if (unit == 0x2c) {
          state = closing == 0x7d ? key : value;
        } else {
          return 'invalid_json';
        }
        index++;
        continue;
      }
      if (state == colon) {
        if (unit != 0x3a) return 'invalid_json';
        state = value;
        index++;
        continue;
      }
      if (unit == 0x22) {
        if (!string(state == objectStart || state == key)) {
          return 'invalid_json';
        }
        state = state == objectStart || state == key ? colon : afterValue;
        continue;
      }
      if (state == objectStart || state == key) return 'invalid_json';
      if (unit == 0x7b || unit == 0x5b) {
        if (depth == containers.length) return 'invalid_json';
        if (!invalidInput && depth < 64 && unit == 0x7b) {
          objectKeys[depth] = <String>{};
        }
        containers[depth++] = unit == 0x7b ? 0x7d : 0x5d;
        if (depth > 64) invalidInput = true;
        state = unit == 0x7b ? objectStart : arrayStart;
        index++;
        continue;
      }
      if (unit == 0x2d || (unit >= 0x30 && unit <= 0x39)) {
        final start = index;
        if (at(0x2d)) index++;
        if (at(0x30)) {
          index++;
        } else if (!digits()) {
          return 'invalid_json';
        }
        if (at(0x2e)) {
          index++;
          if (!digits()) return 'invalid_json';
        }
        if (at(0x65) || at(0x45)) {
          index++;
          if (at(0x2b) || at(0x2d)) index++;
          if (!digits()) return 'invalid_json';
        }
        if (!invalidInput &&
            !double.parse(source.substring(start, index)).isFinite) {
          invalidInput = true;
        }
      } else {
        final literal = switch (unit) {
          0x6e => 'null',
          0x74 => 'true',
          0x66 => 'false',
          _ => null,
        };
        if (literal == null || !source.startsWith(literal, index)) {
          return 'invalid_json';
        }
        index += literal.length;
      }
      state = afterValue;
    }
    if (depth != 0 || state != afterValue) return 'invalid_json';
    return invalidInput ? 'invalid_input' : null;
  }

  static ServerResponse _error(String code, int status) =>
      ServerResponse(status, jsonEncode({'error': code}));
}

/// Identity exposed to a business handler after host verification.
final class SessionUser {
  const SessionUser(this.id, this.email);

  final String id;
  final String email;
}

/// A verified business session for the current request.
final class Session {
  const Session(this.id, this.user);

  final String id;
  final SessionUser user;
}

/// The public user snapshot supplied during a host signup callback.
final class AuthUser {
  const AuthUser(this.id, this.email, this.createdAt);

  final String id;
  final String email;
  final String createdAt;
}

/// Callbacks wired by generated applications into the host's signup lifecycle.
final class AuthHooks {
  const AuthHooks({this.userCreating, this.userCreated});

  final Future<void> Function(DatabaseConnection, AuthUser)? userCreating;
  final Future<void> Function(AuthUser)? userCreated;
}

Map<String, Object?> _object(Object? value, int keys) {
  if (value is! Map<String, Object?> || value.length != keys) {
    throw const FormatException('Invalid host authentication frame.');
  }
  return value;
}

String _string(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || field.isEmpty) {
    throw const FormatException('Invalid host authentication frame.');
  }
  return field;
}

void _validateVersion(Map<String, Object?> frame) {
  final version = frame['version'];
  if (version is! int || version != 1) {
    throw const FormatException('Invalid host authentication frame.');
  }
}

Session? _decodeVerifiedSession(Object? value) {
  final frame = _object(value, 2);
  _validateVersion(frame);
  if (frame.containsKey('session') && frame['session'] == null) return null;
  final session = _object(frame['session'], 2);
  final user = _object(session['user'], 2);
  return Session(
    _string(session, 'id'),
    SessionUser(_string(user, 'id'), _string(user, 'email')),
  );
}

({String kind, AuthUser user}) _decodeAuthHook(Object? value) {
  final frame = _object(value, 3);
  _validateVersion(frame);
  final user = _object(frame['user'], 3);
  return (
    kind: _string(frame, 'hook'),
    user: AuthUser(
      _string(user, 'id'),
      _string(user, 'email'),
      _string(user, 'createdAt'),
    ),
  );
}
