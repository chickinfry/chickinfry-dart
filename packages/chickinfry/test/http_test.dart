import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('C-01 JSON POST preserves wire names and values', () async {
    final peer = await Peer.start((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/account_status.get_status');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(await readBody(request), {
        'user_id': 'one',
        'text': '\uD55C\uAE00😀',
        'none': null,
      });
      await reply(request, {
        'created_at': '2026-10-13T01:02:03.123456Z',
        'items': <Object?>[],
      });
    });
    final transport = peer.transport();
    expect(
      await transport.invoke('account_status.get_status', {
        'user_id': 'one',
        'text': '\uD55C\uAE00😀',
        'none': null,
      }),
      {'created_at': '2026-10-13T01:02:03.123456Z', 'items': <Object?>[]},
    );
    for (final name in [
      'Thing.get',
      'thing.get/extra',
      'thing.get?',
      'thing.get#',
      'thing',
      'thing.get\n',
    ]) {
      await expectLater(
        transport.invoke(name, {}),
        throwsA(clientFailure('invalid_input')),
      );
    }
    await expectLater(
      transport.invoke('thing.get', {'value': Object()}),
      throwsA(clientFailure('invalid_input')),
    );
    expect(peer.requests, 1);
  });

  test('C-02 origin validation and normalization', () {
    for (final origin in [
      'https://EXAMPLE.COM:443/',
      'http://127.0.0.1:1234/',
      'http://127.255.255.255',
      'http://[::1]:1234',
    ]) {
      final transport = HttpTransport(origin);
      transport.close();
    }
    final transport = HttpTransport('https://EXAMPLE.COM:443/');
    addTearDown(transport.close);
    expect(transport.origin, 'https://example.com');
    for (final origin in [
      'http://localhost',
      'http://example.com',
      'http://127.1',
      'http://0x7f000001',
      'http://2130706433',
      'http://0177.0.0.1',
      'http://127.00.0.1',
      'http://[::ffff:127.0.0.1]',
      'http://[0:0:0:0:0:0:0:1]',
      'https://user@example.com',
      'https://@example.com',
      'https://example.com/api',
      'https://example.com/%2f',
      'https://example.com/.',
      'https://example.com/a/..',
      'https://example.com/../',
      'http://127.0.0.1/.',
      'http://127.0.0.1/a/..',
      'http://127.0.0.1/../',
      'http://%31%32%37.0.0.1',
      'https://%65xample.com',
      'https://example.com//',
      'https://example.com?',
      'https://example.com#',
      'https://example.com:0',
      'https://example.com:65536',
      '//example.com',
      'not a URL',
    ]) {
      expect(
        () => HttpTransport(origin),
        throwsA(clientFailure('invalid_origin')),
        reason: 'Must reject the invalid origin $origin.',
      );
    }
    expect(
      () => transport.withSession(
        MemorySessionStore(
          'https://other.example',
          'other',
          Record(credentials()),
        ),
      ),
      throwsA(clientFailure('invalid_origin')),
    );
    expect(
      () => HttpTransport('https://example.com', timeout: Duration.zero),
      throwsArgumentError,
    );
  });

  test(
    'C-07 bearer copies leave the original anonymous and share root lifetime',
    () async {
      final authenticated = <bool>[];
      final peer = await Peer.start((request) async {
        authenticated.add(
          request.headers.value('authorization') == 'Bearer $accessToken',
        );
        await request.drain<void>();
        await reply(request, {});
      });
      final root = peer.transport();
      final signed = root.withBearer(accessToken);
      await signed.invoke('thing.get', {});
      signed.close();
      await root.invoke('thing.get', {});
      expect(authenticated, [true, false]);
      for (final token in ['', 'bad', '$accessToken\n']) {
        expect(
          () => root.withBearer(token),
          throwsA(clientFailure('invalid_token')),
        );
      }
      root.close();
      await expectLater(
        signed.invoke('thing.get', {}),
        throwsA(clientFailure('network_error')),
      );
      expect(peer.requests, 2);
    },
  );

  test(
    'C-03 transport rejects malformed JSON, UTF-8 and non-object roots',
    () async {
      final bodies = <List<int>>[
        utf8.encode('['),
        utf8.encode('[]'),
        utf8.encode('null'),
        [0xff],
      ];
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        request.response.add(bodies.removeAt(0));
        await request.response.close();
      });
      final transport = peer.transport();
      for (var i = 0; i < 4; i++) {
        await expectLater(
          transport.invoke('thing.get', {}),
          throwsA(clientFailure('invalid_response', status: 200)),
        );
      }
    },
  );

  test(
    'C-06 server errors preserve unknown codes and status without body details',
    () async {
      final statuses = [403, 429, 500, 404];
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        await reply(request, {
          'error': 'future_server_error',
          'detail': 'private-detail',
        }, status: statuses.removeAt(0));
      });
      final transport = peer.transport();
      for (final status in [403, 429, 500, 404]) {
        try {
          await transport.invoke('thing.get', {});
          fail('Expected operation failure.');
        } on OperationError catch (error) {
          expect(error.code, 'future_server_error');
          expect(error.status, status);
          expect(error.toString().contains('private-detail'), isFalse);
        }
      }
    },
  );

  test(
    'C-06 malformed error envelopes become invalid_response with status',
    () async {
      final bodies = [
        '<html>private-detail</html>',
        '',
        '{}',
        '{"error":null}',
        '{"error":42}',
        '{"error":"Not.Valid"}',
      ];
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        request.response.statusCode = 503;
        request.response.write(bodies.removeAt(0));
        await request.response.close();
      });
      final transport = peer.transport();
      for (var i = 0; i < 6; i++) {
        await expectLater(
          transport.invoke('thing.get', {}),
          throwsA(clientFailure('invalid_response', status: 503)),
        );
      }
    },
  );

  test('error messages render code-specific guidance and generic fallback', () {
    expect(
      const ClientException('unsupported_platform').toString(),
      contains('browser support is planned'),
    );
    expect(
      const ClientException('invalid_token').toString(),
      contains('pass the access token string'),
    );
    expect(
      const ClientException('invalid_response', status: 503).toString(),
      contains("check that the origin points to your project's server"),
    );
    expect(
      const ClientException('response_too_large', status: 200).toString(),
      contains('(response_too_large, HTTP 200)'),
    );
    expect(
      const ClientException('network_error').toString(),
      'The request failed before a response arrived; check network '
      'connectivity and the origin. (network_error)',
    );
    expect(
      const OperationError('operation_failed', 500).toString(),
      contains('Handle it by branching on code'),
    );
    expect(
      const ClientException('future_local_error').toString(),
      'Client failed (future_local_error).',
    );
    expect(
      const ClientException('future_local_error', status: 599).toString(),
      'Client failed (future_local_error, HTTP 599).',
    );
  });

  test(
    'C-04 UTF-8 request boundary is inclusive and oversize is never sent',
    () async {
      final lengths = <int>[];
      final peer = await Peer.start((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        lengths.add(bytes.length);
        await reply(request, {});
      });
      final transport = peer.transport();
      const overhead = 12;
      await transport.invoke('thing.get', {
        'value': 'a' * (4 * 1024 * 1024 - overhead),
      });
      await expectLater(
        transport.invoke('thing.get', {
          'value': 'a' * (4 * 1024 * 1024 - overhead + 1),
        }),
        throwsA(clientFailure('request_too_large')),
      );
      await expectLater(
        transport.invoke('thing.get', {'value': '\uD55C😀\\\n' * (512 * 1024)}),
        throwsA(clientFailure('request_too_large')),
      );
      expect(lengths, [4 * 1024 * 1024]);
    },
  );

  test(
    'C-04 response byte boundary is inclusive for success and error streams',
    () async {
      var index = 0;
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        final current = index++;
        request.response.statusCode = current == 2 ? 500 : 200;
        final padding = 'a' * (1024 * 1024 - 12 + (current == 0 ? 0 : 1));
        request.response.write('{"value":"$padding"}');
        await request.response.close();
      });
      final transport = peer.transport();
      final result =
          await transport.invoke('thing.get', {}) as Map<String, Object?>;
      expect((result['value'] as String).length, 1024 * 1024 - 12);
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('response_too_large', status: 200)),
      );
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('response_too_large', status: 500)),
      );
    },
  );

  for (final status in [301, 302, 303, 307, 308]) {
    test('C-05 redirect $status never reaches its destination', () async {
      final destination = await Peer.start((request) async {
        await request.drain<void>();
        await reply(request, {});
      });
      final source = await Peer.start((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.set(
          'location',
          '${destination.origin}/thing.get',
        );
        await request.response.close();
      });
      await expectLater(
        source.transport().withBearer(accessToken).invoke('thing.get', {}),
        throwsA(operationFailure('redirect_not_allowed', status)),
      );
      expect(destination.requests, 0);
      expect(source.requests, 1);
    });
  }

  test(
    'Proxy selection preserves the environment route without direct requests',
    () async {
      final origin = await Peer.start((request) async {
        await request.drain<void>();
        await reply(request, {});
      });
      final proxy = await Peer.start((request) async {
        expect(request.uri.toString(), '${origin.origin}/thing.get');
        expect(request.headers.value('authorization'), 'Bearer $accessToken');
        await request.drain<void>();
        await reply(request, {});
      });
      await HttpOverrides.runZoned(
        () async {
          final transport = origin.transport().withBearer(accessToken);
          expect(await transport.invoke('thing.get', {}), <String, Object?>{});
        },
        findProxyFromEnvironment: (url, environment) {
          return 'PROXY 127.0.0.1:${proxy.server.port}';
        },
      );
      print(
        'Proxy selection: origin=${origin.requests}; proxy=${proxy.requests}',
      );
      expect(origin.requests, 0);
      expect(proxy.requests, 1);
    },
  );

  test(
    'Proxy CONNECT preserves app routing, TLS verification and caller deadline',
    () async {
      final serverContext = SecurityContext()
        ..useCertificateChain('test/fixtures/server_chain.pem')
        ..usePrivateKey('test/fixtures/server_key.pem');
      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() => origin.close(force: true));
      var requests = 0;
      origin.listen((request) async {
        requests++;
        expect(request.headers.value('authorization'), 'Bearer $accessToken');
        await request.drain<void>();
        request.response.persistentConnection = false;
        await reply(request, {});
      });
      var stalled = false;
      var tunnels = 0;
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(proxy.close);
      proxy.listen((socket) {
        addTearDown(socket.destroy);
        var headers = '';
        var established = false;
        Socket? upstream;
        socket.listen(
          (bytes) async {
            if (established) {
              upstream?.add(bytes);
              return;
            }
            headers += latin1.decode(bytes);
            if (!headers.contains('\r\n\r\n')) return;
            established = true;
            tunnels++;
            expect(
              headers.startsWith(
                'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\n',
              ),
              isTrue,
            );
            if (!stalled) {
              final target = await Socket.connect('127.0.0.1', origin.port);
              upstream = target;
              addTearDown(target.destroy);
              target.listen(
                socket.add,
                onError: (_) => socket.destroy(),
                onDone: socket.destroy,
              );
            }
            socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
            await socket.flush();
          },
          onError: (_) => upstream?.destroy(),
          onDone: () => upstream?.destroy(),
        );
      });
      final clientContext = SecurityContext(withTrustedRoots: false);
      final native = HttpClient(context: clientContext)
        ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      final root = HttpOverrides.runZoned(
        () => HttpTransport(
          'https://127.0.0.1:${origin.port}',
          timeout: const Duration(milliseconds: 200),
        ),
        createHttpClient: (_) => native,
      );
      native.connectionTimeout = const Duration(seconds: 2);
      addTearDown(root.close);
      final transport = root.withBearer(accessToken);
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('network_error')),
      );
      expect(requests, 0);
      expect(tunnels, 1);
      clientContext.setTrustedCertificates('test/fixtures/ca.pem');
      expect(await transport.invoke('thing.get', {}), <String, Object?>{});
      expect(requests, 1);
      expect(tunnels, 2);
      stalled = true;
      final watch = Stopwatch()..start();
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('request_timeout')),
      );
      print(
        'Proxy CONNECT: requests=$requests; tunnels=$tunnels; '
        'deadlineReturned=${watch.elapsedMilliseconds}ms',
      );
      expect(watch.elapsedMilliseconds, lessThan(800));
      expect(requests, 1);
      expect(tunnels, 3);
    },
  );

  test(
    'C-05 deadline closes stalled TLS and keeps the transport usable',
    () async {
      final disconnected = Completer<int>();
      final watch = Stopwatch();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      addTearDown(server.close);
      server.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) {
              disconnected.complete(watch.elapsedMilliseconds);
            }
          },
        );
      });
      final native = HttpClient()..findProxy = (_) => 'DIRECT';
      final transport = HttpOverrides.runZoned(
        () => HttpTransport(
          'https://127.0.0.1:$port',
          timeout: const Duration(milliseconds: 200),
        ),
        createHttpClient: (_) => native,
      );
      native.connectionTimeout = const Duration(seconds: 2);
      addTearDown(transport.close);
      watch.start();
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('request_timeout')),
      );
      final returnedAt = watch.elapsedMilliseconds;
      final closedAt = await disconnected.future.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () => -1,
      );
      print(
        'TLS deadline: returned=${returnedAt}ms; peerClosed=${closedAt}ms; '
        'connectionTimeout=2000ms',
      );
      expect(
        closedAt,
        inInclusiveRange(0, 800),
        reason: 'Request cancellation must close TLS before connectionTimeout.',
      );
      await server.close();
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/server_chain.pem')
        ..usePrivateKey('test/fixtures/server_key.pem');
      final next = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        port,
        context,
      );
      addTearDown(() => next.close(force: true));
      var requests = 0;
      var receivedBytes = 0;
      next.listen((request) async {
        requests++;
        receivedBytes = await request.fold<int>(
          0,
          (length, chunk) => length + chunk.length,
        );
        await reply(request, {'value': 'a' * (256 * 1024)});
      });
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('network_error')),
      );
      SecurityContext.defaultContext.setTrustedCertificates(
        'test/fixtures/ca.pem',
      );
      final result = await transport.invoke('thing.get', {
        'value': 'a' * (256 * 1024),
      }) as Map<String, Object?>;
      expect((result['value'] as String).length, 256 * 1024);
      expect(receivedBytes, 256 * 1024 + 12);
      expect(requests, 1);
    },
  );

  for (final headersSent in [false, true]) {
    test(
      'C-05 deadline aborts ${headersSent ? 'body' : 'headers'} and keeps other connections usable',
      () async {
        final disconnected = Completer<void>();
        var first = true;
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          if (!first) {
            await reply(request, {});
            return;
          }
          first = false;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          addTearDown(socket.destroy);
          socket.listen(
            (_) {},
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
          if (headersSent) {
            socket.add(
              utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{'),
            );
            await socket.flush();
          }
        });
        final transport = peer.transport(
          timeout: const Duration(milliseconds: 200),
        );
        await expectLater(
          transport
              .invoke('thing.write', {})
              .timeout(const Duration(seconds: 1)),
          throwsA(
            clientFailure('request_timeout', status: headersSent ? 200 : null),
          ),
        );
        await disconnected.future.timeout(const Duration(seconds: 2));
        expect(await transport.invoke('thing.get', {}), <String, Object?>{});
        expect(peer.requests, 2);
      },
    );
  }

  test('C-04 oversized unbounded stream aborts at the limit without waiting for EOF', () async {
    final disconnected = Completer<void>();
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      final socket = await request.response.detachSocket(writeHeaders: false);
      addTearDown(socket.destroy);
      socket.listen(
        (_) {},
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n'));
      socket.add(List.filled(1024 * 1024 + 1, 32));
      await socket.flush();
    });
    await expectLater(
      peer.transport().invoke('thing.get', {}),
      throwsA(clientFailure('response_too_large', status: 200)),
    );
    await disconnected.future.timeout(const Duration(seconds: 2));
    expect(peer.requests, 1);
  });

  test('C-05 committed write with lost response is never replayed', () async {
    var writes = 0;
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      writes++;
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    });
    await expectLater(
      peer.transport().invoke('thing.write', {}),
      throwsA(clientFailure('network_error')),
    );
    expect(writes, 1);
    expect(peer.requests, 1);
  });

  test('C-05 response lost mid-body reports the received status', () async {
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.add(
        utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{'),
      );
      await socket.flush();
      await socket.close();
    });
    await expectLater(
      peer.transport().invoke('thing.get', {}),
      throwsA(
        isA<ClientException>()
            .having((error) => error.code, 'code', 'network_error')
            .having((error) => error.status, 'status', 200)
            .having(
              (error) => error.toString(),
              'message',
              'The connection failed while the response was being read; '
                  'check network connectivity and the origin. '
                  '(network_error, HTTP 200)',
            ),
      ),
    );
    expect(peer.requests, 1);
  });
}
