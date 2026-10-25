import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/http_client_io.dart' as native;
import 'package:chickinfry/src/testing/conformance.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('RT-3 only proven stable SDK versions allow retained bounds', () {
    for (final version in ['3.13.0 (stable)', '3.13.5 (stable)']) {
      expect(provenSdk(version), isTrue);
    }
    for (final version in [
      '',
      'unknown',
      '3.13.6 (stable)',
      '3.13.5 (beta)',
      '3.13.50 (stable)',
    ]) {
      expect(provenSdk(version), isFalse);
      final call = conformanceCall('sdk', 'thing.get', Observer());
      final attempt = ConformanceHttpAttempt(call, 'thing.get');
      attempt.observeConnection(Object(), 384 * 1024);
      attempt.confirmRetainedBytes(version, profiled: false, encoding: null);
      attempt.transport(ConformanceTransportPhase.headers);
      expect(attempt.libraryRetainedBytes, isNull);
      expect(call.transportEvents.last.retainedBytes, isNull);
      expect(call.transportEvents.last.peakRetainedBytes, isNull);
    }
  });

  test(
    'C-04 native bridge caps reads and guards paused or destroyed readers',
    () async {
      final raw = ControlledRawSocket([
        List.filled(8192, 1),
        [2],
      ]);
      final socket = native.createSocketForTesting(raw);
      addTearDown(socket.destroy);
      raw.events.add(RawSocketEvent.read);
      await Future<void>.delayed(Duration.zero);
      expect(raw.readArguments, isEmpty);
      final first = Completer<void>();
      final second = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = socket.listen((bytes) {
        if (!first.isCompleted) {
          expect(bytes.length, 8192);
          subscription.pause();
          first.complete();
        } else {
          expect(bytes, [2]);
          second.complete();
        }
      });
      await first.future;
      expect(raw.readEventsEnabled, isFalse);
      raw.events.add(RawSocketEvent.read);
      await Future<void>.delayed(Duration.zero);
      expect(raw.readArguments, [8192]);
      subscription.resume();
      await second.future;
      expect(raw.readArguments, [8192, 8192]);
      raw.events.add(RawSocketEvent.read);
      socket.destroy();
      await Future<void>.delayed(Duration.zero);
      expect(raw.readArguments, [8192, 8192]);
    },
  );

  test('C-04 accumulated small views own their bytes before backing reuse', () async {
    final head = utf8.encode('{"value":"first');
    final tail = utf8.encode('second"}');
    final raw = ControlledRawSocket([
      utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: ${head.length + tail.length}\r\n\r\n',
          ) +
          head,
      tail,
    ]);
    final socket = native.createSocketForTesting(raw);
    addTearDown(socket.destroy);
    final client = BridgedHttpClient(
      HttpClient()..findProxy = (_) => 'DIRECT',
      socket,
    );
    final transport = HttpOverrides.runZoned(
      () => HttpTransport('http://127.0.0.1'),
      createHttpClient: (_) => client,
    );
    addTearDown(transport.close);
    expect(await transport.invoke('thing.get', {}), {'value': 'firstsecond'});
    expect(raw.readArguments, [8192, 8192]);
  });

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
    final constructions = <ConformanceConstruction>[];
    final call = conformanceCall(
      'constructor',
      'client.create',
      Observer(
        onRecord: (event) {
          if (event is ConformanceConstruction) constructions.add(event);
        },
      ),
    );
    for (final origin in [
      'https://EXAMPLE.COM:443/',
      'http://127.0.0.1:1234/',
      'http://127.255.255.255',
      'http://[::1]:1234',
    ]) {
      final transport = withConformanceCall(call, () => HttpTransport(origin));
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
        () => withConformanceCall(call, () => HttpTransport(origin)),
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
    if (conformanceEnabled) {
      expect(constructions.where((event) => event.succeeded), isNotEmpty);
      expect(constructions.where((event) => !event.succeeded), isNotEmpty);
      expect(
        constructions.map((event) => event.networkEntries),
        everyElement(0),
      );
    } else {
      expect(constructions, isEmpty);
    }
  });

  if (conformanceEnabled) {
    test(
      'RT-2 separates connection refusal, actual writes and lost response',
      () async {
        final portProbe = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final unusedPort = portProbe.port;
        await portProbe.close();
        final refused = HttpTransport('http://127.0.0.1:$unusedPort');
        addTearDown(refused.close);
        final beforeSend = conformanceCall(
          'before-send',
          'thing.write',
          Observer(),
        );
        await expectLater(
          withConformanceCall(
            beforeSend,
            () => refused.invoke('thing.write', {}),
          ),
          throwsA(clientFailure('network_error')),
        );
        expect(beforeSend.httpObservation!.socketBytesWritten, 0);
        expect(beforeSend.httpObservation!.outcomeUnknown, isFalse);
        expect(beforeSend.httpObservation!.cancelObserved, isNull);

        final server = await RawServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(server.close);
        var received = 0;
        server.listen((socket) {
          addTearDown(socket.close);
          socket.listen((event) {
            if (event == RawSocketEvent.read) {
              received += socket.read(1)?.length ?? 0;
              unawaited(socket.close());
            }
          });
        });
        final dropped = HttpTransport('http://127.0.0.1:${server.port}');
        addTearDown(dropped.close);
        final sent = conformanceCall('partial-send', 'thing.write', Observer());
        await expectLater(
          withConformanceCall(
            sent,
            () => dropped.invoke('thing.write', {
              'data': 'x' * (4 * 1024 * 1024 - 512),
            }),
          ),
          throwsA(clientFailure('network_error')),
        );
        expect(received, greaterThan(0));
        expect(sent.httpObservation!.socketBytesWritten, greaterThan(0));
        expect(sent.httpObservation!.pendingSocketBytes, greaterThan(0));
        expect(sent.httpObservation!.responseConfirmed, isFalse);
        expect(sent.httpObservation!.outcomeUnknown, isTrue);

        final peer = await Peer.start((request) async {
          await request.drain<void>();
          await reply(request, {});
        });
        final transport = peer.transport();
        final invalid = conformanceCall(
          'invalid-model',
          'thing.write',
          Observer(),
        );
        await expectLater(
          withConformanceCall(invalid, () async {
            final value = await transport.invoke('thing.write', {});
            if (value is! Map<String, Object?> || value['id'] is! String) {
              throw const ClientException('invalid_response');
            }
            return value['id'];
          }),
          throwsA(clientFailure('invalid_response')),
        );
        expect(peer.requests, 1);
        expect(invalid.httpObservation!.status, 200);
        expect(invalid.httpObservation!.bodyComplete, isTrue);
        expect(invalid.httpObservation!.socketBytesWritten, greaterThan(0));
        expect(invalid.httpObservation!.responseConfirmed, isFalse);
        expect(invalid.httpObservation!.outcomeUnknown, isTrue);
        expect(
          invalid.transportEvents.where(
            (event) => event.phase == ConformanceTransportPhase.completed,
          ),
          hasLength(1),
        );
      },
    );

    test('RT-3 observes live bytes, copy peak and generated-call completion', () async {
      final release = Completer<void>();
      final read = Completer<void>();
      final readerClosed = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final head = utf8.encode('{"value":"first');
      final tail = utf8.encode('second"}');
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        final socket = await request.response.detachSocket(writeHeaders: false);
        addTearDown(socket.destroy);
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: ${head.length + tail.length}\r\n\r\n',
          ),
        );
        socket.add(head);
        await socket.flush();
        await release.future;
        socket.add(tail);
        await socket.close();
      });
      final transport = peer.transport();
      final call = conformanceCall(
        'live-reader',
        'thing.get',
        Observer(
          onRecord: (event) {
            if (event is ConformanceTransportEvent &&
                event.phase == ConformanceTransportPhase.read &&
                !read.isCompleted) {
              read.complete();
            }
            if (event is ConformanceTransportEvent &&
                event.phase == ConformanceTransportPhase.readerClosed &&
                !readerClosed.isCompleted) {
              readerClosed.complete();
            }
          },
        ),
      );
      final sdkResult = Completer<void>();
      final pending = withConformanceCall(call, () async {
        final value = await transport.invoke('thing.get', {});
        expect(value, {'value': 'firstsecond'});
        await sdkResult.future;
      });
      await read.future;
      expect(call.httpObservation!.readBytes, head.length);
      expect(call.httpObservation!.runtimeRetainedBytes, head.length);
      expect(call.transportEvents.last.runtimeRetainedBytes, 0);
      expect(
        call.transportEvents.every(
          (event) =>
              event.libraryRetainedBytes == 0 &&
              event.retainedBytes == event.runtimeRetainedBytes &&
              event.peakRetainedBytes == event.runtimePeakRetainedBytes,
        ),
        isTrue,
      );
      release.complete();
      await readerClosed.future;
      expect(call.httpObservation!.responseConfirmed, isFalse);
      expect(call.httpObservation!.outcomeUnknown, isTrue);
      expect(
        call.transportEvents.any(
          (event) => event.phase == ConformanceTransportPhase.completed,
        ),
        isFalse,
      );
      sdkResult.complete();
      await pending;
      expect(call.httpObservation!.readBytes, head.length + tail.length);
      expect(
        call.transportEvents.last.phase,
        ConformanceTransportPhase.completed,
      );
      expect(call.transportEvents.last.runtimeRetainedBytes, 0);
      expect(
        call.transportEvents.last.runtimePeakRetainedBytes,
        (head.length + tail.length) * 2,
      );
      expect(
        call.transportEvents.last.peakRetainedBytes,
        (head.length + tail.length) * 2,
      );
      expect(call.transportEvents.last.retainedBytes, 0);
      expect(call.httpObservation!.responseConfirmed, isTrue);
      expect(call.httpObservation!.outcomeUnknown, isFalse);
      expect(call.httpObservation!.cancelObserved, isNull);
      expect(
        call.transportEvents.where(
          (event) => event.phase == ConformanceTransportPhase.completed,
        ),
        hasLength(1),
      );
      for (var i = 1; i < call.transportEvents.length; i++) {
        expect(
          call.transportEvents[i].sequence,
          greaterThan(call.transportEvents[i - 1].sequence),
        );
        expect(
          call.transportEvents[i].elapsedMs,
          greaterThanOrEqualTo(call.transportEvents[i - 1].elapsedMs),
        );
        expect(
          call.transportEvents[i].peakRetainedBytes,
          greaterThanOrEqualTo(call.transportEvents[i - 1].peakRetainedBytes!),
        );
      }
    });

    test('RT-3 confirms every request on a reused direct connection', () async {
      final ports = <int>[];
      final peer = await Peer.start((request) async {
        ports.add(request.connectionInfo!.remotePort);
        await reply(request, {});
      });
      final transport = peer.transport();
      for (var i = 0; i < 2; i++) {
        final call = conformanceCall('reuse-$i', 'thing.get', Observer());
        await withConformanceCall(
          call,
          () => transport.invoke('thing.get', {}),
        );
        expect(call.httpObservation!.libraryRetainedBytes, 0);
        expect(call.transportEvents.last.retainedBytes, 0);
        expect(call.transportEvents.last.peakRetainedBytes, isNotNull);
      }
      expect(ports[1], ports[0]);
    });

    for (final profiled in [false, true]) {
      test('RT-3 ${profiled ? 'profiler' : 'gzip'} stays unknown', () async {
        final wasProfiled = HttpClient.enableTimelineLogging;
        HttpClient.enableTimelineLogging = profiled;
        addTearDown(() => HttpClient.enableTimelineLogging = wasProfiled);
        final peer = await Peer.start((request) async {
          if (profiled) {
            await reply(request, {'value': 'kept'});
          } else {
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(gzip.encode(utf8.encode('{"value":"kept"}')));
            await request.response.close();
          }
        });
        final call = conformanceCall('unknown', 'thing.get', Observer());
        expect(
          await withConformanceCall(
            call,
            () => peer.transport().invoke('thing.get', {}),
          ),
          {'value': 'kept'},
        );
        expect(call.transportEvents, isNotEmpty);
        for (final event in call.transportEvents) {
          expect(event.libraryRetainedBytes, isNull);
          expect(event.retainedBytes, isNull);
          expect(event.peakRetainedBytes, isNull);
        }
      });
    }

    test('RT-3 unknown and multiple exchanges never recover a known peak', () {
      final call = conformanceCall('exchanges', 'thing.get', Observer());
      final first = ConformanceHttpAttempt(call, 'thing.get');
      first.transport(ConformanceTransportPhase.headers);
      first.libraryRetainedBytes = 0;
      first.retain(10);
      first.transport(ConformanceTransportPhase.read);
      expect(call.transportEvents.last.retainedBytes, isNull);
      final second = ConformanceHttpAttempt(call, 'thing.get');
      second.libraryRetainedBytes = 0;
      second.transport(ConformanceTransportPhase.headers);
      expect(call.transportEvents.last.peakRetainedBytes, isNull);
      final connection = Object();
      second.observeConnection(connection, 0);
      second.observeConnection(connection, 0);
      expect(second.fixedRetainedBytes, 0);
      second.observeConnection(Object(), 0);
      expect(second.fixedRetainedBytes, isNull);
      second.observeConnection(connection, 0);
      expect(second.fixedRetainedBytes, isNull);

      final repeated = conformanceCall('repeated', 'thing.get', Observer());
      final known = ConformanceHttpAttempt(repeated, 'thing.get');
      known.libraryRetainedBytes = 0;
      known.transport(ConformanceTransportPhase.headers);
      expect(repeated.transportEvents.last.retainedBytes, 0);
      final replay = ConformanceHttpAttempt(repeated, 'thing.get');
      replay.libraryRetainedBytes = 0;
      replay.transport(ConformanceTransportPhase.headers);
      expect(repeated.transportEvents.last.retainedBytes, isNull);
      expect(repeated.transportEvents.last.peakRetainedBytes, isNull);
    });

    test('RT-1 constructor monitor counts a real native HTTP send', () async {
      final peer = await Peer.start((request) => reply(request, {}));
      final client = native.createClient(const Duration(seconds: 2));
      addTearDown(client.close);
      final constructions = <ConformanceConstruction>[];
      final call = conformanceCall(
        'network-constructor',
        'client.create',
        Observer(
          onRecord: (event) {
            if (event is ConformanceConstruction) constructions.add(event);
          },
        ),
      );
      final response = await withConformanceCall(
        call,
        () => observeConstruction(
          () => client.send(
            http.Request('POST', Uri.parse('${peer.origin}/thing.get')),
          ),
        ),
      );
      await response.stream.drain<void>();
      expect(peer.requests, 1);
      expect(constructions.single.httpSends, 1);
      expect(constructions.single.networkEntries, greaterThan(0));
    });
  }

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
      contains('OS secure session storage'),
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
          final call = conformanceCall('proxy', 'thing.get', Observer());
          expect(
            await withConformanceCall(
              call,
              () => transport.invoke('thing.get', {}),
            ),
            <String, Object?>{},
          );
          if (conformanceEnabled) {
            for (final event in call.transportEvents) {
              expect(event.retainedBytes, isNull);
              expect(event.peakRetainedBytes, isNull);
            }
          }
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
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/server_chain.pem')
        ..usePrivateKey('test/fixtures/server_key.pem');
      final next = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
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
      var resumeTls = false;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      addTearDown(server.close);
      server.listen((socket) async {
        addTearDown(socket.destroy);
        if (resumeTls) {
          final upstream = await Socket.connect(
            InternetAddress.loopbackIPv4,
            next.port,
          );
          addTearDown(upstream.destroy);
          socket.listen(
            upstream.add,
            onError: (_) => upstream.destroy(),
            onDone: upstream.destroy,
          );
          upstream.listen(
            socket.add,
            onError: (_) => socket.destroy(),
            onDone: socket.destroy,
          );
          return;
        }
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
      // Keep the origin port bound while subsequent connections reach TLS.
      resumeTls = true;
      await expectLater(
        transport.invoke('thing.get', {}),
        throwsA(clientFailure('network_error')),
      );
      SecurityContext.defaultContext.setTrustedCertificates(
        'test/fixtures/ca.pem',
      );
      final call = conformanceCall('tls-bound', 'thing.get', Observer());
      final result = await withConformanceCall(
        call,
        () => transport.invoke('thing.get', {'value': 'a' * (256 * 1024)}),
      ) as Map<String, Object?>;
      expect((result['value'] as String).length, 256 * 1024);
      expect(receivedBytes, 256 * 1024 + 12);
      expect(requests, 1);
      if (conformanceEnabled) {
        for (final event in call.transportEvents) {
          expect(event.libraryRetainedBytes, 393216);
          expect(event.retainedBytes, event.runtimeRetainedBytes! + 393216);
          expect(
            event.peakRetainedBytes,
            event.runtimePeakRetainedBytes! + 393216,
          );
        }
        expect(call.transportEvents.last.retainedBytes, 393216);
      }
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

  for (final (status, framing) in [
    for (final status in [200, 302, 503])
      for (final framing in ['eof', 'content-length', 'chunked'])
        (status, framing),
  ]) {
    test(
      'C-04 oversized $framing $status stream aborts without waiting for EOF',
      () async {
        final disconnected = Completer<void>();
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          addTearDown(socket.destroy);
          socket.listen(
            (_) {},
            onError: (Object error) {
              expect(error, isA<SocketException>());
              if (!disconnected.isCompleted) disconnected.complete();
            },
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
          const size = 1024 * 1024 + 1;
          final headers = switch (framing) {
            'content-length' => 'Content-Length: ${size + 1024}\r\n',
            'chunked' => 'Transfer-Encoding: chunked\r\n',
            _ => '',
          };
          socket.add([
            ...utf8.encode(
              'HTTP/1.1 $status Test\r\n${headers}Connection: close\r\n\r\n'
              '${framing == 'chunked' ? '${size.toRadixString(16)}\r\n' : ''}',
            ),
            ...List.filled(size, 32),
          ]);
          try {
            await socket.flush();
          } on SocketException {
            await disconnected.future;
          }
        });
        final call = conformanceCall(
          'oversized-$framing-$status',
          'thing.get',
          Observer(),
        );
        await expectLater(
          withConformanceCall(
            call,
            () => peer.transport().invoke('thing.get', {}),
          ),
          throwsA(
            status == 302
                ? operationFailure('redirect_not_allowed', status)
                : clientFailure('response_too_large', status: status),
          ),
        );
        await disconnected.future.timeout(const Duration(seconds: 2));
        expect(peer.requests, 1);
        if (conformanceEnabled) {
          final attempt = call.httpObservation!;
          expect(attempt.cancelRequested, isTrue);
          expect(attempt.cancelObserved, isTrue);
          expect(attempt.readerClosed, isTrue);
          expect(
            attempt.readBytes,
            status == 302 ? 0 : greaterThan(1024 * 1024),
          );
          expect(
            attempt.runtimePeakRetainedBytes,
            lessThanOrEqualTo(1024 * 1024),
          );
          expect(attempt.libraryRetainedBytes, 0);
          expect(attempt.peakRetainedBytes, attempt.runtimePeakRetainedBytes);
          for (final event in call.transportEvents) {
            expect(event.retainedBytes, event.runtimeRetainedBytes);
            expect(event.peakRetainedBytes, event.runtimePeakRetainedBytes);
          }
          final phases = call.transportEvents
              .map((event) => event.phase)
              .toList();
          expect(
            phases,
            containsAll([
              ConformanceTransportPhase.headers,
              ConformanceTransportPhase.cancelRequested,
              ConformanceTransportPhase.cancelObserved,
              ConformanceTransportPhase.readerClosed,
              ConformanceTransportPhase.completed,
            ]),
          );
          if (status != 302) {
            final limit = phases.indexOf(ConformanceTransportPhase.limit);
            expect(phases[limit - 1], ConformanceTransportPhase.read);
            expect(
              phases[limit + 1],
              ConformanceTransportPhase.cancelRequested,
            );
          } else {
            expect(phases, isNot(contains(ConformanceTransportPhase.read)));
          }
        }
      },
    );
  }

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
