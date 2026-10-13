import 'errors.dart';

final tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _timestampPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))$',
);

bool _validTimestamp(String value) {
  final match = _timestampPattern.firstMatch(value);
  if (match == null || DateTime.tryParse(value) == null) return false;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  return date.year == parts[0] &&
      date.month == parts[1] &&
      date.day == parts[2] &&
      parts[3] < 24 &&
      parts[4] < 60 &&
      parts[5] < 60 &&
      (match.group(7) == null ||
          (int.parse(match.group(7)!) < 24 && int.parse(match.group(8)!) < 60));
}

/// SessionCredentials holds one validated, immutable native session record.
final class SessionCredentials {
  SessionCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.refreshExpiresAt,
    required this.userId,
    required this.sessionId,
  }) {
    if (!tokenPattern.hasMatch(accessToken) ||
        !tokenPattern.hasMatch(refreshToken) ||
        userId.isEmpty ||
        sessionId.isEmpty ||
        !_validTimestamp(expiresAt) ||
        !_validTimestamp(refreshExpiresAt)) {
      throw const ClientException('invalid_session_record');
    }
  }

  factory SessionCredentials.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ClientException('invalid_session_record');
    }
    String field(String name) {
      final result = value[name];
      if (result is! String) {
        throw const ClientException('invalid_session_record');
      }
      return result;
    }

    return SessionCredentials(
      accessToken: field('access_token'),
      refreshToken: field('refresh_token'),
      expiresAt: field('expires_at'),
      refreshExpiresAt: field('refresh_expires_at'),
      userId: field('user_id'),
      sessionId: field('session_id'),
    );
  }

  final String accessToken;
  final String refreshToken;
  final String expiresAt;
  final String refreshExpiresAt;
  final String userId;
  final String sessionId;

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
    'refresh_expires_at': refreshExpiresAt,
    'user_id': userId,
    'session_id': sessionId,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionCredentials &&
      accessToken == other.accessToken &&
      refreshToken == other.refreshToken &&
      expiresAt == other.expiresAt &&
      refreshExpiresAt == other.refreshExpiresAt &&
      userId == other.userId &&
      sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(
    accessToken,
    refreshToken,
    expiresAt,
    refreshExpiresAt,
    userId,
    sessionId,
  );

  @override
  String toString() => 'SessionCredentials(redacted)';
}

/// SessionStore owns one origin's record; mutations must share an atomic boundary.
abstract interface class SessionStore {
  String get origin;

  /// coordinationKey identifies the physical record without credentials or identity.
  String get coordinationKey;

  Future<SessionCredentials?> read();
  Future<void> write(SessionCredentials value);

  /// compareAndSet replaces only the expected record; null deletes that record.
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  );
}
