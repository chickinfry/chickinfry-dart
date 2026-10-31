import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../errors.dart';
import '../session.dart';
import 'persist.dart';
import 'store.dart';

const _safeIntegerLimit = 9007199254740991;

bool _safeIntegers(DeviceState state) => [
  state.generation,
  state.authGeneration,
  for (final attempt in state.attempts.values) attempt.startedAt,
].every((value) => value <= _safeIntegerLimit);

DeviceStore openDevice(DeviceScope scope, Persist? persist) {
  if (persist?.directory != null) {
    throw const ClientException('device_storage_unavailable');
  }
  return WebDeviceStore(scope);
}

final class WebDeviceStore extends DeviceStore {
  WebDeviceStore(super.scope);
  final _rawValues = Expando<String>();

  @override
  String get coordinationKey => 'chickinfry:device:${jsonEncode(scope.owner)}';

  DeviceState _loadPersistent() {
    final String? value;
    try {
      value = web.window.localStorage.getItem(coordinationKey);
    } catch (_) {
      throw const ClientException('device_storage_unavailable');
    }
    if (value == null) {
      final state = DeviceState();
      // Empty stored strings are corrupt, so '' represents a missing key.
      _rawValues[state] = '';
      if (transientState == null) lastPersistentState = state;
      return state;
    }
    try {
      if (utf8.encode(value).length > devicePayloadLimit) {
        throw const ClientException('device_storage_corrupt');
      }
      final envelope = jsonDecode(value);
      if (envelope is! Map<String, Object?> || envelope['version'] is! int) {
        throw const ClientException('device_storage_corrupt');
      }
      if ((envelope['version']! as int) > 1) {
        throw const ClientException('device_storage_version_unsupported');
      }
      final auth = envelope['auth'];
      if (envelope['version'] != 1 ||
          jsonEncode(envelope['owner']) != jsonEncode(scope.owner) ||
          auth is! Map<String, Object?> ||
          auth['session'] != null ||
          auth['refresh_sent'] != false ||
          auth['refresh_id'] != null ||
          auth['auth_transition_id'] != null ||
          auth['auth_transition_unknown'] != false) {
        throw const ClientException('device_storage_corrupt');
      }
      final state = DeviceState.fromJson(auth);
      if (state.attempts.length > deviceAttemptLimit || !_safeIntegers(state)) {
        throw const ClientException('device_storage_corrupt');
      }
      _rawValues[state] = value;
      if (transientState == null) lastPersistentState = state;
      return state;
    } on ClientException {
      rethrow;
    } catch (_) {
      throw const ClientException('device_storage_corrupt');
    }
  }

  @override
  Future<DeviceState> load() async {
    requireAvailable();
    if (transientState == null) return _loadPersistent();
    try {
      for (var conflicts = 0; conflicts <= deviceLocalRetryLimit; conflicts++) {
        final current = _loadPersistent();
        final recovered = reconcileRecovery(current, transientState!);
        if (transientState == null) return lastPersistentState = current;
        if (_commitPersistent(current, recovered)) {
          return lastPersistentState!;
        }
        if (transientState == null) return lastPersistentState!;
      }
    } on ClientException catch (error) {
      if (error.code != 'device_storage_unavailable' &&
          error.code != 'device_storage_full') {
        rethrow;
      }
    }
    return transientState!;
  }

  @override
  Future<SessionCredentials?> read() async {
    requireAvailable();
    if (transientState != null) {
      try {
        final current = _loadPersistent();
        if (recoveryReadInvalidated(current)) return null;
      } on ClientException catch (error) {
        if (error.code != 'device_storage_unavailable') rethrow;
      }
    }
    return super.read();
  }

  @override
  Future<bool> commit(DeviceState expected, DeviceState next) async {
    requireAvailable();
    if (next.session != null ||
        next.refreshId != null ||
        next.authTransitionId != null ||
        next.refreshSent ||
        next.authTransitionUnknown) {
      throw const ClientException('unsupported_auth_transport');
    }
    final memory = transientState;
    if (memory == null) return _commitPersistent(expected, next);
    if (memory.generation != expected.generation ||
        memory.authGeneration != expected.authGeneration ||
        jsonEncode(memory.toJson()) != jsonEncode(expected.toJson())) {
      return false;
    }
    if (next.generation != expected.generation + 1 ||
        next.authGeneration < expected.authGeneration) {
      throw const ClientException('session_changed');
    }
    final current = _loadPersistent();
    final recovered = reconcileRecovery(current, next);
    if (transientState == null) return false;
    return _commitPersistent(current, recovered);
  }

  bool _commitPersistent(DeviceState expected, DeviceState next) {
    final current = _loadPersistent();
    if (current.generation != expected.generation ||
        current.authGeneration != expected.authGeneration ||
        _rawValues[current] != _rawValues[expected]) {
      if (transientState != null) {
        reconcileRecovery(current, transientState!);
      }
      return false;
    }
    if (next.generation != current.generation + 1 ||
        next.authGeneration < current.authGeneration) {
      throw const ClientException('session_changed');
    }
    next = prepareWrite(next);
    if (!_safeIntegers(next)) {
      throw const ClientException('device_storage_full');
    }
    final encoded = jsonEncode(bundle(next));
    try {
      // One write replaces the bundle; the generation check does not lock other tabs.
      web.window.localStorage.setItem(coordinationKey, encoded);
    } catch (error) {
      uncertainWrite = next;
      if (consumedAttemptEmails.isNotEmpty) {
        final base = lastPersistentState;
        try {
          recoveryWasApplied(_loadPersistent());
        } on ClientException catch (error) {
          if (error.code != 'device_storage_unavailable' &&
              error.code != 'device_storage_full') {
            rethrow;
          }
        } finally {
          lastPersistentState = base;
        }
      }
      if (error.isA<web.DOMException>() &&
          (error as web.DOMException).name == 'QuotaExceededError') {
        throw const ClientException('device_storage_full');
      }
      throw const ClientException('device_storage_unavailable');
    }
    finishRecovery(current);
    lastPersistentState = next;
    _rawValues[next] = encoded;
    return true;
  }
}
