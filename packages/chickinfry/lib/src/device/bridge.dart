import '../browser_session.dart';
import '../errors.dart';
import '../http.dart';
import '../session.dart';
import 'open_stub.dart'
    if (dart.library.io) 'native.dart'
    if (dart.library.js_interop) 'web.dart'
    as platform;
import 'persist.dart';
import 'store.dart';

const _browser = bool.fromEnvironment('dart.library.js_interop');

final _authTransitions = <String, _AuthTransitions>{};

final class _AuthTransitions {
  _AuthTransitions(this.authGeneration);
  final int authGeneration;
  final live = <DeviceState>{};
  final emailGenerations = <String, int>{};
  String? markId;
  // A sibling rejection cannot undo an earlier uncertain account change.
  bool unresolved = false;

  void recordEmailClear(String email) {
    emailGenerations[email] = (emailGenerations[email] ?? 0) + 1;
  }
}

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

HttpTransport deviceRealtimeTransport(DeviceTransport transport) =>
    transport._transport;

final class DeviceTransport implements PublicTransport {
  DeviceTransport(this.store, {Duration timeout = const Duration(seconds: 30)})
    : _connection = HttpTransport(store.origin, timeout: timeout) {
    _transport = _browser ? _connection : _connection.withSession(store);
  }
  final DeviceStore store;
  final HttpTransport _connection;
  late final HttpTransport _transport;
  void close() => _connection.close();
  HttpTransport withBearer(String token) => _connection.withBearer(token);

  @override
  Future<Object?> invoke(String operation, Map<String, Object?> input) =>
      _invoke(operation, input, publicOperation: false);

  @override
  Future<Object?> invokePublic(String operation, Map<String, Object?> input) =>
      _invoke(operation, input, publicOperation: true);

