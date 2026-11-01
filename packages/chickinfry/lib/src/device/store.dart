import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../errors.dart';
import '../origin.dart';
import '../session.dart';

const devicePayloadLimit = 8192;
const deviceLocalRetryLimit = 3;
const deviceAttemptLimit = 3;
const deviceEmailLimit = 320;
const deviceScreenLimit = 64;
// Parse the native limit so this shared import also compiles for JavaScript.
final _generationLimit = int.parse('7fffffffffffffff', radix: 16);
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _requestId = RegExp(r'^[0-9a-f]{32}$');
final _requestRandom = Random.secure();

String newDeviceRequestId() => List.generate(
  16,
  (_) => _requestRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

bool _validScreen(String value) =>
    value.isNotEmpty &&
    value.length <= deviceScreenLimit &&
    value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

final class DeviceScope {
  DeviceScope({
    required this.app,
    required String origin,
    required this.project,
    required this.environment,
    required this.screen,
  }) : origin = normalizeOrigin(origin) {
    if ([
          app,
          project,
          environment,
        ].any((value) => value.isEmpty || value.length > 320) ||
        !_validScreen(screen)) {
      throw const ClientError('invalid_argument');
    }
  }
  final String app;
  final String origin;
  final String project;
  final String environment;
  final String screen;
  List<String> get owner => [app, origin, project, environment];
}

final class DeviceAttempt {
  DeviceAttempt(this.id, this.email, this.startedAt);
  final String id;
  final String email;
  final int startedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'started_at': startedAt,
  };

  factory DeviceAttempt.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value['id'] is! String ||
        value['email'] is! String ||
        value['started_at'] is! int) {
      throw const ClientError('data_loss');
    }
    final result = DeviceAttempt(
      value['id']! as String,
      value['email']! as String,
      value['started_at']! as int,
    );
    if (!_uuid.hasMatch(result.id) ||
        result.email.isEmpty ||
        result.email.length > deviceEmailLimit ||
        result.startedAt < 0) {
      throw const ClientError('data_loss');
    }
    return result;
  }

  bool validAt(int now) =>
      now >= startedAt &&
      now - startedAt < const Duration(hours: 24).inMilliseconds;
  bool expiredAt(int now) =>
      now >= startedAt &&
      now - startedAt >= const Duration(hours: 24).inMilliseconds;
}

final class DeviceState {
  DeviceState({
    this.generation = 0,
    this.authGeneration = 0,
    this.session,
    this.refreshSent = false,
    this.refreshId,
    this.authTransitionUnknown = false,
    this.authTransitionId,
    Map<String, DeviceAttempt> attempts = const {},
  }) : attempts = Map.unmodifiable(attempts);
  final int generation;
  final int authGeneration;
  final SessionCredentials? session;
  final bool refreshSent;
  final String? refreshId;
  final bool authTransitionUnknown;
  final String? authTransitionId;
  final Map<String, DeviceAttempt> attempts;

  Map<String, Object?> toJson() => {
    'generation': generation,
    'auth_generation': authGeneration,
    'session': session?.toJson(),
    'refresh_sent': refreshSent,
    if (refreshId != null) 'refresh_id': refreshId,
    'auth_transition_unknown': authTransitionUnknown,
    if (authTransitionId != null) 'auth_transition_id': authTransitionId,
    'attempts': attempts.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory DeviceState.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value['generation'] is! int ||
        value['auth_generation'] is! int ||
        (value['auth_generation']! as int) < 0 ||
        (value['generation']! as int) < 0 ||
        value['refresh_sent'] is! bool ||
        (value.containsKey('auth_transition_unknown') &&
            value['auth_transition_unknown'] is! bool) ||
        (value['auth_transition_id'] != null &&
            (value['auth_transition_id'] is! String ||
                !_requestId.hasMatch(value['auth_transition_id']! as String) ||
                value['auth_transition_unknown'] != true)) ||
        (value['refresh_id'] != null &&
            (value['refresh_id'] is! String ||
                !_requestId.hasMatch(value['refresh_id']! as String) ||
                value['refresh_sent'] != true)) ||
        value['attempts'] is! Map<String, Object?>) {
      throw const ClientError('data_loss');
    }
    try {
      final attempts = (value['attempts']! as Map<String, Object?>).map((
        key,
        entry,
      ) {
        if (!_validScreen(key)) {
          throw const ClientError('data_loss');
        }
        return MapEntry(key, DeviceAttempt.fromJson(entry));
      });
      final session = value['session'] == null
          ? null
          : SessionCredentials.fromJson(value['session']);
      if ((session != null &&
              (!_uuid.hasMatch(session.userId) ||
                  !_uuid.hasMatch(session.sessionId))) ||
          (value['refresh_sent'] == true && session == null)) {
        throw const ClientError('data_loss');
      }
      return DeviceState(
        generation: value['generation']! as int,
        authGeneration: value['auth_generation']! as int,
        session: session,
        refreshSent: value['refresh_sent']! as bool,
        refreshId: value['refresh_id'] as String?,
        authTransitionUnknown: value['auth_transition_unknown'] == true,
        authTransitionId: value['auth_transition_id'] as String?,
        attempts: attempts,
      );
    } on ClientError {
      throw const ClientError('data_loss');
    }
  }
}

