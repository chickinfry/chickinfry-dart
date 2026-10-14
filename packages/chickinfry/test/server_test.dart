import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chickinfry/server.dart';
import 'package:test/test.dart';

void main() {
  var calls = 0;
  late Application app;
  setUp(() {
    calls = 0;
    app = Application({
      'demo.echo': (context, input) async {
        if (input['request_id'] is! String || input['message'] is! String) {
          throw const OperationError('invalid_input', 400);
        }
        calls++;
        switch (input['message']) {
          case 'business':
            throw const OperationError('conflict', 409);
          case 'protected':
            requireSession(context);
          case 'sentinel':
            throw StateError('SECRET_SENTINEL');
          case 'badcode':
            throw const OperationError('SECRET_SENTINEL', 409);
          case 'badstatus':
            throw const OperationError('conflict', 200);
        }
        return {'request_id': input['request_id'], 'message': input['message']};
      },
    });
  });
  Future<ServerResponse> call({
    String method = 'POST',
    String path = '/demo.echo',
    String contentType = 'application/json',
    String? authorization,
    Object? input,
    List<int>? bytes,
  }) => app.handle(
    ServerRequest(
      method: method,
      uri: Uri.parse('https://example.test$path'),
      headers: {
        'Content-Type': contentType,
        if (authorization != null) 'authorization': authorization,
      },
    ),
    Stream.value(
      bytes ??
          utf8.encode(
            jsonEncode(
              input ?? {'request_id': 'not-a-uuid', 'message': '\uC548\uB155\uD558\uC138\uC694'},
            ),
          ),
    ),
    rawUri: 'https://example.test$path',
  );

  test(
    'wire values remain strings and anonymous contexts have no session',
    () async {
      final response = await call();
      expect(response.status, 200);
      expect(jsonDecode(response.body), {
        'request_id': 'not-a-uuid',
        'message': '\uC548\uB155\uD558\uC138\uC694',
      });
      expect(calls, 1);
      expect(() => runApplication(app), throwsUnsupportedError);
    },
  );
  test(
    'non-object input never invokes even an unvalidated operation',
    () async {
      var invoked = 0;
      final boundary = Application({
        'demo.echo': (context, input) async {
          invoked++;
          return {};
        },
      });
      final response = await boundary.handle(
        ServerRequest(
          method: 'POST',
          uri: Uri.parse('https://example.test/demo.echo'),
          headers: {'content-type': 'application/json'},
        ),
        Stream.value(utf8.encode('[]')),
      );
      expect(response.status, 400);
      expect(invoked, 0);
    },
  );
  test('HTTP and malformed input fail before handler work', () async {
    for (final response in [
      await call(method: 'GET'),
      await call(path: '/missing'),
      await call(path: '/demo.echo?x=1'),
      await call(path: '/demo%2eecho'),
      await call(contentType: 'text/plain'),
      await call(bytes: [0xff]),
      await call(bytes: utf8.encode('{')),
      await call(input: []),
      await call(input: {'message': 'x'}),
      await call(input: {'request_id': null, 'message': 'x'}),
      await call(input: {'request_id': 4, 'message': 'x'}),
      await call(authorization: 'Bearer wrong'),
    ]) {
      expect(response.status, isNot(200));
    }
    expect(calls, 0);
  });
  test('exact body limit succeeds; excess stops reading and cancels', () async {
    final prefix = utf8.encode('{"request_id":"x","message":"');
    final suffix = utf8.encode('"}');
    final exact = [
      ...prefix,
      ...Uint8List(Application.maxRequestBytes - prefix.length - suffix.length)
        ..fillRange(
          0,
          Application.maxRequestBytes - prefix.length - suffix.length,
          97,
        ),
      ...suffix,
    ];
    expect((await call(bytes: exact)).status, 200);
    var reads = 0;
    var cancelled = false;
    Stream<List<int>> chunks() async* {
      try {
        reads++;
        yield exact;
        reads++;
        yield [32];
        reads++;
        yield [32];
      } finally {
        cancelled = true;
      }
    }

    final response = await app.handle(
      ServerRequest(
        method: 'POST',
        uri: Uri.parse('https://example.test/demo.echo'),
        headers: {'content-type': 'application/json'},
      ),
      chunks(),
    );
    expect(response.status, 413);
    expect(response.body, '{"error":"request_too_large"}');
    expect(reads, 2);
    expect(cancelled, isTrue);
    expect(calls, 1);
  });
  test(
    'only permitted business errors escape the generic failure boundary',
    () async {
      for (final message in [
        'business',
        'protected',
        'sentinel',
        'badcode',
        'badstatus',
      ]) {
        final response = await call(
          input: {'request_id': 'not-a-uuid', 'message': message},
        );
        expect(
          response.status,
          message == 'business'
              ? 409
              : message == 'protected'
              ? 401
              : 500,
        );
        expect(
          response.body,
          message == 'business'
              ? '{"error":"conflict"}'
              : message == 'protected'
              ? '{"error":"unauthenticated"}'
              : '{"error":"operation_failed"}',
        );
      }
    },
  );
  test(
    'pending handler does not serialize another request or share metadata',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      final contexts = <Context>[];
      final concurrent = Application({
        'demo.echo': (context, input) async {
          contexts.add(context);
          if (input['message'] == 'A') {
            arrived.complete();
            await release.future;
          }
          return {
            'message': input['message'],
            'header': context.request.headers['x-request'],
          };
        },
      });
      Future<ServerResponse> invoke(String message) => concurrent.handle(
        ServerRequest(
          method: 'POST',
          uri: Uri.parse('https://example.test/demo.echo'),
          headers: {'content-type': 'application/json', 'x-request': message},
        ),
        Stream.value(utf8.encode(jsonEncode({'message': message}))),
      );
      final first = invoke('A');
      await arrived.future;
      final second = await invoke('B');
      expect(jsonDecode(second.body), {'message': 'B', 'header': 'B'});
      release.complete();
      expect(jsonDecode((await first).body), {'message': 'A', 'header': 'A'});
      expect(contexts[0].session, isNull);
      expect(
        () => contexts[0].request.headers['x-request'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
}
