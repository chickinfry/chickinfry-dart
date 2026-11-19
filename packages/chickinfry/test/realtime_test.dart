import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/realtime.dart';
import 'package:chickinfry/src/realtime_socket_io.dart';
import 'package:chickinfry/src/testing/conformance.dart';
import 'package:test/test.dart';

const ticket = '10000000-0000-4000-8000-000000000001';
const cursor = '20000000-0000-4000-8000-000000000001';

void main() {
  test('WebSocket ticket never crosses an HTTP redirect', () async {
    final trusted = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirected = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await trusted.close(force: true);
      await redirected.close(force: true);
    });
    var redirectedRequests = 0;
    redirected.listen((request) async {
      redirectedRequests++;
      request.response.statusCode = 400;
      await request.response.close();
    });
    trusted.listen((request) async {
      expect(request.uri.queryParameters['ticket'], ticket);
      request.response
        ..statusCode = 307
        ..headers.set(
          'location',
          'http://127.0.0.1:${redirected.port}/elsewhere',
        );
      await request.response.close();
    });
    final (socket, abort) = openRealtimeSocket(
      Uri.parse('ws://127.0.0.1:${trusted.port}/realtime?ticket=$ticket'),
    );
    addTearDown(abort);
    socket.stream.listen((_) {}, onError: (Object _) {});
    await expectLater(socket.ready, throwsException);
    expect(redirectedRequests, 0);
  });

  test('replays only after a matching ready confirmation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final frames = <String>[];
    server.listen((request) async {
      if (request.uri.path == '/realtime.ticket') {
        expect(request.method, 'POST');
        expect(await utf8.decoder.bind(request).join(), '{}');
        request.response.write(
          jsonEncode({
            'ticket': ticket,
            'endpoint': 'ws://127.0.0.1:${server.port}/realtime',
          }),
        );
        await request.response.close();
        return;
      }
      expect(request.uri.queryParameters, {'ticket': ticket});
      expect(request.headers.value('authorization'), isNull);
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((text) {
        final frame = jsonDecode(text as String) as Map<String, Object?>;
        final type = frame['type'] as String;
        frames.add(type);
        if (type == 'subscribe') {
          expect(frame['cursor'], '');
          socket.add(
            jsonEncode({
              'type': 'event',
              'channel': 'orders',
              'cursor': cursor,
              'previous': '',
              'payload': 42,
            }),
          );
          socket.add(
            jsonEncode({
              'type': 'ready',
              'channel': 'orders',
              'cursor': cursor,
              'acknowledge': true,
            }),
          );
        } else if (type == 'confirm') {
          socket.add(
            jsonEncode({
              'type': 'ready',
              'channel': 'orders',
              'cursor': cursor,
              'acknowledge': true,
              'confirmation': frame['confirmation'],
            }),
          );
        }
      });
    });
    final transport = HttpTransport(origin).withBearer('a' * 43);
    final result = await runZoned(
      () => createRealtimeClient(transport).subscribe('orders'),
      zoneValues: {
        realtimeProbeKey: RealtimeProbe(
          endpoint: (value) {
            expect(value, 'ws://127.0.0.1:${server.port}/realtime');
            return value as String;
          },
        ),
      },
    );
    expect((await result.events.first).payload, 42);
    expect(
      () => result.events.listen((_) {}),
      throwsA(
        isA<ClientError>().having((e) => e.code, 'code', 'failed_precondition'),
      ),
    );
    await result.unsubscribe();
    expect(frames.take(2), ['subscribe', 'confirm']);
  }, skip: !conformanceEnabled);
}