final class _AttemptConsumption {
  _AttemptConsumption(this.result);
  final DeviceState result;
  bool settled = false;
}

// Authentication uses this storage boundary on every supported device.
abstract class DeviceStore implements SessionStore {
  DeviceStore(this.scope);
  final DeviceScope scope;
  bool blocked = false;
  int authInvalidations = 0;
  DeviceState? transientState;
  DeviceState? lastPersistentState;
  int? transientBaseAuthGeneration;
  DeviceState? _uncertainWrite;
  bool _uncertainWriteApplied = false;
  Map<String, _AttemptConsumption> _uncertainConsumption = {};
  DeviceState? get uncertainWrite => _uncertainWrite;
  set uncertainWrite(DeviceState? candidate) {
    _uncertainWrite = candidate;
    _uncertainWriteApplied = false;
    _uncertainConsumption = candidate == null ? {} : {...consumedAttemptEmails};
  }

  final consumedAttemptEmails = <String, _AttemptConsumption>{};

  void recordAttemptConsumption(String email, DeviceState result) {
    consumedAttemptEmails[email] = _AttemptConsumption(result);
  }

  final _observedPeerAuthIds = <String?>{};
  final _observedPeerRefreshIds = <String?>{};

  bool get observedPeerAuth =>
      _observedPeerAuthIds.isNotEmpty || _observedPeerRefreshIds.isNotEmpty;

  bool hasObservedPeerAuth(DeviceState current) =>
      (current.authTransitionUnknown &&
          _observedPeerAuthIds.contains(current.authTransitionId)) ||
      (current.refreshSent &&
          _observedPeerRefreshIds.contains(current.refreshId));

  void forgetObservedPeerAuth() {
    _observedPeerAuthIds.clear();
    _observedPeerRefreshIds.clear();
  }

  final activeAuthTransitions = <DeviceState>{};

  @override
  String get origin => scope.origin;
  Future<DeviceState> load();
  Future<bool> commit(DeviceState expected, DeviceState next);

  Future<bool> commitAfterSuccess(
    DeviceState expected,
    DeviceState next, {
    bool baseKnown = true,
    String? consumedEmail,
  }) async {
    final memory = transientState;
    final previousConsumption = consumedAttemptEmails[consumedEmail];
    final consumption = consumedEmail == null
        ? null
        : _AttemptConsumption(next);
    if (consumedEmail != null) {
      consumedAttemptEmails[consumedEmail] = consumption!;
    }
    var accepted = false;
    try {
      next = DeviceState.fromJson(next.toJson());
      // Recovery cannot retroactively establish an unobserved request base.
      if (!baseKnown && !identical(await load(), transientState)) return false;
      accepted = await commit(expected, next);
      return accepted;
    } on ClientError catch (error) {
      if (blocked ||
          (error.code != 'failed_precondition' &&
              error.code != 'resource_exhausted')) {
        rethrow;
      }
      if (transientState == null && baseKnown) {
        lastPersistentState = expected;
        transientBaseAuthGeneration = expected.authGeneration;
      }
      if (identical(transientState, memory)) transientState = next;
      accepted = true;
      return true;
    } finally {
      if (transientState == null) {
        consumedAttemptEmails.clear();
      } else if (!accepted &&
          consumedEmail != null &&
          identical(consumedAttemptEmails[consumedEmail], consumption)) {
        if (previousConsumption != null && !previousConsumption.settled) {
          consumedAttemptEmails[consumedEmail] = previousConsumption;
        } else {
          consumedAttemptEmails.remove(consumedEmail);
        }
      }
    }
  }

