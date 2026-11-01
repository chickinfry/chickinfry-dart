import 'errors.dart';
import 'http.dart';
import 'session.dart' show validTimestamp;

// Internal until the generated browser authentication API names are settled.
final class BrowserSession {
  BrowserSession._(this.id, this.email, this.sessionId, this.expiresAt);

  factory BrowserSession.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ClientError('internal');
    }
    String field(String name) {
      final result = value[name];
      if (result is! String || result.isEmpty) {
        throw const ClientError('internal');
      }
      return result;
    }

    final expiresAt = field('expiresAt');
    if (!validTimestamp(expiresAt)) {
      throw const ClientError('internal');
    }
    return BrowserSession._(
      field('id'),
      field('email'),
      field('sessionId'),
      expiresAt,
    );
  }

  final String id;
  final String email;
  final String sessionId;
  final String expiresAt;
}

// No token, native store, refresh, or automatic retry boundary exists here.
final class BrowserAuth {
  BrowserAuth(this._transport);
  final ClientTransport _transport;

  Future<BrowserSession> session() async =>
      BrowserSession.fromJson(await _transport.invoke('auth.session', {}));

  Future<BrowserSession> authenticate(
    String operation,
    Map<String, Object?> input,
  ) async {
    if (!const {
      'auth.signup',
      'auth.signin',
      'auth.identity',
    }.contains(operation)) {
      throw const ClientError('invalid_argument');
    }
    final issued = BrowserSession.fromJson(
      await _transport.invoke(operation, input),
    );
    final confirmed = await session();
    if (issued.id != confirmed.id || issued.sessionId != confirmed.sessionId) {
      throw const ClientError('failed_precondition');
    }
    return confirmed;
  }

  Future<void> logout() async {
    await _transport.invoke('auth.logout', {});
  }
}
