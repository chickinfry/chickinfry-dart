// The internal driver tests the same opt-in hooks that it consumes.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/src/testing/conformance.dart';
import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_conformance/credentials.dart';
import 'package:chickinfry_conformance/driver.dart';
import 'package:chickinfry_conformance/protocol.dart';
import 'package:chickinfry_conformance/server.dart';
import 'package:test/test.dart';

Map<String, Object?> get handshake => {
  'protocolVersions': [1],
  'runId': 'run',
  'requiredCapabilities': <String>[],
  'target': {'language': 'dart', 'role': 'sdk', 'environment': 'native'},
};
Map<String, Object?> args(Map<String, Object?> values) => {
  'caseId': 'case',
  'timeoutMs': 2000,
  ...values,
};

void main() {
  test('strict JSON rejects escaped/nested duplicates and malformed UTF-8', () {
    for (final value in [
      '{"x":1,"x":2}',
      '{"x":1,"\\u0078":2}',
      '{"x":[{"a":1,"a":2}]}',
      '{',
      '',
    ]) {
      expect(() => strictJson(value), throwsA(isA<DriverError>()));
    }
    expect(
      strictJson('{"a":[{"x":1},{"x":2}],"b":"x:y"}'),
      isA<Map<String, Object?>>(),
    );
    expect(() => Frames(100).add([255, 10]), throwsA(isA<DriverError>()));
  });
  test(
    'framing counts LF and UTF-8 bytes, rejects unfinished and 16MiB overflow',
    () {
      expect(Frames(5).add(utf8.encode('éé\n')), ['éé']);
      expect(
        () => Frames(4).add(utf8.encode('éé\n')),
        throwsA(isA<DriverError>()),
      );
      final partial = Frames(100)..add([123]);
      expect(partial.finish, throwsA(isA<DriverError>()));
      final boundary = List<int>.filled(16 * 1024 * 1024, 32)..last = 10;
      expect(
        Frames(boundary.length).add(boundary).single.length,
        boundary.length - 1,
      );
      boundary.last = 32;
      expect(
        () => Frames(boundary.length).add(boundary),
        throwsA(isA<DriverError>()),
      );
    },
  );
  test('protected references never overwrite and full records match all seven fields', () {
    final refs = Credentials()
      ..register('access', 'a' * 43)
      ..register('refresh', 'r' * 43);
    final record = {
      'origin': 'http://127.0.0.1:1234',
      'access_token': 'a' * 43,
      'refresh_token': 'r' * 43,
      'expires_at': '2099-01-01T00:00:00Z',
      'refresh_expires_at': '2099-02-01T00:00:00Z',
      'user_id': 'user',
      'session_id': 'session',
    };
    refs.register('record', jsonEncode(record));
    expect(
      () => refs.register('access', 'a' * 43),
      throwsA(isA<DriverError>()),
    );
    expect(
      refs.record(record['origin']!, 'record', 'access', 'refresh').userId,
      'user',
    );
    expect(
      () => refs.record('https://example.com', 'record', 'access', 'refresh'),
      throwsA(isA<DriverError>()),
    );
    refs.register('extra', jsonEncode({...record, 'unexpected': 'x'}));
    expect(
      () => refs.record(record['origin']!, 'extra', 'access', 'refresh'),
      throwsA(isA<DriverError>()),
    );
    refs.register('missing', jsonEncode({...record}..remove('user_id')));
    expect(
      () => refs.record(record['origin']!, 'missing', 'access', 'refresh'),
      throwsA(isA<DriverError>()),
    );
  });
  test('handshake has exactly three target fields and never advertises incomplete transport', () {
    final driver = Driver(Credentials(), (_, __) async => {});
    expect(
      () => driver.handshake({
        ...handshake,
        'target': {
          ...handshake['target'] as Map<String, Object?>,
          'extra': true,
        },
      }),
      throwsA(isA<DriverError>()),
    );
    expect(
      () => driver.handshake({
        ...handshake,
        'protocolVersions': [2],
      }),
      throwsA(isA<DriverError>()),
    );
    expect(
      () => driver.handshake({
        ...handshake,
        'requiredCapabilities': ['client.transport'],
      }),
      throwsA(isA<DriverError>()),
    );
    expect(
      driver.handshake(handshake)['capabilities'],
      isNot(contains('client.transport')),
    );
    driver.dispose();
  });
  test(
    'store create is all-or-none and snapshot/revision/null are preserved',
    () async {
      final driver = Driver(Credentials(), (_, __) async => {})
        ..handshake(handshake);
      addTearDown(driver.dispose);
      expect(
        driver.handle(
          'c:bad',
          'session.store.create',
          args({
            'storeRef': 'bad',
            'origin': 'http://127.0.0.1',
            'accessRef': 'a',
          }),
        ),
        throwsA(isA<DriverError>()),
      );
      expect(
        await driver.handle(
          'c:create',
          'session.store.create',
          args({'storeRef': 'store', 'origin': 'http://127.0.0.1'}),
        ),
        {'storeRef': 'store', 'revision': 0},
      );
      expect(
        await driver.handle(
          'c:read',
          'session.store.read',
          args({'storeRef': 'store', 'includeTrace': false}),
        ),
        {
          'present': false,
          'revision': 0,
          'accessRef': null,
          'refreshRef': null,
        },
      );
    },
  );
  test('server rejects unknown fields/IDs/reuse and serializes concurrent responses', () async {
    final lines = <Map<String, Object?>>[];
    final credentials = Credentials()..register('protected', 'g' * 43);
    final server = Server(credentials, (bytes) async {
      await Future<void>.delayed(Duration.zero);
      lines.add(object(strictJson(utf8.decode(bytes))));
    });
    server.driver.handshake(handshake);
    for (var i = 0; i < 20; i++) {
      server.receive({'id': 'c:$i', 'command': 'unknown', 'args': args({})});
    }
    await Future.wait(server.active.toList());
    expect(lines.length, 20);
    expect(lines.map((line) => line['id']).toSet().length, 20);
    for (final timeout in [0, -1, '2000', null, 1.5, true]) {
      server.add(
        utf8.encode(
          '${jsonEncode({
            'id': 'c:timeout:${lines.length}',
            'command': 'session.store.create',
            'args': args({'storeRef': 'unused', 'origin': 'http://127.0.0.1', 'timeoutMs': timeout}),
          })}\n',
        ),
      );
      await Future.wait(server.active.toList());
      expect(object(lines.last['error'])['code'], 'invalid_args');
      expect(object(lines.last['error'])['kind'], 'driver');
      expect(lines.last['result'], null);
      expect(server.failed, false);
    }
    server.add(
      utf8.encode(
        '${jsonEncode({
          'id': 'c:valid',
          'command': 'session.store.create',
          'args': args({'storeRef': 'valid', 'origin': 'http://127.0.0.1'}),
        })}\n',
      ),
    );
    await Future.wait(server.active.toList());
    expect(lines.last['error'], null);
    expect(object(lines.last['result'])['storeRef'], 'valid');
    expect(
      () =>
          server.receive({'id': 'c:0', 'command': 'unknown', 'args': args({})}),
      throwsA(isA<DriverError>()),
    );
    expect(
      () => server.receive({'id': 'd:unknown', 'result': {}, 'error': null}),
      throwsA(isA<DriverError>()),
    );
    expect(
      () => server.receive({
        'id': 'c:extra',
        'command': 'unknown',
        'args': args({}),
        'extra': true,
      }),
      throwsA(isA<DriverError>()),
    );
    expect(
      () => server.receive({
        'id': 'c:literal',
        'command': 'unknown',
        'args': args({'literal': 'g' * 43}),
      }),
      throwsA(isA<DriverError>()),
    );
    expect(server.failed, false);
    final input = StreamController<List<int>>();
    addTearDown(input.close);
    final serving = server.serve(input.stream);
    server.add(
      utf8.encode(
        '${jsonEncode({
          'id': 'c:mixed',
          'command': 'session.store.create',
          'args': args({'storeRef': 'unused', 'origin': 'http://127.0.0.1', 'timeoutMs': 0, 'extra': true}),
        })}\n',
      ),
    );
    await Future.wait(server.active.toList());
    expect(object(lines.last['error'])['code'], 'protocol_violation');
    expect(lines.last['result'], null);
    expect(server.failed, true);
    await serving.timeout(const Duration(seconds: 1));
    expect(server.ended, true);
  });
  test(
    'asynchronous fatal response cancels open input and disposes once',
    () async {
      for (final overlappingFailures in [false, true]) {
        var cancellations = 0;
        final cancelled = Completer<void>();
        final input = StreamController<List<int>>(
          onCancel: () {
            cancellations++;
            cancelled.complete();
          },
        );
        addTearDown(input.close);
        final refs = Credentials()..register('protected', 'g' * 43);
        final lines = <Map<String, Object?>>[];
        final writing = Completer<void>();
        final releaseWrite = Completer<void>();
        final server = Server(refs, (bytes) async {
          lines.add(object(strictJson(utf8.decode(bytes))));
          if (overlappingFailures) {
            writing.complete();
            await releaseWrite.future;
            throw StateError('Synthetic response write failure.');
          }
          await Future<void>.delayed(Duration.zero);
        });
        final serving = server.serve(input.stream);
        final cleanExit = serving
            .timeout(const Duration(seconds: 1))
            .then<Object?>((_) => null, onError: (Object error) => error);
        input.add(
          utf8.encode(
            '${jsonEncode({
              'id': 'c:handshake',
              'command': 'handshake',
              'args': {
                ...handshake,
                'protocolVersions': [2],
              },
            })}\n',
          ),
        );
        if (overlappingFailures) {
          await writing.future;
          final cleanResponse = server.active.single.then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          input.addError(StateError('Synthetic input failure.'));
          await cancelled.future;
          releaseWrite.complete();
          expect(
            await Future.wait([cleanExit, cleanResponse]),
            everyElement(isNull),
            reason:
                'Overlapping fatal paths must finish without shutdown errors.',
          );
        } else {
          expect(await cleanExit, isNull);
        }
        expect(object(lines.single['error'])['code'], 'protocol_mismatch');
        expect(cancellations, 1);
        expect(server.failed, true);
        expect(server.ended, true);
        expect(refs.contains('protected'), false);
        expect(server.driver.stores, isEmpty);
        expect(server.active, isEmpty);
        expect(server.pending, isEmpty);
        expect(server.finish(), same(server.finish()));
        refs.register('afterDispose', 'post-disposal marker');
        await server.finish();
        expect(refs.contains('afterDispose'), true);
      }
    },
  );
  test('EOF preserves truncation failure and fails pending barriers', () async {
    final server = Server(Credentials(), (_) async {});
    server.driver.handshake(handshake);
    final response = server.request('barrier.arrive', {});
    expect(response, throwsA(isA<DriverError>()));
    server.add(utf8.encode('{'));
    await server.finish();
    expect(server.failed, true);
    expect(server.pending, isEmpty);
  });
  test(
    'input/ref conflicts include literal null; SDK copy preserves the original',
    () async {
      final credentials = Credentials()..register('bearer', 'a' * 43);
      final driver = Driver(credentials, (_, __) async => {})
        ..handshake(handshake);
      addTearDown(driver.dispose);
      await driver.handle(
        'c:create',
        'client.create',
        args({
          'clientRef': 'client',
          'origin': 'http://127.0.0.1:1234',
          'requestTimeoutMs': 1000,
        }),
      );
      final original = driver.clients['client'];
      await driver.handle(
        'c:copy',
        'client.copy',
        args({
          'sourceClientRef': 'client',
          'clientRef': 'copy',
          'bearerRef': 'bearer',
        }),
      );
      expect(identical(driver.clients['client'], original), true);
      expect(
        driver.handle(
          'c:conflict',
          'client.call',
          args({
            'clientRef': 'client',
            'operation': 'probe.echo',
            'input': {'wire_value': null},
            'inputRefs': {'wire_value': 'bearer'},
          }),
        ),
        throwsA(isA<DriverError>()),
      );
      expect(
        driver.handle(
          'c:auth',
          'client.call',
          args({
            'clientRef': 'client',
            'operation': 'auth.refresh',
            'input': <String, Object?>{},
            'inputRefs': {'refresh_token': 'bearer'},
          }),
        ),
        throwsA(
          isA<DriverError>().having(
            (error) => error.kind,
            'kind',
            'unimplemented',
          ),
        ),
      );
    },
  );
  test('two SDK calls wait independently while protocol store commands progress', () async {
    final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => peer.close(force: true));
    final subscription = peer.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'wire_value': 'value',
          'observed_at': '2026-01-01T00:00:00.123456Z',
        }),
      );
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    final responses = <String, Completer<Map<String, Object?>>>{};
    final arrivals = <Map<String, Object?>>[];
    final arrived = Completer<void>();
    final server = Server(Credentials(), (bytes) async {
      final message = object(strictJson(utf8.decode(bytes)));
      if (message['command'] == 'barrier.arrive') {
        final payload = object(message['args']);
        expect(payload['facts'], {'entered': true});
        arrivals.add(message);
        if (arrivals.length == 2) arrived.complete();
      } else {
        responses[message['id']]!.complete(message);
      }
    });
    addTearDown(server.finish);
    Future<Map<String, Object?>> send(
      String id,
      String command,
      Map<String, Object?> values,
    ) {
      final response = Completer<Map<String, Object?>>();
      responses[id] = response;
      server.add(
        utf8.encode(
          '${jsonEncode({'id': id, 'command': command, 'args': values})}\n',
        ),
      );
      return response.future;
    }

    await send('c:handshake', 'handshake', handshake);
    await send(
      'c:store',
      'session.store.create',
      args({'storeRef': 'shared', 'origin': 'http://127.0.0.1:${peer.port}'}),
    );
    for (final ref in ['first', 'second']) {
      await send(
        'c:create:$ref',
        'client.create',
        args({
          'clientRef': ref,
          'origin': 'http://127.0.0.1:${peer.port}',
          'requestTimeoutMs': 1000,
          'storeRef': 'shared',
        }),
      );
    }
    await send(
      'c:arm',
      'barrier.arm',
      args({
        'barrierRef': 'gate',
        'point': 'sdk-entered',
        'participants': ['c:first', 'c:second'],
      }),
    );
    final calls = [
      for (final ref in ['first', 'second'])
        send(
          'c:$ref',
          'client.call',
          args({
            'clientRef': ref,
            'operation': 'probe.echo',
            'input': {'wire_value': 'value'},
          }),
        ),
    ];
    await arrived.future;
    final snapshot = await send(
      'c:read',
      'session.store.read',
      args({'storeRef': 'shared', 'includeTrace': true}),
    );
    expect(object(snapshot['result'])['clearAttempts'], isEmpty);
    expect(responses['c:first']!.isCompleted, false);
    expect(responses['c:second']!.isCompleted, false);
    for (final message in arrivals) {
      server.add(
        utf8.encode(
          '${jsonEncode({
            'id': message['id'],
            'result': {'barrierRef': 'gate', 'state': 'released', 'sequence': 1},
            'error': null,
          })}\n',
        ),
      );
    }
    final results = await Future.wait(calls);
    expect(
      results.every((result) => object(result['result'])['httpStatus'] == 200),
      true,
    );
    final observation = await send(
      'c:observe',
      'client.observe',
      args({'callId': 'c:first', 'afterSequence': 0}),
    );
    expect(object(observation['error'])['kind'], 'unimplemented');
    await Future.wait(server.active.toList());
  }, skip: !conformanceEnabled);
  test('trace preserves actual expected credentials, failed CAS and mutation revision', () async {
    final refs = Credentials();
    for (final name in ['oldAccess', 'oldRefresh', 'newAccess', 'newRefresh']) {
      refs.register(
        name,
        (name.startsWith('old')
                ? (name.endsWith('Access') ? 'a' : 'r')
                : (name.endsWith('Access') ? 'b' : 's')) *
            43,
      );
    }
    const origin = 'http://127.0.0.1:1234';
    for (final prefix in ['old', 'new']) {
      refs.register(
        '${prefix}Record',
        jsonEncode({
          'origin': origin,
          'access_token': refs.value('${prefix}Access'),
          'refresh_token': refs.value('${prefix}Refresh'),
          'expires_at': '2099-01-01T00:00:00Z',
          'refresh_expires_at': '2099-02-01T00:00:00Z',
          'user_id': 'user',
          'session_id': 'session',
        }),
      );
    }
    final driver = Driver(refs, (_, __) async => {})..handshake(handshake);
    addTearDown(driver.dispose);
    await driver.handle(
      'c:create',
      'session.store.create',
      args({
        'storeRef': 'store',
        'origin': origin,
        'recordRef': 'oldRecord',
        'accessRef': 'oldAccess',
        'refreshRef': 'oldRefresh',
      }),
    );
    final old = driver.stores['store']!.record.value!;
    final write = await driver.handle(
      'c:write',
      'session.store.write',
      args({
        'storeRef': 'store',
        'recordRef': 'newRecord',
        'accessRef': 'newAccess',
        'refreshRef': 'newRefresh',
      }),
    );
    expect(write['revision'], 2);
    final (call, _) = driver.observationFor('c:write', 'probe.echo');
    expect(
      await withConformanceCall(
        call,
        () => driver.stores['store']!.store.compareAndSet(old, null),
      ),
      false,
    );
    final read = await driver.handle(
      'c:read',
      'session.store.read',
      args({'storeRef': 'store', 'includeTrace': true}),
    );
    expect(read['revision'], 2);
    expect(read['accessRef'], 'newAccess');
    expect(read['clearAttempts'], [
      {
        'callId': 'c:write',
        'expectedAccessRef': 'oldAccess',
        'expectedRefreshRef': 'oldRefresh',
        'removed': false,
      },
    ]);
    final latest = driver.stores['store']!.record.value!;
    expect(
      await withConformanceCall(
        call,
        () => driver.stores['store']!.store.compareAndSet(latest, null),
      ),
      true,
    );
    expect(driver.stores['store']!.record.revision, 3);
    expect(driver.stores['store']!.record.value, null);
  }, skip: !conformanceEnabled);
  test(
    'errors preserve unknown observations and tool deadline identity',
    () async {
      final driver = Driver(Credentials(), (_, __) async => {})
        ..handshake(handshake);
      addTearDown(driver.dispose);
      await driver.handle(
        'c:setup',
        'session.store.create',
        args({'storeRef': 'store', 'origin': 'http://127.0.0.1'}),
      );
      final (call, observation) = driver.observationFor(
        'c:error',
        'probe.echo',
      );
      call.httpAttempts = 1;
      final error = observation.sdkError(
        const ClientException('network_error'),
        call,
        driver.credentials,
      );
      const sdkFields = {
        'kind',
        'code',
        'httpStatus',
        'outcomeUnknown',
        'rawTransportDetails',
      };
      expect(error.keys.toSet(), sdkFields);
      expect(
        observation
            .sdkError(
              const ClientException('network_error'),
              call,
              driver.credentials,
              construction: true,
            )
            .keys
            .toSet(),
        {...sdkFields, 'constructorNetworkRequests'},
      );
      expect(error['httpStatus'], null);
      expect(error['outcomeUnknown'], null);
      expect(error['rawTransportDetails'], false);
      for (final failure in [
        const ClientException('network_error', status: 200),
        const ClientException('unrecognized_code'),
        const OperationError('denied', 403),
      ]) {
        final payload = observation.sdkError(failure, call, driver.credentials);
        expect(payload.keys.toSet(), sdkFields);
        expect(payload['rawTransportDetails'], false);
      }
      driver.credentials.register('protected', 's' * 43);
      final protectedFailure = OperationError(
        driver.credentials.value('protected'),
        500,
      );
      expect(driver.credentials.exposes(protectedFailure.toString()), true);
      for (final failure in [
        const ClientException('network_error SocketException: peer marker'),
        const OperationError('Denied', 403),
        const OperationError('denied detail', 403),
        const OperationError('denied1', 403),
        protectedFailure,
      ]) {
        final payload = observation.sdkError(failure, call, driver.credentials);
        expect(payload.keys.toSet(), sdkFields);
        expect(payload['rawTransportDetails'], true);
        expect(payload['code'], null);
      }
      final envelopes = <String>[];
      final server = Server(driver.credentials, (bytes) async {
        envelopes.add(utf8.decode(bytes));
      });
      addTearDown(server.finish);
      final payload = observation.sdkError(
        protectedFailure,
        call,
        driver.credentials,
      );
      await server.write({'id': 'c:error', 'result': null, 'error': payload});
      expect(driver.credentials.exposes(envelopes), false);
      expect(
        object(object(strictJson(envelopes.single))['error']).keys.toSet(),
        sdkFields,
      );
      await expectLater(
        () => server.write({
          'id': 'c:exposure',
          'result': null,
          'error': {...payload, 'rawError': protectedFailure.toString()},
        }),
        throwsA(
          isA<DriverError>().having(
            (error) => error.code,
            'code',
            'driver_failed',
          ),
        ),
      );
      expect(server.failed, true);
      expect(envelopes.length, 1);
      expect(driver.credentials.exposes(envelopes), false);
      expect(const DriverError('deadline_exceeded').toJson(), {
        'kind': 'driver',
        'code': 'deadline_exceeded',
        'httpStatus': null,
        'outcomeUnknown': null,
      });
    },
  );
}
