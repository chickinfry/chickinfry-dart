import '../errors.dart';
import '../http.dart';
import '../session.dart';
import 'open_stub.dart' if (dart.library.io) 'native.dart' as platform;
import 'persist.dart';
import 'store.dart';

// Generated clients supply identities; the runtime never infers them from URLs.
DeviceTransport createDeviceTransport({
  required String app,
  required String origin,
  required String project,
  required String environment,
  required String screen,
  Persist? persist,
  Duration timeout = const Duration(seconds: 30),
}) {
  final scope = DeviceScope(
    app: app,
    origin: origin,
    project: project,
    environment: environment,
    screen: screen,
  );
  final store = persist == Persist.disabled
      ? MemoryDeviceStore(scope)
      : platform.openDevice(scope, persist);
  return DeviceTransport(store, timeout: timeout);
}

final class DeviceTransport implements ClientTransport {
  DeviceTransport(this.store, {Duration timeout = const Duration(seconds: 30)})
    : _connection = HttpTransport(store.origin, timeout: timeout) {
    _transport = _connection.withSession(store);
  }
  final DeviceStore store;
  final HttpTransport _connection;
  late final HttpTransport _transport;
  void close() => _connection.close();
  HttpTransport withBearer(String token) => _connection.withBearer(token);

  @override
  Future<Object?> invoke(String operation, Map<String, Object?> input) async {
    final auth = const {
      'auth.signup',
      'auth.signin',
      'auth.signin_with_code',
      'auth.identity',
      'auth.verify_email',
      'auth.send_verification_email',
      'auth.logout',
    };
    if (!auth.contains(operation)) {
      return _transport.invoke(operation, input);
    }
    final before = await store.load();
    final started = DateTime.now().millisecondsSinceEpoch;
    final attempts = Map<String, DeviceAttempt>.from(before.attempts)
      ..removeWhere((_, value) => value.expiredAt(started));
    final screen = store.scope.screen;
    final saved = attempts[screen];
    var request = input;
    if (const {
          'auth.verify_email',
          'auth.send_verification_email',
        }.contains(operation) &&
        input['email'] == null &&
        input['attempt'] == null &&
        saved != null &&
        saved.validAt(started)) {
      request = {...input, 'attempt': saved.id};
    }
    if (operation == 'auth.logout') {
      Object? result;
      try {
        if (before.session != null) {
          result = await _connection
              .withBearer(before.session!.accessToken)
              .invoke(operation, input);
        }
      } finally {
        await store.clear(before);
      }
      return result ?? <String, Object?>{};
    }
    DeviceAttempt? consumed;
    if (operation == 'auth.verify_email' && request['attempt'] is String) {
      for (final attempt in before.attempts.values) {
        if (attempt.id == request['attempt']) consumed = attempt;
      }
    }
    final result = await _connection.invoke(operation, request);
    if (result is! Map<String, Object?>) {
      throw const ClientException('invalid_response');
    }
    final email = request['email'] is String
        ? (request['email']! as String).trim().toLowerCase()
        : (consumed?.email ??
              (saved != null && request['attempt'] == saved.id
                  ? saved.email
                  : null));
    SessionCredentials? issued;
    DeviceAttempt? pending;
    if (result.containsKey('access_token')) {
      try {
        issued = SessionCredentials.fromJson(result);
        DeviceState.fromJson(DeviceState(session: issued).toJson());
      } on ClientException {
        throw const ClientException('invalid_response');
      }
    } else if (operation == 'auth.signup' &&
        result['accepted'] == true &&
        result['attempt'] is String &&
        email != null) {
      try {
        pending = DeviceAttempt.fromJson({
          'id': result['attempt'],
          'email': email,
          'started_at': started,
        });
      } on ClientException {
        throw const ClientException('invalid_response');
      }
    }
    var current = before;
    for (
      var conflicts = 0;
      conflicts <= deviceLocalRetryLimit + 1;
      conflicts++
    ) {
      final attempts = {...current.attempts}
        ..removeWhere(
          (_, value) => value.expiredAt(DateTime.now().millisecondsSinceEpoch),
        );
      final referenced = consumed;
      final stillPresent =
          referenced == null ||
          current.attempts.values.any((value) => value.id == referenced.id);
      final late =
          current.authGeneration != before.authGeneration || !stillPresent;
      DeviceState? next;
      if (late) {
        if (issued == null || referenced == null || !stillPresent) {
          return result;
        }
        attempts.removeWhere((_, value) => value.id == referenced.id);
        next = DeviceState(
          generation: current.generation + 1,
          authGeneration: current.authGeneration,
          session: current.session,
          refreshSent: current.refreshSent,
          attempts: attempts,
        );
      } else if (issued != null) {
        attempts.removeWhere(
          (_, value) => value.email == email || value.id == request['attempt'],
        );
        next = DeviceState(
          generation: current.generation + 1,
          authGeneration:
              current.authGeneration +
              (current.session?.sessionId != issued.sessionId ||
                      current.session?.userId != issued.userId
                  ? 1
                  : 0),
          session: issued,
          attempts: attempts,
        );
      } else if (pending != null) {
        attempts[screen] = pending;
        next = DeviceState(
          generation: current.generation + 1,
          authGeneration: current.authGeneration,
          session: current.session,
          refreshSent: current.refreshSent,
          attempts: attempts,
        );
      } else if (attempts.length != current.attempts.length) {
        next = DeviceState(
          generation: current.generation + 1,
          authGeneration: current.authGeneration,
          session: current.session,
          refreshSent: current.refreshSent,
          attempts: attempts,
        );
      }
      if (next == null) return result;
      if (conflicts == deviceLocalRetryLimit + 1) {
        store.transientBaseGeneration ??= current.generation;
        store.transientState = next;
        return result;
      }
      if (await store.commitAfterSuccess(current, next)) return result;
      current = await store.load();
    }
    return result;
  }
}
