import 'dart:async';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_flutter/chickinfry_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

SessionCredentials credentials({String token = 'a', String user = 'user'}) =>
    SessionCredentials(
      accessToken: token * 43,
      refreshToken: 'r' * 43,
      expiresAt: '2026-01-01T00:00:00.123456Z',
      refreshExpiresAt: '2026-01-08T00:00:00Z',
      userId: user,
      sessionId: 'session',
    );

Matcher failure(String code) =>
    isA<ClientException>().having((error) => error.code, 'code', code);

class StoragePeer {
  final records = <String, String>{};
  final calls = <MethodCall>[];
  String? failMethod;
  bool returnNull = false;
  Future<void> Function()? beforeRead;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (call.method == failMethod) {
      throw PlatformException(code: 'locked', message: 'private OS detail');
    }
    final arguments = call.arguments as Map;
    final key = arguments['key'] as String;
    switch (call.method) {
      case 'read':
        final value = records[key];
        await beforeRead?.call();
        return returnNull ? null : value;
      case 'containsKey':
        return records.containsKey(key);
      case 'write':
        records[key] = arguments['value'] as String;
        return null;
      case 'delete':
        records.remove(key);
        return null;
      default:
        throw StateError('Unexpected storage operation: ${call.method}');
    }
  }

  int count(String method) =>
      calls.where((call) => call.method == method).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StoragePeer peer;
  setUp(() {
    peer = StoragePeer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, peer.handle);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    expect(peer.count('deleteAll'), 0);
  });

  if (kIsWeb) {
    test(
      'Web rejects construction before origin validation or plugin access',
      () {
        for (final origin in ['https://api.example.com', 'invalid']) {
          expect(
            () => SecureSessionStore(origin),
            throwsA(failure('unsupported_platform')),
          );
        }
        expect(peer.calls, isEmpty);
      },
    );
    return;
  }

  test(
    'one complete record survives a new wrapper with canonical origin',
    () async {
      final store = SecureSessionStore('HTTPS://API.EXAMPLE.COM:443/');
      expect(store.origin, 'https://api.example.com');
      expect(await store.read(), isNull);
      final value = credentials();
      await store.write(value);
      final reopened = SecureSessionStore('https://api.example.com');
      expect(reopened.coordinationKey, store.coordinationKey);
      expect(await reopened.read(), value);
      expect(peer.records, hasLength(1));
      expect(jsonDecode(peer.records.values.single), {
        'version': 1,
        'origin': store.origin,
        ...value.toJson(),
      });
    },
  );

  test('invalid origins fail without storage access', () {
    for (final origin in [
      'http://example.com',
      'https://example.com/path',
      'https://u@example.com',
    ]) {
      expect(
        () => SecureSessionStore(origin),
        throwsA(failure('invalid_origin')),
      );
    }
    expect(peer.calls, isEmpty);
  });

  test(
    'native null for an existing record is corruption, not absence',
    () async {
      final store = SecureSessionStore('https://api.example.com');
      await store.write(credentials());
      peer.returnNull = true;
      await expectLater(
        store.read(),
        throwsA(failure('invalid_session_record')),
      );
      await expectLater(
        store.compareAndSet(credentials(), null),
        throwsA(failure('invalid_session_record')),
      );
      expect(peer.records, hasLength(1));
      expect(peer.count('delete'), 0);
      peer.failMethod = 'containsKey';
      await expectLater(
        store.read(),
        throwsA(failure('session_storage_error')),
      );
      expect(peer.count('delete'), 0);
    },
  );

  test('corrupt records fail and preserve the original bytes', () async {
    final store = SecureSessionStore('https://api.example.com');
    final valid = <String, Object?>{
      'version': 1,
      'origin': store.origin,
      ...credentials().toJson(),
    };
    final corrupt = <String>[
      '',
      ' ',
      '{',
      'null',
      '[]',
      '"text"',
      for (final field in valid.keys) jsonEncode({...valid}..remove(field)),
      for (final field in valid.keys) jsonEncode({...valid, field: null}),
      for (final field in credentials().toJson().keys)
        jsonEncode({...valid, field: 7}),
      for (final version in [0, 2, 1.0, '1'])
        jsonEncode({...valid, 'version': version}),
      for (final origin in [
        'https://other.example.com',
        '${store.origin}/',
        'invalid',
      ])
        jsonEncode({...valid, 'origin': origin}),
      for (final field in ['access_token', 'refresh_token'])
        for (final token in ['', 'x' * 42, 'x' * 44, '!' * 43, '${'x' * 43}\n'])
          jsonEncode({...valid, field: token}),
      for (final field in ['user_id', 'session_id'])
        jsonEncode({...valid, field: ''}),
      for (final field in ['expires_at', 'refresh_expires_at'])
        for (final time in [
          '',
          '2026-02-30T00:00:00Z',
          '2026-01-01',
          '2026-01-01T25:00:00Z',
        ])
          jsonEncode({...valid, field: time}),
    ];
    for (final raw in corrupt) {
      peer.records[store.coordinationKey] = raw;
      await expectLater(
        store.read(),
        throwsA(failure('invalid_session_record')),
      );
      await expectLater(
        store.compareAndSet(credentials(), null),
        throwsA(failure('invalid_session_record')),
      );
      expect(peer.records[store.coordinationKey], raw);
    }
    expect(peer.count('write'), 0);
    expect(peer.count('delete'), 0);
    await store.write(credentials(token: 'b'));
    expect(await store.read(), credentials(token: 'b'));
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    test('$platform read errors preserve records and never delete', () async {
      debugDefaultTargetPlatformOverride = platform;
      final store = SecureSessionStore('https://api.example.com');
      await store.write(credentials());
      final before = peer.records[store.coordinationKey];
      peer.failMethod = 'read';
      await expectLater(
        store.read(),
        throwsA(failure('session_storage_error')),
      );
      await expectLater(
        store.compareAndSet(credentials(), null),
        throwsA(failure('session_storage_error')),
      );
      expect(peer.records[store.coordinationKey], before);
      expect(peer.count('delete'), 0);
      peer.failMethod = null;
      expect(await store.read(), credentials());
      final options = (peer.calls.first.arguments as Map)['options'] as Map;
      if (platform == TargetPlatform.android) {
        expect(options['resetOnError'], 'false');
        expect(options['migrateOnAlgorithmChange'], 'false');
        expect(options['storageNamespace'], 'chickinfry.sessions');
      } else {
        expect(options['accountName'], 'chickinfry.sessions');
        expect(options['synchronizable'], 'false');
        expect(options['groupId'], isNull);
      }
    });
  }

  test('OS mutation errors are redacted and release the shared lock', () async {
    final store = SecureSessionStore('https://api.example.com');
    await store.write(credentials());
    for (final method in ['write', 'delete']) {
      peer.failMethod = method;
      try {
        if (method == 'write') {
          await store.write(credentials(token: 'b'));
        } else {
          await store.compareAndSet(credentials(), null);
        }
        fail('Expected storage failure');
      } on ClientException catch (error) {
        expect(error.code, 'session_storage_error');
        expect(error.toString(), isNot(contains('private OS detail')));
      }
      peer.failMethod = null;
      expect(await store.read(), credentials());
    }
  });

  test('conditional mutations protect new logins and other origins', () async {
    final store = SecureSessionStore('https://api.example.com');
    final other = SecureSessionStore('https://other.example.com');
    expect(store.coordinationKey, isNot(other.coordinationKey));
    expect(await store.compareAndSet(credentials(), null), isFalse);
    await other.write(credentials(user: 'other'));
    await store.write(credentials());
    expect(
      await store.compareAndSet(credentials(), credentials(token: 'b')),
      isTrue,
    );
    expect(await store.compareAndSet(credentials(), null), isFalse);
    await store.write(credentials(user: 'new-login'));
    expect(await store.compareAndSet(credentials(token: 'b'), null), isFalse);
    expect(
      await store.compareAndSet(credentials(user: 'new-login'), null),
      isTrue,
    );
    expect(await store.read(), isNull);
    expect(await other.read(), credentials(user: 'other'));
    expect(peer.count('delete'), 1);
  });

  test(
    'shared wrappers serialize compare/write while other origins proceed',
    () async {
      final first = SecureSessionStore('https://api.example.com');
      final second = SecureSessionStore('https://api.example.com/');
      final other = SecureSessionStore('https://other.example.com');
      await first.write(credentials());
      final entered = Completer<void>();
      final resume = Completer<void>();
      peer.beforeRead = () async {
        entered.complete();
        await resume.future;
      };
      final replacement = first.compareAndSet(
        credentials(),
        credentials(token: 'b'),
      );
      await entered.future;
      final login = second.write(credentials(user: 'new-login'));
      await other.write(credentials(user: 'other'));
      expect(peer.count('write'), 2);
      peer.beforeRead = null;
      resume.complete();
      expect(await replacement, isTrue);
      await login;
      expect(await first.read(), credentials(user: 'new-login'));
      final results = await Future.wait([
        first.compareAndSet(
          credentials(user: 'new-login'),
          credentials(token: 'c'),
        ),
        second.compareAndSet(credentials(user: 'new-login'), null),
      ]);
      expect(results, [true, false]);
      expect(await second.read(), credentials(token: 'c'));
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.fuchsia,
  ]) {
    test('$platform is rejected before plugin access', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        () => SecureSessionStore('https://api.example.com'),
        throwsA(failure('unsupported_platform')),
      );
      expect(peer.calls, isEmpty);
    });
  }
}
