import 'dart:io';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/device/bridge.dart';
import 'package:test/test.dart';
import 'package:chickinfry/src/device/store.dart';

import '../support.dart' show Peer, clientFailure, operationFailure, reply;
import 'support.dart';

void main() {
  test('verification without a saved target fails before a request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.response.close();
    });
    final transport = DeviceTransport(
      MemoryDeviceStore(scope('http://127.0.0.1:${server.port}')),
    );
    addTearDown(transport.close);
    for (final operation in [
      'auth.verify_email',
      'auth.send_verification_email',
    ]) {
      for (final input in <Map<String, Object?>>[
        {},
        {'email': 'user@example.test', 'attempt': randomId()},
        {'email': null, 'attempt': randomId()},
      ]) {
        await expectLater(
          transport.invoke(operation, input),
          throwsA(
            isA<ClientError>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );
      }
    }
    expect(requests, 0);
  });
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
  test('C-12 one device transport signs in again after logout', () async {
    final first = credentials();
    final second = credentials(user: first.userId);
    var logins = 0;
    final seen = <(String, String?)>[];
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      final operation = request.uri.path;
      final header = request.headers.value('authorization');
      final bearer = header == null
          ? null
          : header == 'Bearer ${first.accessToken}'
          ? 'first'
          : header == 'Bearer ${second.accessToken}'
          ? 'second'
          : 'unexpected';
      seen.add((operation, bearer));
      final response = switch (operation) {
        '/auth.signin' => (++logins == 1 ? first : second).toJson(),
        '/auth.signup' => {'accepted': true, 'attempt': randomId()},
        '/auth.logout' => {'status': 'ok'},
        _ => <String, Object?>{},
      };
      await reply(request, response);
    });
    final transport = DeviceTransport(MemoryDeviceStore(scope(peer.origin)));
    addTearDown(transport.close);

    await transport.invokePublic('auth.signin', {});
    await transport.invoke('example.read', {});
    await transport.invoke('auth.logout', {});
    expect(await transport.store.read(), isNull);
    await transport.invokePublic('auth.signup', {'email': 'user@example.test'});
    await transport.invokePublic('auth.signin', {});
    await transport.invoke('example.read', {});
    await transport.invokePublic('example.list', {});
    await transport.invoke('auth.logout', {});
    await transport.invokePublic('example.list', {});
    await expectLater(
      transport.invoke('auth.logout', {}),
      throwsA(clientFailure('unauthenticated')),
    );
    await expectLater(
      transport.invoke('example.read', {}),
      throwsA(clientFailure('unauthenticated')),
    );
    expect(seen, [
      ('/auth.signin', null),
      ('/example.read', 'first'),
      ('/auth.logout', 'first'),
      ('/auth.signup', null),
      ('/auth.signin', null),
      ('/example.read', 'second'),
      ('/example.list', 'second'),
      ('/auth.logout', 'second'),
      ('/example.list', null),
    ]);
  });

  for (final failedRefresh in [false, true]) {
    final reason = failedRefresh
        ? 'an uncertain refresh'
        : 'an expired session';
    test('device can sign in after $reason', () async {
      final current = credentials();
      final first = SessionCredentials.fromJson({
        ...current.toJson(),
        'expires_at': '2000-01-01T00:00:00Z',
        'refresh_expires_at': '2000-01-02T00:00:00Z',
      });
      final next = credentials(user: first.userId);
      final signinHeaders = <bool>[];
      var refreshes = 0;
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        final header = request.headers.value('authorization');
        switch (request.uri.path) {
          case '/auth.signin':
            signinHeaders.add(header != null);
            if (header == null) {
              await reply(
                request,
                (signinHeaders.length == 1 ? first : next).toJson(),
              );
            } else {
              await reply(request, {'error': 'invalid_token'}, status: 401);
            }
          case '/auth.refresh':
            refreshes++;
            await reply(request, {
              'error': failedRefresh ? 'unavailable' : 'invalid_token',
            }, status: failedRefresh ? 500 : 401);
          default:
            if (header == 'Bearer ${next.accessToken}') {
              await reply(request, {'accepted': true});
            } else {
              await reply(request, {'error': 'invalid_token'}, status: 401);
            }
        }
      });
      final store = MemoryDeviceStore(scope(peer.origin));
      final transport = DeviceTransport(
        store,
        timeout: const Duration(seconds: 1),
      );
      addTearDown(transport.close);

      await transport.invokePublic('auth.signin', {});
      if (failedRefresh) {
        await expectLater(
          transport.invoke('example.read', {}),
          throwsA(operationFailure('unavailable', 500)),
        );
        expect((await store.load()).refreshSent, isTrue);
      }

      await transport.invokePublic('auth.signin', {});
      expect(await store.read(), next);
      expect(await transport.invoke('example.read', {}), {'accepted': true});
      expect(signinHeaders, [false, false]);
      expect(refreshes, failedRefresh ? 1 : 0);
    });
  }

  test('device can send verification email during a peer transition', () async {
    final seen = <String>[];
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      seen.add(request.uri.path);
      expect(request.headers.value('authorization'), isNull);
      await reply(request, {'accepted': true});
    });
    final store = MemoryDeviceStore(scope(peer.origin));
    final transitionId = newDeviceRequestId();
    await store.commit(
      await store.load(),
      DeviceState(
        generation: 1,
        authTransitionUnknown: true,
        authTransitionId: transitionId,
      ),
    );
    final transport = DeviceTransport(store);
    addTearDown(transport.close);
    expect(
      await transport.invokePublic('auth.send_verification_email', {
        'email': 'user@example.test',
      }),
      {'accepted': true},
    );
    expect((await store.load()).authTransitionId, transitionId);
    await expectLater(
      transport.invokePublic('example.list', {}),
      throwsA(clientFailure('failed_precondition')),
    );
    expect(seen, ['/auth.send_verification_email']);
  });

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
        isA<ClientError>().having((e) => e.code, 'code', 'resource_exhausted'),
      ),
    );
    expect((await store.load()).generation, 1);
  });
}
