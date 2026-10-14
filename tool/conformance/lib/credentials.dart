import 'dart:ffi';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';

import 'protocol.dart';

final class Credentials {
  final _values = <String, String>{};
  void register(String ref, String value) {
    if (!identifierPattern.hasMatch(ref) || _values.containsKey(ref)) {
      violation();
    }
    _values[ref] = value;
  }

  String value(String ref) {
    final result = _values[ref];
    if (result == null) throw const DriverError('invalid_reference');
    return result;
  }

  String? reference(String value) {
    for (final entry in _values.entries) {
      if (entry.value == value) return entry.key;
    }
    return null;
  }

  bool contains(String ref) => _values.containsKey(ref);
  bool exposes(Object? value) {
    if (value is String) {
      return _values.values.any(
        (secret) => secret.isNotEmpty && value.contains(secret),
      );
    }
    if (value is List<Object?>) return value.any(exposes);
    if (value is Map<String, Object?>) {
      return value.entries.any(
        (entry) => exposes(entry.key) || exposes(entry.value),
      );
    }
    return false;
  }

  SessionCredentials record(
    String origin,
    String recordRef,
    String accessRef,
    String refreshRef,
  ) {
    final data = object(strictJson(value(recordRef)));
    const keys = {
      'origin',
      'access_token',
      'refresh_token',
      'expires_at',
      'refresh_expires_at',
      'user_id',
      'session_id',
    };
    if (data.length != keys.length ||
        !keys.every((key) => data[key] is String) ||
        data['origin'] != origin ||
        data['access_token'] != value(accessRef) ||
        data['refresh_token'] != value(refreshRef)) {
      invalidArgs();
    }
    try {
      return SessionCredentials.fromJson(data);
    } catch (_) {
      invalidArgs();
    }
  }

  void clear() => _values.clear();
}

/// Reads the inherited descriptor directly; no path, launcher or secret file is used.
Credentials bootstrap() {
  if (!Platform.isMacOS && !Platform.isLinux) unimplemented();
  final libc = DynamicLibrary.process();
  final read = libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, UintPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final malloc = libc
      .lookupFunction<
        Pointer<Uint8> Function(UintPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final free = libc
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  final buffer = malloc(8192);
  final result = Credentials();
  final frames = Frames(64 * 1024);
  var total = 0;
  try {
    if (buffer == nullptr) throw const DriverError('driver_failed');
    while (true) {
      final count = read(3, buffer, 8192);
      if (count < 0) throw const DriverError('driver_failed');
      if (count == 0) break;
      total += count;
      if (total > 1024 * 1024) violation();
      for (final line in frames.add(buffer.asTypedList(count))) {
        final frame = object(strictJson(line));
        fields(frame, {'ref', 'value'});
        result.register(identifier(frame, 'ref'), string(frame, 'value'));
      }
    }
    frames.finish();
    return result;
  } catch (_) {
    result.clear();
    rethrow;
  } finally {
    close(3);
    free(buffer);
  }
}
