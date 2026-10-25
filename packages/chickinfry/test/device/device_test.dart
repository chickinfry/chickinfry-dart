import 'dart:io';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/device/bridge.dart';
import 'package:test/test.dart';
import 'package:chickinfry/src/device/store.dart';

import 'support.dart';

void main() {
  test(
    'disabled persistence authenticates without creating a directory',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final value = credentials();
      var authenticated = false;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signin') {
          request.response.write(jsonEncode(value.toJson()));
        } else {
          authenticated =
              request.headers.value('authorization') ==
              'Bearer ${value.accessToken}';
          request.response.write('{"accepted":true}');
        }
        await request.response.close();
      });
      final transport = createDeviceTransport(
        app: 'test.app',
        origin: 'http://127.0.0.1:${server.port}',
        project: 'test.project',
        environment: 'test',
        screen: 'signup',
        persist: Persist.disabled,
      );
      addTearDown(transport.close);
      await transport.invoke('auth.signin', {'email': 'user@example.test'});
      expect(await transport.invoke('example.read', {}), {'accepted': true});
      expect(authenticated && await transport.store.read() == value, isTrue);
    },
  );
  test('memory sessions are instance scoped', () async {
    final root = MemoryDeviceStore(scope('https://memory.example.test'));
    final other = MemoryDeviceStore(scope('https://memory.example.test'));
    await root.write(credentials());
    expect(await root.read() != null, isTrue);
    expect(await other.read() == null, isTrue);
  });

  test('capacity failure preserves all three pending attempts', () async {
    final store = MemoryDeviceStore(scope('https://limits.example.test'));
    final now = DateTime.now().millisecondsSinceEpoch;
    final attempts = {
      for (var i = 0; i < 3; i++)
        'screen-$i': DeviceAttempt(randomId(), 'user-$i@example.test', now),
    };
    final first = await store.load();
    expect(
      await store.commit(first, DeviceState(generation: 1, attempts: attempts)),
      isTrue,
    );
    final current = await store.load();
    await expectLater(
      store.commit(
        current,
        DeviceState(
          generation: 2,
          attempts: {
            ...attempts,
            'overflow': DeviceAttempt(randomId(), 'overflow@example.test', now),
          },
        ),
      ),
      throwsA(
        isA<ClientException>().having(
          (e) => e.code,
          'code',
          'device_storage_full',
        ),
      ),
    );
    expect((await store.load()).generation, 1);
  });
}
