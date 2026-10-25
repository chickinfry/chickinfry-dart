import 'dart:async';
import 'dart:convert';

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
      throw const ClientException('invalid_input');
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
      throw const ClientException('device_storage_corrupt');
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
      throw const ClientException('device_storage_corrupt');
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
    this.authTransitionUnknown = false,
    Map<String, DeviceAttempt> attempts = const {},
  }) : attempts = Map.unmodifiable(attempts);
  final int generation;
  final int authGeneration;
  final SessionCredentials? session;
  final bool refreshSent;
  final bool authTransitionUnknown;
  final Map<String, DeviceAttempt> attempts;

  Map<String, Object?> toJson() => {
    'generation': generation,
    'auth_generation': authGeneration,
    'session': session?.toJson(),
    'refresh_sent': refreshSent,
    'auth_transition_unknown': authTransitionUnknown,
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
        value['attempts'] is! Map<String, Object?>) {
      throw const ClientException('device_storage_corrupt');
    }
    try {
      final attempts = (value['attempts']! as Map<String, Object?>).map((
        key,
        entry,
      ) {
        if (!_validScreen(key)) {
          throw const ClientException('device_storage_corrupt');
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
        throw const ClientException('device_storage_corrupt');
      }
      return DeviceState(
        generation: value['generation']! as int,
        authGeneration: value['auth_generation']! as int,
        session: session,
        refreshSent: value['refresh_sent']! as bool,
        authTransitionUnknown: value['auth_transition_unknown'] == true,
        attempts: attempts,
      );
    } on ClientException {
      throw const ClientException('device_storage_corrupt');
    }
  }
}

// This is the only storage boundary consumed by native authentication.
abstract class DeviceStore implements SessionStore {
  DeviceStore(this.scope);
  final DeviceScope scope;
  bool blocked = false;
  DeviceState? transientState;
  int? transientBaseGeneration;
  int? transientBaseAuthGeneration;
  final activeAuthTransitions = <DeviceState>{};

  @override
  String get origin => scope.origin;
  Future<DeviceState> load();
  Future<bool> commit(DeviceState expected, DeviceState next);

  Future<bool> commitAfterSuccess(
    DeviceState expected,
    DeviceState next,
  ) async {
    try {
      next = DeviceState.fromJson(next.toJson());
      return await commit(expected, next);
    } on ClientException catch (error) {
      if (error.code != 'device_storage_unavailable' &&
          error.code != 'device_storage_full') {
        rethrow;
      }
      transientBaseGeneration ??= expected.generation;
      transientBaseAuthGeneration ??= expected.authGeneration;
      transientState = next;
      return true;
    }
  }

  void requireAvailable() {
    if (blocked) throw const ClientException('device_storage_unavailable');
  }

  @override
  Future<SessionCredentials?> read() async {
    requireAvailable();
    final state = await load();
    if (state.authTransitionUnknown &&
        !activeAuthTransitions.any(
          (active) => active.authGeneration == state.authGeneration,
        )) {
      return null;
    }
    if (state.refreshSent) throw const ClientException('session_changed');
    return state.session;
  }

  Future<SessionCredentials?> waitForSession(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        return await read();
      } on ClientException catch (error) {
        if (error.code != 'session_changed' || elapsed.elapsed >= timeout) {
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
      throw const ClientException('session_changed');
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
      authTransitionUnknown: current.authTransitionUnknown,
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
          !current.refreshSent) {
        return false;
      }
      final replacement = DeviceState(
        generation: current.generation + 1,
        authGeneration: current.authGeneration + (next == null ? 1 : 0),
        session: next,
        authTransitionUnknown: next != null && current.authTransitionUnknown,
        attempts: current.attempts,
      );
      if (conflicts == deviceLocalRetryLimit + 1) {
        if (next == null) return false;
        transientBaseGeneration ??= current.generation;
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
    try {
      if (!await commit(
        expected,
        DeviceState(
          generation: expected.generation + 1,
          authGeneration: expected.authGeneration + 1,
        ),
      )) {
        throw const ClientException('session_changed');
      }
    } on ClientException catch (error) {
      if (error.code != 'session_changed') blocked = true;
      rethrow;
    }
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
      authTransitionUnknown: next.authTransitionUnknown,
      attempts: attempts,
    );
    if (next.authGeneration < 0 ||
        next.authGeneration >= _generationLimit ||
        next.generation < 0 ||
        next.generation >= _generationLimit ||
        next.attempts.length > deviceAttemptLimit ||
        utf8.encode(jsonEncode(bundle(next))).length > devicePayloadLimit) {
      throw const ClientException('device_storage_full');
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
    transientState = null;
    transientBaseGeneration = null;
    transientBaseAuthGeneration = null;
    return true;
  }
}
