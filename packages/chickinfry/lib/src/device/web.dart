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
    throw const ClientError('failed_precondition');
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
      throw const ClientError('failed_precondition');
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
        throw const ClientError('data_loss');
      }
      final envelope = jsonDecode(value);
      if (envelope is! Map<String, Object?> || envelope['version'] is! int) {
        throw const ClientError('data_loss');
      }
      if ((envelope['version']! as int) > 1) {
        throw const ClientError('unimplemented');
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
        throw const ClientError('data_loss');
      }
      final state = DeviceState.fromJson(auth);
      if (state.attempts.length > deviceAttemptLimit || !_safeIntegers(state)) {
        throw const ClientError('data_loss');
      }
      _rawValues[state] = value;
      if (transientState == null) lastPersistentState = state;
      return state;
    } on ClientError {
      rethrow;
    } catch (_) {
      throw const ClientError('data_loss');
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
    } on ClientError catch (error) {
      if (blocked ||
          (error.code != 'failed_precondition' &&
              error.code != 'resource_exhausted')) {
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
      } on ClientError catch (error) {
        if (error.code != 'failed_precondition') rethrow;
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
      throw const ClientError('unimplemented');
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
      throw const ClientError('internal');
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
      throw const ClientError('internal');
    }
    next = prepareWrite(next);
    if (!_safeIntegers(next)) {
      throw const ClientError('resource_exhausted');
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
        } on ClientError catch (error) {
          if (error.code != 'failed_precondition' &&
              error.code != 'resource_exhausted') {
            rethrow;
          }
        } finally {
          lastPersistentState = base;
        }
      }
      if (error.isA<web.DOMException>() &&
          (error as web.DOMException).name == 'QuotaExceededError') {
        throw const ClientError('resource_exhausted');
      }
      throw const ClientError('failed_precondition');
    }
    finishRecovery(current);
    lastPersistentState = next;
    _rawValues[next] = encoded;
    return true;
  }
}