  Future<Object?> _invoke(
    String operation,
    Map<String, Object?> input, {
    required bool publicOperation,
  }) async {
    store.requireAvailable();
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
      return publicOperation
          ? _transport.invokePublic(operation, input)
          : _transport.invoke(operation, input);
    }
    final explicitAuthentication = const {
      'auth.signup',
      'auth.signin',
      'auth.signin_with_code',
      'auth.identity',
    }.contains(operation);
    DeviceState before;
    var baseKnown = true;
    try {
      before = await store.load();
    } on ClientError catch (error) {
      if (!_browser || store.blocked || error.code != 'failed_precondition') {
        rethrow;
      }
      // Browser credentials remain in cookies when local storage is blocked.
      before =
          store.transientState ?? store.lastPersistentState ?? DeviceState();
      baseKnown = store.lastPersistentState != null;
    }
    if (identical(before, store.transientState)) {
      baseKnown = store.transientBaseAuthGeneration != null;
    }
    if (!store.hasObservedPeerAuth(before)) {
      store.forgetObservedPeerAuth();
    }
    final started = DateTime.now().millisecondsSinceEpoch;
    final attempts = Map<String, DeviceAttempt>.from(before.attempts)
      ..removeWhere((_, value) => value.expiredAt(started));
    final screen = store.scope.screen;
    final saved = attempts[screen];
    var request = input;
    if (const {
      'auth.verify_email',
      'auth.send_verification_email',
    }.contains(operation)) {
      if (!input.containsKey('email') &&
          !input.containsKey('attempt') &&
          saved != null &&
          saved.validAt(started)) {
        request = {...input, 'attempt': saved.id};
      }
      if (request.containsKey('email') == request.containsKey('attempt') ||
          (request['email'] ?? request['attempt']) is! String) {
        throw const ClientError('invalid_argument');
      }
    }
    if (operation == 'auth.logout') {
      Object? result;
      try {
        if (_browser) {
          result = await _connection.invoke(operation, input);
        } else if (before.session != null) {
          result = await _connection
              .withBearer(before.session!.accessToken)
              .invoke(operation, input);
        }
      } finally {
        await store.clear(before);
      }
      if (!_browser && before.session == null) {
        throw const ClientError('unauthenticated');
      }
      return result;
    }
    DeviceAttempt? consumed;
    if (operation == 'auth.verify_email' && request['attempt'] is String) {
      for (final attempt in before.attempts.values) {
        if (attempt.id == request['attempt']) consumed = attempt;
      }
    }
    final email = request['email'] is String
        ? (request['email']! as String).trim().toLowerCase()
        : (consumed?.email ??
              (saved != null && request['attempt'] == saved.id
                  ? saved.email
                  : null));
    DeviceState? transition;
    _AuthTransitions? owned;
    final coordinationKey = store.coordinationKey;
    final mayIssueSession = const {
      'auth.signup',
      'auth.signin',
      'auth.signin_with_code',
      'auth.identity',
      'auth.verify_email',
    }.contains(operation);
    if (mayIssueSession &&
        (before.session != null || before.authTransitionUnknown)) {
      for (var conflicts = 0; ; conflicts++) {
        final active = _authTransitions[coordinationKey];
        final clearObserved =
            explicitAuthentication && store.hasObservedPeerAuth(before);
        final unowned =
            clearObserved ||
            (before.authTransitionUnknown &&
                (active == null ||
                    active.live.isEmpty ||
                    active.authGeneration != before.authGeneration ||
                    active.markId != before.authTransitionId));
        final marked = DeviceState(
          generation: before.generation + 1,
          authGeneration: before.authGeneration + (unowned ? 1 : 0),
          session: unowned ? null : before.session,
          refreshSent: !unowned && before.refreshSent,
          refreshId: !unowned ? before.refreshId : null,
          authTransitionUnknown: true,
          authTransitionId: newDeviceRequestId(),
          attempts: before.attempts,
        );
        try {
          if (await store.commit(before, marked)) {
            if (clearObserved) {
              store.authInvalidations++;
              store.finishRecovery(marked);
              store.forgetObservedPeerAuth();
            }
            owned =
                active != null && active.authGeneration == marked.authGeneration
                ? active
                : _AuthTransitions(marked.authGeneration);
            _authTransitions[coordinationKey] = owned;
            owned.markId = marked.authTransitionId;
            owned.live.add(marked);
            store.activeAuthTransitions.add(marked);
            transition = marked;
            before = marked;
            break;
          }
        } on ClientError {
          throw const ClientError('failed_precondition');
        }
        if (conflicts == deviceLocalRetryLimit) {
          throw const ClientError('failed_precondition');
        }
        before = await store.load();
        if (before.session == null && !before.authTransitionUnknown) break;
      }
    }
    final invalidations = store.authInvalidations;
    final emailGeneration = owned?.emailGenerations[email] ?? 0;
    var uncertain = true;
    try {
      Object? result;
      OperationError? rejection;
      try {
        // Device authentication can proceed independently of prior credentials.
        result = await _connection.invoke(operation, request);
      } on OperationError catch (error) {
        if (transition == null) rethrow;
        rejection = error;
        uncertain = false;
      }
      if (rejection == null && result is! Map<String, Object?>) {
        throw const ClientError('internal');
      }
      SessionCredentials? issued;
      BrowserSession? browserIssued;
      DeviceAttempt? pending;
      if (_browser &&
          mayIssueSession &&
          result is Map<String, Object?> &&
          result['accepted'] != true) {
        browserIssued = BrowserSession.fromJson(result);
        final confirmed = await BrowserAuth(_connection).session();
        if (browserIssued.id != confirmed.id ||
            browserIssued.sessionId != confirmed.sessionId) {
          throw const ClientError('failed_precondition');
        }
      } else if (!_browser &&
          result is Map<String, Object?> &&
          result.containsKey('access_token')) {
        try {
          issued = SessionCredentials.fromJson(result);
          DeviceState.fromJson(DeviceState(session: issued).toJson());
        } on ClientError {
          throw const ClientError('internal');
        }
      } else if (result is Map<String, Object?> &&
          operation == 'auth.signup' &&
          result['accepted'] == true &&
          result['attempt'] is String &&
          email != null) {
        try {
          pending = DeviceAttempt.fromJson({
            'id': result['attempt'],
            'email': email,
            'started_at': started,
          });
        } on ClientError {
          throw const ClientError('internal');
        }
      }
      if (rejection == null &&
          mayIssueSession &&
          issued == null &&
          browserIssued == null &&
          pending == null) {
        throw const ClientError('internal');
      }
      final issuedSession = issued != null || browserIssued != null;
      if (!issuedSession) uncertain = false;
      var current = before;
      for (
        var conflicts = 0;
        conflicts <= deviceLocalRetryLimit + 1;
        conflicts++
      ) {
        final attempts = {...current.attempts}
          ..removeWhere(
            (_, value) =>
                value.expiredAt(DateTime.now().millisecondsSinceEpoch),
          );
        final referenced = consumed;
        final stillPresent =
            referenced == null ||
            current.attempts.values.any((value) => value.id == referenced.id);
        final sameEmailReplacement =
            referenced != null && current.attempts[screen]?.email == email;
        final late =
            store.authInvalidations != invalidations ||
            current.authGeneration != before.authGeneration ||
            (!stillPresent && !sameEmailReplacement);
        final peerMark =
            transition != null &&
            current.authTransitionUnknown &&
            current.authTransitionId != owned!.markId;
        final keepMark = transition == null || peerMark
            ? current.authTransitionUnknown
            : owned!.unresolved || owned.live.length > 1;
        DeviceState? next;
        if (late) {
          if (!issuedSession || referenced == null || !stillPresent) {
            break;
          }
          attempts.removeWhere((_, value) => value.id == referenced.id);
          next = DeviceState(
            generation: current.generation + 1,
            authGeneration: current.authGeneration,
            session: current.session,
            refreshSent: current.refreshSent,
            refreshId: current.refreshId,
            authTransitionUnknown: current.authTransitionUnknown,
            authTransitionId: current.authTransitionId,
            attempts: attempts,
          );
        } else if (issuedSession) {
          attempts.removeWhere(
            (_, value) =>
                value.email == email || value.id == request['attempt'],
          );
          next = DeviceState(
            generation: current.generation + 1,
            authGeneration:
                current.authGeneration +
                (browserIssued != null ||
                        current.session?.sessionId != issued!.sessionId ||
                        current.session?.userId != issued.userId
                    ? 1
                    : 0),
            session: issued,
            authTransitionUnknown: peerMark,
            authTransitionId: peerMark ? current.authTransitionId : null,
            attempts: attempts,
          );
        } else if (pending != null &&
            (owned?.emailGenerations[email] ?? 0) == emailGeneration) {
          attempts[screen] = pending;
          next = DeviceState(
            generation: current.generation + 1,
            authGeneration: current.authGeneration,
            session: current.session,
            refreshSent: current.refreshSent,
            refreshId: current.refreshId,
            authTransitionUnknown: keepMark,
            authTransitionId: keepMark ? current.authTransitionId : null,
            attempts: attempts,
          );
        } else if (attempts.length != current.attempts.length ||
            (transition != null && current.authTransitionUnknown != keepMark)) {
          next = DeviceState(
            generation: current.generation + 1,
            authGeneration: current.authGeneration,
            session: current.session,
            refreshSent: current.refreshSent,
            refreshId: current.refreshId,
            authTransitionUnknown: keepMark,
            authTransitionId: keepMark ? current.authTransitionId : null,
            attempts: attempts,
          );
        }
        if (next == null) break;
        if (conflicts == deviceLocalRetryLimit + 1) {
          if (rejection != null) {
            throw ClientError('failed_precondition', operationError: rejection);
          }
          if (baseKnown && store.transientState == null) {
            store.lastPersistentState = current;
            store.transientBaseAuthGeneration = current.authGeneration;
          }
          store.transientState = next;
          if (issuedSession && !late && email != null) {
            store.recordAttemptConsumption(email, next);
            owned?.recordEmailClear(email);
          }
          break;
        }
        final saved = rejection == null
            ? await store.commitAfterSuccess(
                current,
                next,
                baseKnown: baseKnown,
                consumedEmail: issuedSession && !late ? email : null,
              )
            : await store.commit(current, next);
        if (saved) {
          if (issuedSession && !late && email != null) {
            owned?.recordEmailClear(email);
          }
          if (issuedSession && store.transientState == null) uncertain = false;
          break;
        }
        current = await store.load();
        if (!baseKnown && !identical(current, store.transientState)) break;
      }
      if (rejection != null) throw rejection;
      return result;
    } finally {
      if (transition != null && owned != null) {
        store.activeAuthTransitions.remove(transition);
        owned.live.remove(transition);
        if (uncertain) owned.unresolved = true;
        if (owned.live.isEmpty &&
            identical(_authTransitions[coordinationKey], owned)) {
          _authTransitions.remove(coordinationKey);
        }
      }
    }
  }
}
