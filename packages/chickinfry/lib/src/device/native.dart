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
  if (!Platform.isMacOS) {
    throw const ClientException('device_storage_unavailable');
  }
  return NativeDeviceStore(scope, directory: persist?.directory);
}

final class NativeDeviceStore extends DeviceStore {
  NativeDeviceStore(super.scope, {String? directory, MacFiles? files})
    : _base = directory,
      _files = files ?? MacFiles();
  final String? _base;
  final MacFiles _files;
  DeviceState? _uncertainWrite;
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
    final home = Platform.environment['HOME'];
    if (home == null || !home.startsWith('/')) {
      throw const ClientException('device_storage_unavailable');
    }
    if (scope.app == '.' ||
        scope.app == '..' ||
        scope.app.contains('/') ||
        scope.app.contains('\x00')) {
      throw const ClientException('device_storage_unavailable');
    }
    return '$home/Library/Application Support/${scope.app}';
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
  Future<DeviceState> load() {
    requireAvailable();
    if (!Platform.isMacOS) {
      throw const ClientException('device_storage_unavailable');
    }
    if (transientState != null) return Future.value(transientState!);
    return _files.locked(directory, (dir) async => _load(dir), root: _root);
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
        final accepted = transientBaseAuthGeneration;
        if (accepted != null && current.authGeneration > accepted) {
          transientState = null;
          transientBaseGeneration = null;
          transientBaseAuthGeneration = null;
          _uncertainWrite = null;
          return null;
        }
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
    if (memory != null) {
      if (memory.generation != expected.generation) return Future.value(false);
      if (next.authTransitionUnknown) {
        throw const ClientException('device_storage_unavailable');
      }
      next = prepareWrite(next);
      transientState = next;
      return Future.value(true);
    }
    return _commitPersistent(expected, next);
  }

  @override
  Future<DeviceState?> claimRefresh(SessionCredentials expected) {
    if (transientState != null) {
      throw const ClientException('device_storage_unavailable');
    }
    return super.claimRefresh(expected);
  }

  @override
  Future<void> clear(DeviceState expected) async {
    if (transientState == null) return super.clear(expected);
    if (transientState!.generation != expected.generation) {
      throw const ClientException('session_changed');
    }
    try {
      final current = await _files.locked(
        directory,
        (dir) async => _load(dir),
        root: _root,
      );
      final candidate = _uncertainWrite;
      if (current.generation != transientBaseGeneration &&
          (candidate == null ||
              jsonEncode(current.toJson()) != jsonEncode(candidate.toJson()))) {
        throw const ClientException('session_changed');
      }
      if (!await _commitPersistent(
        current,
        DeviceState(
          generation: current.generation + 1,
          authGeneration:
              (current.authGeneration > expected.authGeneration
                  ? current.authGeneration
                  : expected.authGeneration) +
              1,
        ),
      )) {
        throw const ClientException('session_changed');
      }
      transientState = null;
      transientBaseGeneration = null;
      transientBaseAuthGeneration = null;
      _uncertainWrite = null;
    } on ClientException {
      blocked = true;
      rethrow;
    }
  }

  Future<bool> _commitPersistent(DeviceState expected, DeviceState next) {
    requireAvailable();
    if (!Platform.isMacOS) {
      throw const ClientException('device_storage_unavailable');
    }
    return _files.locked(directory, (dir) async {
      final current = _load(dir);
      if (current.generation != expected.generation) return false;
      if (next.generation != current.generation + 1) {
        throw const ClientException('session_changed');
      }
      next = prepareWrite(next);
      try {
        _files.writeAtomic(
          dir,
          'auth.json',
          Uint8List.fromList(utf8.encode(jsonEncode(bundle(next)))),
        );
      } on ClientException {
        _uncertainWrite = next;
        rethrow;
      }
      return true;
    }, root: _root);
  }
}
