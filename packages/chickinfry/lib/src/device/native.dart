import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import '../session.dart';
import 'files.dart';
import 'persist.dart';
import 'store.dart';

String resolveDirectory(String directory) {
  if (directory.isEmpty || directory.contains('\x00')) {
    throw const ClientException('device_storage_unavailable');
  }
  try {
    return Directory(directory).absolute.uri.normalizePath().toFilePath();
  } catch (_) {
    throw const ClientException('device_storage_unavailable');
  }
}

DeviceStore openDevice(DeviceScope scope, Persist? persist) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw const ClientException('device_storage_unavailable');
  }
  return NativeDeviceStore(scope, directory: persist?.directory);
}

final class NativeDeviceStore extends DeviceStore {
  NativeDeviceStore(super.scope, {String? directory, PosixFiles? files})
    : _base = directory,
      _files = files ?? PosixFiles();
  final String? _base;
  final PosixFiles _files;
  late final String _slot = _scopePath(scope.owner);

  static String _scopePath(List<String> owner) {
    final encoded = utf8
        .encode(jsonEncode(owner))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return [
      for (var i = 0; i < encoded.length; i += 96)
        encoded.substring(i, i + 96 < encoded.length ? i + 96 : encoded.length),
    ].join('/');
  }

  String get directory => '$_root/$_slot';

  String get _root {
    final base = _base;
    if (base != null) {
      if (!base.startsWith('/') || base.isEmpty) {
        throw const ClientException('device_storage_unavailable');
      }
      return base;
    }
    if (scope.app == '.' ||
        scope.app == '..' ||
        scope.app.contains('/') ||
        scope.app.contains('\x00')) {
      throw const ClientException('device_storage_unavailable');
    }
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_STATE_HOME'];
      if (xdg != null && xdg.startsWith('/')) {
        return '$xdg/chickinfry/${scope.app}';
      }
    }
    final home = Platform.environment['HOME'];
    if (home == null || !home.startsWith('/')) {
      throw const ClientException('device_storage_unavailable');
    }
    return Platform.isLinux
        ? '$home/.local/state/chickinfry/${scope.app}'
        : '$home/Library/Application Support/${scope.app}';
  }

  @override
  String get coordinationKey => '$directory/auth.json';

  DeviceState _load(int dir) {
    final bytes = _files.read(dir, 'auth.json');
    if (bytes == null) return DeviceState();
    try {
      final envelope = jsonDecode(utf8.decode(bytes));
      if (envelope is! Map<String, Object?> || envelope['version'] is! int) {
        throw const ClientException('device_storage_corrupt');
      }
      if ((envelope['version']! as int) > 1) {
        throw const ClientException('device_storage_version_unsupported');
      }
      if (envelope['version'] != 1 ||
          jsonEncode(envelope['owner']) != jsonEncode(scope.owner)) {
        throw const ClientException('device_storage_corrupt');
      }
      final state = DeviceState.fromJson(envelope['auth']);
      if (state.attempts.length > deviceAttemptLimit) {
        throw const ClientException('device_storage_corrupt');
      }
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
    if (!Platform.isMacOS && !Platform.isLinux) {
      throw const ClientException('device_storage_unavailable');
    }
    try {
      return await _files.locked(directory, (dir) async {
        final current = _load(dir);
        final memory = transientState;
        if (memory == null) return lastPersistentState = current;
        var recovered = reconcileRecovery(current, memory);
        if (transientState == null) {
          return lastPersistentState = current;
        }
        recovered = prepareWrite(recovered);
        _write(dir, current, recovered);
        return recovered;
      }, root: _root);
    } on ClientException catch (error) {
      final memory = transientState;
      if (memory == null ||
          (error.code != 'device_storage_unavailable' &&
              error.code != 'device_storage_full')) {
        rethrow;
      }
      return memory;
    }
  }

  @override
  Future<SessionCredentials?> read() async {
    requireAvailable();
    if (transientState?.session != null) {
      try {
        final current = await _files.locked(
          directory,
          (dir) async => _load(dir),
          root: _root,
        );
        if (recoveryReadInvalidated(current)) return null;
      } on ClientException {
        return super.read();
      }
    }
    return super.read();
  }

  @override
  Future<bool> commit(DeviceState expected, DeviceState next) {
    requireAvailable();
    final memory = transientState;
    if (memory == null) return _commitPersistent(expected, next);
    if (memory.generation != expected.generation ||
        memory.authGeneration != expected.authGeneration ||
        jsonEncode(memory.toJson()) != jsonEncode(expected.toJson())) {
      return Future.value(false);
    }
    if (next.generation != expected.generation + 1 ||
        next.authGeneration < expected.authGeneration) {
      throw const ClientException('session_changed');
    }
    return _files.locked(directory, (dir) async {
      if (!identical(memory, transientState)) return false;
      final current = _load(dir);
      final recovered = reconcileRecovery(current, next);
      if (transientState == null) {
        return false;
      }
      if (next.authTransitionUnknown &&
          next.authTransitionId != memory.authTransitionId &&
          recovered.authTransitionId != next.authTransitionId) {
        return false;
      }
      _write(dir, current, prepareWrite(recovered));
      return true;
    }, root: _root);
  }

  @override
  Future<DeviceState?> claimRefresh(SessionCredentials expected) async {
    await load();
    if (transientState != null) {
      throw const ClientException('device_storage_unavailable');
    }
    return super.claimRefresh(expected);
  }

  Future<bool> _commitPersistent(DeviceState expected, DeviceState next) {
    requireAvailable();
    if (!Platform.isMacOS && !Platform.isLinux) {
      throw const ClientException('device_storage_unavailable');
    }
    return _files.locked(directory, (dir) async {
      final current = _load(dir);
      if (current.generation != expected.generation ||
          current.authGeneration != expected.authGeneration ||
          jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
        return false;
      }
      if (next.generation != current.generation + 1 ||
          next.authGeneration < current.authGeneration) {
        throw const ClientException('session_changed');
      }
      next = prepareWrite(next);
      _write(dir, current, next);
      return true;
    }, root: _root);
  }

  void _write(int dir, DeviceState current, DeviceState next) {
    try {
      _files.writeAtomic(
        dir,
        'auth.json',
        Uint8List.fromList(utf8.encode(jsonEncode(bundle(next)))),
      );
      finishRecovery(current);
      lastPersistentState = next;
    } on ClientException {
      uncertainWrite = next;
      if (consumedAttemptEmails.isNotEmpty) {
        try {
          recoveryWasApplied(_load(dir));
        } on ClientException catch (error) {
          if (error.code != 'device_storage_unavailable' &&
              error.code != 'device_storage_full') {
            rethrow;
          }
        }
      }
      rethrow;
    }
  }
}
