import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chickinfry/server.dart';
import 'package:test/test.dart';

void main() {
  test('server errors accept the public argument order', () {
    const field = FieldError('message', 'required');
    const error = OperationError('invalid_input', 400, 'Check the input', [
      field,
    ]);
    expect(error.code, 'invalid_input');
    expect(error.status, 400);
    expect(error.message, 'Check the input');
    expect(error.fields.single.path, 'message');
    expect(error.fields.single.code, 'required');
  });

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
          case 'sentinel':
            throw StateError('SECRET_SENTINEL');
          case 'badcode':
            throw const OperationError('SECRET_SENTINEL', 409);
          case 'badstatus':
            throw const OperationError('conflict', 200);
          case 'notimplemented':
            throw const OperationError('not_implemented', 501);
          case 'other501':
            throw const OperationError('conflict', 501);
          case 'builtin':
            throw UnimplementedError('not_implemented');
          case 'messageonly':
            throw Exception('not_implemented');
        }
        return {'request_id': input['request_id'], 'message': input['message']};
      },
    });
  });
  Future<ServerResponse> call({
    String method = 'POST',
    String path = '/demo.echo',
    String contentType = 'application/json',
    Object? input,
    List<int>? bytes,
  }) => app.handle(
    ServerRequest(
      method: method,
      uri: Uri.parse('https://example.test$path'),
      headers: {'Content-Type': contentType},
    ),
    Stream.value(
      bytes ??
          utf8.encode(
            jsonEncode(
              input ??
                  {
                    'request_id': 'not-a-uuid',
                    'message': '\uC548\uB155\uD558\uC138\uC694',
                  },
            ),
          ),
    ),
    rawUri: 'https://example.test$path',
  );

  test('wire values remain strings without setup', () async {
    await app.prepare();
    final response = await call();
    expect(response.status, 200);
    expect(jsonDecode(response.body), {
      'request_id': 'not-a-uuid',
      'message': '\uC548\uB155\uD558\uC138\uC694',
    });
    expect(calls, 1);
    expect(() => runApplication(app), throwsUnsupportedError);
  });
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
  test(
    'setup gates concurrent requests once per application instance',
    () async {
      final started = Completer<void>();
      final release = Completer<ApplicationOptions>();
      var setupCalls = 0;
      var handlerCalls = 0;
      Application createApplication() => Application(
        {
          'demo.echo': (context, input) async {
            handlerCalls++;
            return input;
          },
        },
        setup: () {
          setupCalls++;
          if (!started.isCompleted) started.complete();
          return release.future;
        },
      );
      app = createApplication();
      expect(setupCalls, 0);
      var prepared = 0;
      final preparations = [
        app.prepare().then((_) => prepared++),
        app.prepare().then((_) => prepared++),
      ];
      final first = call();
      final second = call();
      await started.future;
      expect(setupCalls, 1);
      expect(handlerCalls, 0);
      expect(prepared, 0);
      release.complete(const ApplicationOptions());
      await Future.wait(preparations);
      expect(prepared, 2);
      for (final response in await Future.wait([first, second])) {
        expect(response.status, 200);
      }
      expect((await call()).status, 200);
      await app.prepare();
      expect(setupCalls, 1);
      expect(handlerCalls, 3);
      app = createApplication();
      expect((await call()).status, 200);
      expect(setupCalls, 2);
      expect(handlerCalls, 4);
    },
  );
  for (final synchronous in [false, true]) {
    test('setup failure is latched (synchronous: $synchronous)', () async {
      final started = Completer<void>();
      final release = Completer<ApplicationOptions>();
      var setupCalls = 0;
      var handlerCalls = 0;
      final failure = synchronous
          ? const OperationError('setup_sentinel', 409)
          : StateError('SETUP_SENTINEL');
      app = Application(
        {
          'demo.echo': (context, input) async {
            handlerCalls++;
            return input;
          },
        },
        setup: () {
          setupCalls++;
          if (!started.isCompleted) started.complete();
          if (synchronous) {
            throw failure;
          }
          return release.future;
        },
      );
      final first = call();
      final preparation = expectLater(app.prepare(), throwsA(same(failure)));
      final second = call();
      await started.future;
      expect(handlerCalls, 0);
      if (!synchronous) release.completeError(failure);
      await preparation;
      await expectLater(app.prepare(), throwsA(same(failure)));
      final responses = await Future.wait([first, second]);
      responses.add(await call());
      for (final response in responses) {
        expect(response.status, 500);
        expect(response.body, '{"error":"operation_failed"}');
        expect(response.body.toLowerCase(), isNot(contains('sentinel')));
      }
      expect(setupCalls, 1);
      expect(handlerCalls, 0);
    });
  }
  test(
    'platform registration and readiness are not public server API',
    () async {
      final build = Directory('build')..createSync(recursive: true);
      final probe = build.createTempSync('ready_public_api_');
      addTearDown(() {
        print(
          'Removing API probe: ${probe.listSync().map((entry) => entry.path)}',
        );
        probe.deleteSync(recursive: true);
      });
      final source = File('${probe.path}/negative.dart')
        ..writeAsStringSync('''
import 'package:chickinfry/server.dart' as server;

void main() {
  server.__chikDartRegister;
  server._register;
  server.ready;
}
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        'analyze',
        '--format=machine',
        source.path,
      ]);
      expect(result.exitCode, 3);
      final diagnostics = (result.stdout as String).trim().split('\n');
      expect(diagnostics, hasLength(3));
      for (final name in ['__chikDartRegister', '_register', 'ready']) {
        expect(
          diagnostics.singleWhere((line) => line.contains("'$name'")),
          contains('|UNDEFINED_PREFIXED_NAME|'),
        );
      }
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
        'sentinel',
        'badcode',
        'badstatus',
        'notimplemented',
        'other501',
        'builtin',
        'messageonly',
      ]) {
        final response = await call(
          input: {'request_id': 'not-a-uuid', 'message': message},
        );
        expect(
          response.status,
          message == 'business'
              ? 409
              : message == 'notimplemented'
              ? 501
              : 500,
        );
        expect(
          response.body,
          message == 'business'
              ? '{"error":"conflict"}'
              : message == 'notimplemented'
              ? '{"error":"not_implemented"}'
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
      expect(
        () => contexts[0].request.headers['x-request'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
  Future<ServerResponse> callWithProxyCredentials(Application app) =>
      app.handle(
        ServerRequest(
          method: 'POST',
          uri: Uri.parse('https://example.test/demo.echo'),
          headers: const {
            'content-type': 'application/json',
            'Proxy-Authorization': 'Basic transport-only',
            'Authorization': 'Bearer application-only',
            'Cookie': 'session=transport-only',
            'x-request': 'kept',
          },
        ),
        Stream.value(utf8.encode('{"message":"x"}')),
      );
  void expectNoProxyCredentials(Map<String, String> headers) {
    expect(headers.containsKey('proxy-authorization'), isFalse);
    expect(headers['proxy-authorization'], isNull);
    expect(headers.containsKey('cookie'), isTrue);
    expect(headers['authorization'] == 'Bearer application-only', isTrue);
    expect(headers['cookie'] == 'session=transport-only', isTrue);
    expect(headers.containsKey('x-request'), isTrue);
  }

  test(
    'application credentials reach handlers without proxy credentials',
    () async {
      Map<String, String>? handlerHeaders;
      var calls = 0;
      final app = Application({
        'demo.echo': (context, input) async {
          calls++;
          handlerHeaders = context.request.headers;
          return {};
        },
      });
      expect((await callWithProxyCredentials(app)).status, 200);
      expectNoProxyCredentials(handlerHeaders!);
      expect(calls, 1);
    },
  );
  test('Proxy-Authorization never reaches context factories', () async {
    ServerRequest? factoryRequest;
    final app = Application(
      {'demo.echo': (context, input) async => {}},
      contextFactory: (request, connection, secrets, log, _, _, _) {
        factoryRequest = request;
        return Context(request);
      },
    );
    expect((await callWithProxyCredentials(app)).status, 200);
    expectNoProxyCredentials(factoryRequest!.headers);
  });

  test('context factories receive lazily read secret values', () async {
    final reads = <String>[];
    String? handlerValue;
    final app = Application(
      {
        'demo.echo': (context, input) async {
          handlerValue = await (context as _SecretContext).secrets.value(
            'API_TOKEN',
          );
          return {};
        },
      },
      contextFactory: (request, connection, secrets, log, _, _, _) =>
          _SecretContext(request, secrets!),
    );
    final response = await app.handle(
      ServerRequest(
        method: 'POST',
        uri: Uri.parse('https://example.test/demo.echo'),
        headers: const {'Content-Type': 'application/json'},
      ),
      Stream.value(utf8.encode('{}')),
      rawUri: 'https://example.test/demo.echo',
      secrets: SecretValues((name) async {
        reads.add(name);
        return name == 'API_TOKEN' ? 'token-value' : null;
      }),
    );
    expect(response.status, 200);
    expect(handlerValue, 'token-value');
    expect(reads, ['API_TOKEN']);
  });

  test('unbound secret values fail with the shared contract', () async {
    final app = Application(
      {
        'demo.echo': (context, input) async {
          await (context as _SecretContext).secrets.value('API_TOKEN');
          return {};
        },
      },
      contextFactory: (request, connection, secrets, log, _, _, _) =>
          _SecretContext(request, secrets!),
    );
    final response = await app.handle(
      ServerRequest(
        method: 'POST',
        uri: Uri.parse('https://example.test/demo.echo'),
        headers: const {'Content-Type': 'application/json'},
      ),
      Stream.value(utf8.encode('{}')),
      rawUri: 'https://example.test/demo.echo',
      secrets: SecretValues((name) async => null),
    );
    expect(response.status, 503);
    expect(jsonDecode(response.body), {'error': 'service_unavailable'});
  });

  test('context log forwards levels and never fails the request', () async {
    final entries = <String>[];
    final app = Application(
      {
        'demo.echo': (context, input) async {
          await context.log('warn', 'half-open connection');
          await context.log('loud', 'invalid levels are dropped');
          await context.log('info', 'with fields', {
            'order': 'o-1',
            'nested': {'ok': true},
            'none': null,
          });
          await context.log('info', 'bad fields', {'count': double.nan});
          await context.log('info', 'bad fields', {'huge': 9007199254740992});
          await context.log('info', 'bad fields', {'custom': Object()});
          final cycle = <String, Object?>{};
          cycle['cycle'] = cycle;
          await context.log('info', 'cyclic fields', cycle);
          return {};
        },
      },
      contextFactory: (request, connection, secrets, log, _, _, _) =>
          Context(request, log),
    );
    final response = await app.handle(
      ServerRequest(
        method: 'POST',
        uri: Uri.parse('https://example.test/demo.echo'),
        headers: const {'Content-Type': 'application/json'},
      ),
      Stream.value(utf8.encode('{}')),
      rawUri: 'https://example.test/demo.echo',
      log: (level, message, fields) async {
        entries.add('$level:$message:$fields');
        if (message == 'half-open connection') {
          throw StateError('log failure must not fail the request');
        }
      },
    );
    expect(response.status, 200);
    expect(jsonDecode(response.body), isEmpty);
    expect(entries, [
      'warn:half-open connection:null',
      'info:with fields:{order: o-1, nested: {ok: true}, none: null}',
    ]);
  });

  test(
    'print stays with the request that resumes after another request',
    () async {
      final started = Completer<void>();
      final resume = Completer<void>();
      final app = Application(
        {
          'demo.echo': (_, input) async {
            if (input['name'] == 'first') {
              started.complete();
              await resume.future;
            }
            print(input['name']);
            return {};
          },
        },
        setup: () async {
          print('setup');
          return const ApplicationOptions();
        },
      );
      final records = <String>[];
      Future<ServerResponse> call(String name) => app.handle(
        ServerRequest(
          method: 'POST',
          uri: Uri.parse('https://example.test/demo.echo'),
          headers: const {'Content-Type': 'application/json'},
        ),
        Stream.value(utf8.encode(jsonEncode({'name': name}))),
        log: (level, message, _) async {
          records.add('$name:$level:$message');
        },
      );

      final first = call('first');
      await started.future;
      expect((await call('second')).status, 200);
      resume.complete();
      expect((await first).status, 200);
      expect(records, [
        'first:info:setup',
        'second:info:second',
        'first:info:first',
      ]);
    },
  );

  test('context log without a binding is dropped', () async {
    final app = Application({
      'demo.echo': (context, input) async {
        await context.log('info', 'unbound');
        return {};
      },
    });
    final response = await app.handle(
      ServerRequest(
        method: 'POST',
        uri: Uri.parse('https://example.test/demo.echo'),
        headers: const {'Content-Type': 'application/json'},
      ),
      Stream.value(utf8.encode('{}')),
      rawUri: 'https://example.test/demo.echo',
    );
    expect(response.status, 200);
  });
}

final class _SecretContext extends Context {
  _SecretContext(super.request, this.secrets);

  final SecretValues secrets;
}
