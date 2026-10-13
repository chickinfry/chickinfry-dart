import 'dart:async';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _namespace = 'chickinfry.sessions';
const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    resetOnError: false,
    migrateOnAlgorithmChange: false,
    storageNamespace: _namespace,
  ),
  iOptions: IOSOptions(accountName: _namespace),
  mOptions: MacOsOptions(accountName: _namespace),
);
final _pending = <String, Future<void>>{};

/// Stores one origin's session in app-scoped OS secure storage.
///
/// Wrappers share a mutation boundary within one isolate. Cross-isolate and
/// cross-process transactions are unsupported. Corrupt records are preserved.
final class SecureSessionStore implements SessionStore {
  factory SecureSessionStore(String origin) {
    _requireNative();
    // Reuse the runtime's origin contract without opening a network connection.
    final transport = HttpTransport(origin);
    try {
      return SecureSessionStore._(transport.origin);
    } finally {
      transport.close();
    }
  }

  SecureSessionStore._(this.origin)
    : coordinationKey = '$_namespace.${base64Url.encode(utf8.encode(origin))}';

  @override
  final String origin;

  @override
  final String coordinationKey;

  @override
  Future<SessionCredentials?> read() => _locked(_read);

  @override
  Future<void> write(SessionCredentials value) => _locked(() => _write(value));

  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) => _locked(() async {
    if (await _read() != expected) return false;
    if (next == null) {
      try {
        await _storage.delete(key: coordinationKey);
      } catch (_) {
        throw const ClientException('session_storage_error');
      }
    } else {
      await _write(next);
    }
    return true;
  });

  Future<SessionCredentials?> _read() async {
    final String? raw;
    final bool present;
    try {
      raw = await _storage.read(key: coordinationKey);
      // A native backend can return null for an existing non-UTF-8 value.
      present = raw != null || await _storage.containsKey(key: coordinationKey);
    } catch (_) {
      throw const ClientException('session_storage_error');
    }
    if (raw == null) {
      if (present) throw const ClientException('invalid_session_record');
      return null;
    }
    try {
      final record = jsonDecode(raw);
      if (record is! Map<String, Object?> ||
          record['version'] is! int ||
          record['version'] != 1 ||
          record['origin'] != origin) {
        throw const ClientException('invalid_session_record');
      }
      return SessionCredentials.fromJson(record);
    } catch (_) {
      throw const ClientException('invalid_session_record');
    }
  }

  Future<void> _write(SessionCredentials value) async {
    final raw = jsonEncode({'version': 1, 'origin': origin, ...value.toJson()});
    try {
      await _storage.write(key: coordinationKey, value: raw);
    } catch (_) {
      throw const ClientException('session_storage_error');
    }
  }

  Future<T> _locked<T>(Future<T> Function() action) async {
    _requireNative();
    final previous = _pending[coordinationKey];
    final released = Completer<void>();
    _pending[coordinationKey] = released.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      released.complete();
      if (identical(_pending[coordinationKey], released.future)) {
        _pending.remove(coordinationKey);
      }
    }
  }
}

void _requireNative() {
  if (kIsWeb ||
      !const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform)) {
    throw const ClientException('unsupported_platform');
  }
}