  bool _sameAuthentication(DeviceState a, DeviceState b) =>
      a.authGeneration == b.authGeneration &&
      a.session == b.session &&
      a.refreshSent == b.refreshSent &&
      a.refreshId == b.refreshId &&
      a.authTransitionUnknown == b.authTransitionUnknown &&
      a.authTransitionId == b.authTransitionId;

  bool recoveryWasApplied(DeviceState current) {
    final candidate = uncertainWrite;
    if (candidate == null ||
        current.authGeneration != candidate.authGeneration) {
      return false;
    }
    if (!_uncertainWriteApplied) {
      final base = lastPersistentState;
      // A new native session identifies our auth write despite peer attempts.
      final sameAuth =
          base != null &&
          candidate.session != null &&
          candidate.session != base.session &&
          current.generation >= candidate.generation &&
          _sameAuthentication(current, candidate);
      if (!sameAuth &&
          jsonEncode(current.toJson()) != jsonEncode(candidate.toJson())) {
        return false;
      }
      _uncertainWriteApplied = true;
      for (final consumption in _uncertainConsumption.values) {
        consumption.settled = true;
      }
    }
    return true;
  }

  void _observeRecoveryPeerMarks(DeviceState current) {
    final memory = transientState;
    if (memory == null) return;
    final base = recoveryWasApplied(current)
        ? uncertainWrite
        : lastPersistentState;
    final expectedSession =
        base != null &&
        current.session == base.session &&
        current.refreshSent == base.refreshSent &&
        current.refreshId == base.refreshId;
    _observedPeerAuthIds.removeWhere(
      (id) => !current.authTransitionUnknown || id != current.authTransitionId,
    );
    _observedPeerRefreshIds.removeWhere(
      (id) => !current.refreshSent || id != current.refreshId,
    );
    final completingOwnAuth =
        base != null &&
        base.authTransitionUnknown &&
        !memory.authTransitionUnknown &&
        base.authTransitionId != null &&
        current.authTransitionId == base.authTransitionId;
    if (current.authTransitionUnknown &&
        !completingOwnAuth &&
        !activeAuthTransitions.any(
          (active) => active.authTransitionId == current.authTransitionId,
        )) {
      _observedPeerAuthIds.add(current.authTransitionId);
    }
    if (current.refreshSent &&
        !(expectedSession && base.refreshSent && !memory.refreshSent)) {
      _observedPeerRefreshIds.add(current.refreshId);
    }
  }

  void finishRecovery(DeviceState current) {
    _observeRecoveryPeerMarks(current);
    transientState = null;
    transientBaseAuthGeneration = null;
    uncertainWrite = null;
    consumedAttemptEmails.clear();
  }

  bool recoveryReadInvalidated(DeviceState current) {
    final accepted = transientBaseAuthGeneration;
    if (accepted == null ||
        current.authGeneration <= accepted ||
        recoveryWasApplied(current)) {
      return false;
    }
    authInvalidations++;
    finishRecovery(current);
    lastPersistentState = current;
    return true;
  }

