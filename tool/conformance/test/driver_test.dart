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

import '../bin/driver.dart' show validateLaunch;

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
  test('launch accepts the optional required-auth SDK without other flags', () {
    const base = ['--plain-sdk', 'plain', '--auth-sdk', 'auth'];
    expect(() => validateLaunch(base), returnsNormally);
    expect(
      () => validateLaunch([...base, '--required-auth-sdk', 'required']),
      returnsNormally,
    );
    for (final args in <List<String>>[
      [],
      [...base, '--required-auth-sdk'],
      [...base, '--unknown', 'required'],
      [...base, '--required-auth-sdk', 'required', 'extra'],
    ]) {
      expect(() => validateLaunch(args), throwsStateError);
    }
  });
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
  test('handshake validates the target and advertises only enabled instrumentation', () {
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
    final enabled = conformanceEnabled && provenSdk(Platform.version);
    if (!enabled) {
      expect(
        () => driver.handshake({
          ...handshake,
          'requiredCapabilities': ['client.transport'],
        }),
        throwsA(isA<DriverError>()),
      );
    }
    expect(
      (driver.handshake(handshake)['capabilities'] as List).contains(
        'client.transport',
      ),
      enabled,
    );
    final otherRole = Driver(Credentials(), (_, __) async => {});
    for (final role in ['server', 'cli']) {
      expect(
        () => otherRole.handshake({
          ...handshake,
          'target': {'language': 'dart', 'role': role, 'environment': 'native'},
        }),
        throwsA(
          isA<DriverError>().having(
            (error) => error.kind,
            'kind',
            'unimplemented',
          ),
        ),
      );
    }
    otherRole.dispose();
    driver.dispose();
  });
  test(
    'fixture is explicit and unknown values fail before SDK construction',
    () async {
      final driver = Driver(Credentials(), (_, __) async => {})
        ..handshake(handshake);
      addTearDown(driver.dispose);
      for (final fixture in ['unknown', '', null, 1]) {
        await expectLater(
          driver.handle(
            'c:bad:$fixture',
            'client.create',
            args({
              'clientRef': 'bad',
              'fixture': fixture,
              'origin': 'invalid',
              'requestTimeoutMs': 1000,
            }),
          ),
          throwsA(
            isA<DriverError>().having(
              (error) => error.code,
              'code',
              'invalid_args',
            ),
          ),
        );
      }
      expect(driver.ownedTransports, isEmpty);
    },
  );
  test(
    'auth fixture and its bearer copy call the generated refresh bridge',
    () async {
      final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => peer.close(force: true));
      var requests = 0;
      final refs = Credentials()
        ..register('inputRefresh', 'r' * 43)
        ..register('bearer', 'a' * 43);
      final subscription = peer.listen((request) async {
        expect(request.uri.path, '/auth.refresh');
        final input = jsonDecode(await utf8.decoder.bind(request).join());
        expect(input['refresh_token'] == refs.value('inputRefresh'), true);
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'access_token': 'b' * 43,
            'refresh_token': 's' * 43,
            'expires_at': '2099-01-01T00:00:00Z',
            'refresh_expires_at': '2099-02-01T00:00:00Z',
            'user_id': 'user',
            'session_id': 'session',
          }),
        );
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final driver = Driver(refs, (_, __) async => {})..handshake(handshake);
      addTearDown(driver.dispose);
      await driver.handle(
        'c:create:auth',
        'client.create',
        args({
          'fixture': 'auth',
          'clientRef': 'auth',
          'origin': 'http://127.0.0.1:${peer.port}',
          'requestTimeoutMs': 1000,
        }),
      );
      await driver.handle(
        'c:copy:auth',
        'client.copy',
        args({
          'sourceClientRef': 'auth',
          'clientRef': 'copy',
          'bearerRef': 'bearer',
        }),
      );
      for (final client in ['auth', 'copy']) {
        final result = await driver.handle(
          'c:refresh:$client',
          'client.call',
          args({
            'clientRef': client,
            'operation': 'auth.refresh',
            'input': <String, Object?>{},
            'inputRefs': {'refresh_token': 'inputRefresh'},
            'outputRefs': {
              'access_token': 'access:$client',
              'refresh_token': 'refresh:$client',
            },
          }),
        );
        expect(object(result['output']).keys, isNot(contains('access_token')));
        expect(object(result['output']).keys, isNot(contains('refresh_token')));
        expect(object(result['output'])['session_id'], 'session');
        expect(result['credentialRefs'], {
          'access_token': 'access:$client',
          'refresh_token': 'refresh:$client',
        });
        expect(refs.exposes(result), false);
      }
      expect(requests, 2);
    },
  );
  test('snapshot preserves live watermarks, final projection and unavailable retention', () async {
    final driver = Driver(Credentials(), (_, __) async => {})
      ..handshake(handshake)
      ..caseId = 'case';
    addTearDown(driver.dispose);
    final (call, observation) = driver.observationFor(
      'c:observed',
      'probe.echo',
    );
    call.elapsed.start();
    observe(ConformanceTransportPhase phase) =>
        call.httpObservation!.transport(phase);
    final first = ConformanceHttpAttempt(call, 'probe.echo')
      ..status = 302
      ..libraryRetainedBytes = 0;
    call.httpObservation = first;
    observe(ConformanceTransportPhase.headers);
    final initial = observation.snapshot(call, 0);
    expect(initial['complete'], true);
    expect((initial['events'] as List).single, containsPair('httpStatus', 302));
    final watermark = initial['throughSequence'] as int;
    first.requestCancel();
    first.closeReader();
    expect(observation.transport.last['phase'], 'cancel-requested');
    first.observeCancel();
    call.complete(succeeded: false);
    final finalSnapshot = observation.snapshot(call, watermark);
    final events = (finalSnapshot['events'] as List)
        .cast<Map<String, Object?>>();
    expect(events.map((event) => event['phase']), [
      'cancel-requested',
      'cancel-observed',
      'reader-closed',
      'completed',
    ]);
    expect(
      events.every((event) => (event['sequence'] as int) > watermark),
      true,
    );
    expect(events.every((event) => event.keys.toSet().length == 8), true);
    expect(
      observation.snapshot(
        call,
        finalSnapshot['throughSequence'] as int,
      )['events'],
      isEmpty,
    );
    final (unknown, unknownObservation) = driver.observationFor(
      'c:unknown',
      'probe.echo',
    );
    final unknownAttempt = ConformanceHttpAttempt(unknown, 'probe.echo')
      ..status = 200;
    unknown.httpObservation = unknownAttempt;
    unknownAttempt.transport(ConformanceTransportPhase.headers);
    final unavailable =
        (unknownObservation.snapshot(unknown, 0)['events'] as List).single;
    expect(unavailable['retainedBytes'], null);
    expect(unavailable['peakRetainedBytes'], null);
    expect(unknownObservation.snapshot(unknown, 0)['complete'], false);
    expect(
      unavailable['sequence'],
      greaterThan(finalSnapshot['throughSequence'] as int),
    );
    unknown.instrumentationFailed = true;
    expect(
      unknownObservation.snapshot(
        unknown,
        unknownObservation.transport.last['sequence'] as int,
      )['complete'],
      false,
    );
    final (multiple, projection) = driver.observationFor(
      'c:multi',
      'probe.echo',
      deferTransport: true,
    );
    multiple.elapsed.start();
    for (final status in [401, 503]) {
      final exchange = ConformanceHttpAttempt(
        multiple,
        status == 401 ? 'probe.echo' : 'auth.refresh',
      )..status = status;
      multiple.httpObservation = exchange;
      exchange.transport(ConformanceTransportPhase.headers);
      exchange.read(12);
      exchange.closeReader();
    }
    final live = projection.snapshot(multiple, 0);
    expect((live['events'] as List).map((event) => event['phase']), [
      'read',
      'read',
    ]);
    expect((live['events'] as List).map((event) => event['readBytes']), [
      12,
      24,
    ]);
    projection.record(
      ConformanceRefreshEvent(
        Object(),
        'operation_failed',
        503,
        ConformanceRefreshObservation()..attempt = multiple.httpObservation,
      ),
    );
    multiple.complete(succeeded: false);
    final finalProjection =
        (projection.snapshot(multiple, live['throughSequence'] as int)['events']
            as List);
    expect(finalProjection.map((event) => event['phase']), [
      'headers',
      'reader-closed',
      'completed',
    ]);
    expect(
      finalProjection.every(
        (event) =>
            event['httpStatus'] == 503 &&
            event['readBytes'] == 24 &&
            event['peakRetainedBytes'] == null,
      ),
      true,
    );
    for (final status in [401, 302]) {
      final (late, lateProjection) = driver.observationFor(
        'c:late:$status',
        'probe.echo',
        deferTransport: true,
      );
      late.elapsed.start();
      ConformanceHttpAttempt? intermediate;
      if (status == 302) {
        intermediate = ConformanceHttpAttempt(late, 'probe.echo')..status = 401;
        late.httpObservation = intermediate;
        intermediate.transport(ConformanceTransportPhase.headers);
        intermediate.read(12);
        intermediate.requestCancel();
        intermediate.closeReader();
      }
      final result =
          ConformanceHttpAttempt(
              late,
              status == 401 ? 'probe.echo' : 'auth.refresh',
            )
            ..status = status
            ..libraryRetainedBytes = 0;
      late.httpObservation = result;
      result.transport(ConformanceTransportPhase.headers);
      result.requestCancel();
      result.closeReader();
      if (status == 302) {
        lateProjection.record(
          ConformanceRefreshEvent(
            Object(),
            'redirect_not_allowed',
            status,
            ConformanceRefreshObservation()..attempt = result,
          ),
        );
      }
      late.complete(succeeded: false);
      final completed = lateProjection.snapshot(late, 0);
      final completedEvents = (completed['events'] as List)
          .cast<Map<String, Object?>>();
      expect(completedEvents.map((event) => event['phase']), [
        if (intermediate != null) 'read',
        'headers',
        'cancel-requested',
        'completed',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      intermediate?.observeCancel();
      result.observeCancel();
      result.observeCancel();
      result.closeReader();
      late.complete(succeeded: false);
      final completionWatermark = completed['throughSequence'] as int;
      final closed = lateProjection.snapshot(late, completionWatermark);
      final closureEvents = (closed['events'] as List)
          .cast<Map<String, Object?>>();
      expect(closureEvents.map((event) => event['phase']), [
        'cancel-observed',
        'reader-closed',
      ]);
      expect(
        closureEvents.every(
          (event) =>
              (event['sequence'] as int) > completionWatermark &&
              (event['elapsedMs'] as double) >
                  (completedEvents.last['elapsedMs'] as double) &&
              event['httpStatus'] == status,
        ),
        true,
      );
      expect(
        completed['complete'],
        completedEvents.every(
          (event) =>
              event['readBytes'] != null &&
              event['retainedBytes'] != null &&
              event['peakRetainedBytes'] != null,
        ),
      );
      if (status == 401) expect(completed['complete'], true);
      expect(closed['complete'], status == 401);
      final exhausted = lateProjection.snapshot(
        late,
        closed['throughSequence'] as int,
      );
      expect(exhausted['events'], isEmpty);
      expect(
        lateProjection.transport.where(
          (event) => event['phase'] == 'completed',
        ),
        hasLength(1),
      );
    }
  }, skip: !conformanceEnabled);
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
          'fixture': 'plain',
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
          'fixture': 'auth',
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
    expect(observation['error'], null);
    final observed = object(observation['result']);
    expect(observed['complete'], true);
    expect((observed['events'] as List).last['phase'], 'completed');
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
        const ClientError('unavailable'),
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
              const ClientError('unavailable'),
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
        const ClientError('unavailable', status: 200),
        const ClientError('unrecognized_code'),
        const OperationError('denied', 403),
      ]) {
        final payload = observation.sdkError(failure, call, driver.credentials);
        expect(payload.keys.toSet(), sdkFields);
        expect(payload['rawTransportDetails'], false);
      }
      call.httpObservation = ConformanceHttpAttempt(call, 'probe.echo')
        ..status = 401;
      expect(
        observation.sdkError(
          const ClientError('unauthenticated'),
          call,
          driver.credentials,
        )['httpStatus'],
        isNull,
      );
      expect(
        observation.sdkError(
          const ClientError('deadline_exceeded', status: 200),
          call,
          driver.credentials,
        )['httpStatus'],
        200,
      );
      call.httpObservation = null;
      driver.credentials.register('protected', 's' * 43);
      final protectedFailure = OperationError(
        driver.credentials.value('protected'),
        500,
      );
      expect(driver.credentials.exposes(protectedFailure.toString()), true);
      for (final failure in [
        const ClientError('network_error SocketException: peer marker'),
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