  DeviceState reconcileRecovery(
    DeviceState current,
    DeviceState next, {
    bool retain = true,
  }) {
    final memory = transientState!;
    final applied = recoveryWasApplied(current);
    final base = applied ? uncertainWrite : lastPersistentState;
    final accepted = transientBaseAuthGeneration;
    final expectedSession =
        base != null &&
        current.session == base.session &&
        current.refreshSent == base.refreshSent &&
        current.refreshId == base.refreshId;
    if (retain) _observeRecoveryPeerMarks(current);
    if (base == null ||
        (!applied &&
            (accepted == null || current.authGeneration != accepted))) {
      final accountChanged = memory.authGeneration > (accepted ?? 0);
      authInvalidations++;
      finishRecovery(current);
      lastPersistentState = current;
      if (accountChanged) {
        blocked = true;
        throw const ClientError('failed_precondition');
      }
      return current;
    }
    if (retain) {
      consumedAttemptEmails.removeWhere(
        (_, consumption) => consumption.settled,
      );
    }
    if (applied && jsonEncode(next.toJson()) == jsonEncode(base.toJson())) {
      finishRecovery(current);
      return lastPersistentState = current;
    }

    // A proven start may be newer than the last successful in-memory result.
    final currentBoundary = next.authGeneration >= base.authGeneration;
    final ownRefresh =
        currentBoundary &&
        expectedSession &&
        base.refreshSent &&
        !next.refreshSent;
    final startingAuth =
        next.authTransitionUnknown &&
        next.authTransitionId != memory.authTransitionId;
    final explicitStart =
        hasObservedPeerAuth(current) &&
        startingAuth &&
        next.authGeneration > memory.authGeneration;
    final ownAccount =
        explicitStart ||
        (expectedSession && next.authGeneration > base.authGeneration);
    final clearing =
        !startingAuth &&
        ownAccount &&
        next.authGeneration > memory.authGeneration &&
        next.session == null &&
        next.attempts.isEmpty;
    var unknown = current.authTransitionUnknown;
    var transitionId = current.authTransitionId;
    if (explicitStart) {
      unknown = true;
      transitionId = next.authTransitionId;
    } else if (currentBoundary &&
        expectedSession &&
        next.authTransitionUnknown != base.authTransitionUnknown) {
      if ((!current.authTransitionUnknown && next.authTransitionUnknown) ||
          (base.authTransitionId != null &&
              current.authTransitionId == base.authTransitionId)) {
        unknown = next.authTransitionUnknown;
        transitionId = next.authTransitionId;
      }
    }

    final baseIds = {for (final attempt in base.attempts.values) attempt.id};
    final ownIds = {for (final attempt in next.attempts.values) attempt.id};
    final peerIds = {for (final attempt in current.attempts.values) attempt.id};
    final attempts = {...current.attempts};
    attempts.removeWhere(
      (_, attempt) =>
          baseIds.contains(attempt.id) && !ownIds.contains(attempt.id),
    );
    for (final entry in next.attempts.entries) {
      if (baseIds.contains(entry.value.id) &&
          !peerIds.contains(entry.value.id)) {
        continue;
      }
      final selected = attempts[entry.key];
      if (selected == null || entry.value.startedAt > selected.startedAt) {
        attempts[entry.key] = entry.value;
      }
    }
    final completedEmails = {
      if (expectedSession)
        for (final entry in consumedAttemptEmails.entries)
          if (entry.value.result.authGeneration >= base.authGeneration &&
              entry.value.result.authGeneration <= next.authGeneration)
            entry.key,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    attempts.removeWhere(
      (_, attempt) =>
          clearing ||
          completedEmails.contains(attempt.email) ||
          attempt.expiredAt(now),
    );
    final recovered = DeviceState(
      generation: current.generation + 1,
      authGeneration: ownAccount ? next.authGeneration : current.authGeneration,
      session: ownAccount || ownRefresh ? next.session : current.session,
      refreshSent: clearing || ownRefresh || explicitStart
          ? false
          : current.refreshSent,
      refreshId: clearing || ownRefresh || explicitStart
          ? null
          : current.refreshId,
      authTransitionUnknown: !clearing && unknown,
      authTransitionId: !clearing && unknown ? transitionId : null,
      attempts: attempts,
    );
    if (recovered.authGeneration < current.authGeneration) {
      throw const ClientError('internal');
    }
    if (retain) {
      // An unsaved start mark is not a successful authentication result.
      final remembered = startingAuth
          ? reconcileRecovery(current, memory, retain: false)
          : recovered;
      lastPersistentState = current;
      transientBaseAuthGeneration = current.authGeneration;
      transientState = remembered;
    }
    return recovered;
  }

  void requireAvailable() {
    if (blocked) throw const ClientError('failed_precondition');
  }

  @override
  Future<SessionCredentials?> read() async {
    requireAvailable();
    final state = await load();
    if (state.authTransitionUnknown &&
        !activeAuthTransitions.any(
          (active) =>
              active.authGeneration == state.authGeneration &&
              active.authTransitionId == state.authTransitionId,
        )) {
      return null;
    }
    if (state.refreshSent) throw const ClientError('unauthenticated');
    return state.session;
  }

  Future<SessionCredentials?> waitForSession(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        return await read();
      } on ClientError catch (error) {
        if (error.code != 'unauthenticated' || elapsed.elapsed >= timeout) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<void> write(SessionCredentials value) async {
    final current = await load();
    if (!await commit(
      current,
      DeviceState(
        generation: current.generation + 1,
        authGeneration:
            current.authGeneration +
            (current.session?.sessionId != value.sessionId ||
                    current.session?.userId != value.userId
                ? 1
                : 0),
        session: value,
        attempts: current.attempts,
      ),
    )) {
      throw const ClientError('failed_precondition');
    }
  }

  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) async {
    final current = await load();
    if (current.session != expected) return false;
    return commit(
      current,
      DeviceState(
        generation: current.generation + 1,
        authGeneration:
            current.authGeneration +
            (next == null ||
                    next.sessionId != current.session?.sessionId ||
                    next.userId != current.session?.userId
                ? 1
                : 0),
        session: next,
        attempts: current.attempts,
      ),
    );
  }

  Future<DeviceState?> claimRefresh(SessionCredentials expected) async {
    final current = await load();
    if (current.session != expected || current.refreshSent) return null;
    final claimed = DeviceState(
      generation: current.generation + 1,
      session: expected,
      authGeneration: current.authGeneration,
      refreshSent: true,
      refreshId: newDeviceRequestId(),
      authTransitionUnknown: current.authTransitionUnknown,
      authTransitionId: current.authTransitionId,
      attempts: current.attempts,
    );
    return await commit(current, claimed) ? claimed : null;
  }

  Future<bool> finishRefresh(
    DeviceState claimed,
    SessionCredentials? next,
  ) async {
    var current = claimed;
    for (
      var conflicts = 0;
      conflicts <= deviceLocalRetryLimit + 1;
      conflicts++
    ) {
      if (current.authGeneration != claimed.authGeneration ||
          current.session != claimed.session ||
          current.refreshId != claimed.refreshId ||
          !current.refreshSent) {
        return false;
      }
      final replacement = DeviceState(
        generation: current.generation + 1,
        authGeneration: current.authGeneration + (next == null ? 1 : 0),
        session: next,
        authTransitionUnknown: next != null && current.authTransitionUnknown,
        authTransitionId: next != null ? current.authTransitionId : null,
        attempts: current.attempts,
      );
      if (conflicts == deviceLocalRetryLimit + 1) {
        if (next == null) return false;
        if (transientState == null) lastPersistentState = current;
        transientBaseAuthGeneration ??= current.authGeneration;
        transientState = replacement;
        return true;
      }
      final saved = next == null
          ? await commit(current, replacement)
          : await commitAfterSuccess(current, replacement);
      if (saved) return true;
      current = await load();
    }
    return false;
  }

  Future<void> clear(DeviceState expected) async {
    final bool saved;
    try {
      saved = await commit(
        expected,
        DeviceState(
          generation: expected.generation + 1,
          authGeneration: expected.authGeneration + 1,
        ),
      );
    } on ClientError {
      blocked = true;
      rethrow;
    }
    if (!saved) throw const ClientError('failed_precondition');
  }

  Map<String, Object?> bundle(DeviceState state) => {
    'version': 1,
    'owner': scope.owner,
    'auth': state.toJson(),
  };

  DeviceState prepareWrite(DeviceState next) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final attempts = {...next.attempts}
      ..removeWhere((_, attempt) => attempt.expiredAt(now));
    next = DeviceState(
      generation: next.generation,
      authGeneration: next.authGeneration,
      session: next.session,
      refreshSent: next.refreshSent,
      refreshId: next.refreshId,
      authTransitionUnknown: next.authTransitionUnknown,
      authTransitionId: next.authTransitionId,
      attempts: attempts,
    );
    if (next.authGeneration < 0 ||
        next.authGeneration >= _generationLimit ||
        next.generation < 0 ||
        next.generation >= _generationLimit ||
        next.attempts.length > deviceAttemptLimit ||
        utf8.encode(jsonEncode(bundle(next))).length > devicePayloadLimit) {
      throw const ClientError('resource_exhausted');
    }
    return DeviceState.fromJson(next.toJson());
  }
}

final class MemoryDeviceStore extends DeviceStore {
  MemoryDeviceStore(super.scope);
  DeviceState _state = DeviceState();
  @override
  String get coordinationKey => 'memory:${identityHashCode(this)}';
  @override
  Future<DeviceState> load() async {
    requireAvailable();
    return transientState ?? _state;
  }

  @override
  Future<bool> commit(DeviceState expected, DeviceState next) async {
    requireAvailable();
    if ((transientState ?? _state).generation != expected.generation) {
      return false;
    }
    next = prepareWrite(next);
    _state = next;
    finishRecovery(expected);
    return true;
  }
}
