import 'dart:async';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/testing/conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  if (conformanceEnabled) {
    test(
      'conformance callbacks isolate barriers and preserve SDK outcomes',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          await reply(request, {'ok': true});
        });
        final transport = peer.transport();
        final blockedCall = conformanceCall(
          'blocked',
          'thing.get',
          Observer(
            onArrive: (point, facts) {
              if (point == ConformancePoint.sdkEntered) {
                entered.complete();
                return release.future;
              }
              return null;
            },
          ),
        );
        final blocked = withConformanceCall(
          blockedCall,
          () => transport.invoke('thing.get', {}),
        );
        await entered.future;
        expect(peer.requests, 0);
        final freeCall = conformanceCall('free', 'thing.get', Observer());
        expect(
          await withConformanceCall(
            freeCall,
            () => transport.invoke('thing.get', {}),
          ).timeout(
            const Duration(seconds: 1),
            onTimeout: () => {'blocked': true},
          ),
          {'ok': true},
        );
        expect(peer.requests, 1);
        release.complete();
        expect(await blocked, {'ok': true});
        expect(blockedCall.instrumentationFailed, isFalse);

        final shared = Completer<SessionCredentials>();
        final releaseFailure = Completer<void>();
        final failureEvents = <ConformanceEvent>[];
        final failureCall = conformanceCall(
          'failure',
          'thing.get',
          Observer(
            onArrive: (_, _) => releaseFailure.future,
            onRecord: failureEvents.add,
          ),
        );
        final flight = Object();
        final failed = withConformanceCall(
          failureCall,
          () => observeRefresh(
            shared.future,
            flight,
            credentials(),
            initiator: false,
          ),
        ).then<Object>((value) => value, onError: (Object error) => error);
        const error = ClientException('request_timeout');
        shared.completeError(error);
        expect(await transport.invoke('thing.get', {}), {'ok': true});
        expect(failureEvents, isEmpty);
        releaseFailure.complete();
        expect(await failed, same(error));
        final observed = failureEvents
            .whereType<ConformanceRefreshEvent>()
            .single;
        expect(observed.flight, same(flight));
        expect(observed.code, 'request_timeout');
        expect(observed.status, isNull);
        expect(failureCall.instrumentationFailed, isFalse);

        for (final kind in ['sync', 'async', 'record']) {
          final call = conformanceCall(
            kind,
            'thing.get',
            Observer(
              onArrive: (_, _) {
                if (kind == 'sync') throw StateError('observer');
                if (kind == 'async') {
                  return Future<void>.error(StateError('observer'));
                }
                return null;
              },
              onRecord: (_) {
                if (kind == 'record') throw StateError('observer');
              },
            ),
          );
          expect(
            await withConformanceCall(
              call,
              () => transport.invoke('thing.get', {}),
            ),
            {'ok': true},
          );
          expect(call.instrumentationFailed, isTrue);
        }
        final invalidArrivals = <ConformanceFacts>[];
        final invalid = conformanceCall(
          'invalid',
          'invalid',
          Observer(
            onArrive: (point, facts) {
              if (point == ConformancePoint.sdkEntered) {
                invalidArrivals.add(facts);
              }
              return null;
            },
          ),
        );
        await expectLater(
          withConformanceCall(invalid, () => transport.invoke('invalid', {})),
          throwsA(clientFailure('invalid_input')),
        );
        expect(invalidArrivals, hasLength(1));
        expect(invalidArrivals.single.operation, 'invalid');
        expect(invalid.httpAttempts, 0);
      },
    );

    test('conformance store delegates exact CAS and preserves atomic revision snapshots', () async {
      final original = credentials();
      final replacement = credentials(rotated: true, session: 'other');
      final record = Record(null);
      final memory = MemorySessionStore('http://127.0.0.1', 'record', record);
      final write = memory.write(original);
      expect(record.snapshot, (value: original, revision: 1));
      final second = memory.write(replacement);
      expect(record.snapshot, (value: replacement, revision: 2));
      await Future.wait([write, second]);
      expect(await memory.compareAndSet(original, null), isFalse);
      expect(record.revision, 2);
      await memory.write(replacement);
      expect(record.revision, 3);
      expect(await memory.compareAndSet(replacement, null), isTrue);
      expect(record.snapshot, (value: null, revision: 4));

      for (final fails in [false, true]) {
        final delegate = FaultyStore(record, fails);
        final store = RecordingSessionStore(delegate);
        record.value = replacement;
        final call = conformanceCall('clear', 'thing.get', Observer());
        final future = withConformanceCall(
          call,
          () => store.compareAndSet(original, null),
        );
        if (fails) {
          await expectLater(future, throwsA(same(delegate.failure)));
          expect(store.clearAttempts.single.removed, isNull);
        } else {
          expect(await future, isTrue);
          expect(record.value, isNull);
          expect(store.clearAttempts.single.removed, isTrue);
        }
        expect(delegate.arguments, [(original, null)]);
        expect(store.clearAttempts.single.expected, same(original));
        expect(store.clearAttempts.single.callId, 'clear');
        expect(store.origin, delegate.origin);
        expect(store.coordinationKey, delegate.coordinationKey);
      }
    });
  }
  test(
    'C-03 session credentials reject missing, null, invalid tokens and times',
    () {
      final original = credentials();
      expect(
        SessionCredentials.fromJson(original.toJson()) == original,
        isTrue,
      );
      expect(original.expiresAt, '2026-10-13T12:15:00.123456Z');
      expect(original.toString().contains(original.accessToken), isFalse);
      for (final field in original.toJson().keys) {
        for (final value in [null, 1, '']) {
          expect(
            () => SessionCredentials.fromJson({
              ...original.toJson(),
              field: value,
            }),
            throwsA(clientFailure('invalid_session_record')),
          );
        }
        expect(
          () => SessionCredentials.fromJson(original.toJson()..remove(field)),
          throwsA(clientFailure('invalid_session_record')),
        );
      }
      for (final value in [
        '2026-02-30T00:00:00Z',
        '2026-10-13',
        '2026-10-13T24:00:00Z',
        '2026-10-13T12:00:00',
        'private-invalid-time',
      ]) {
        expect(
          () => SessionCredentials.fromJson({
            ...original.toJson(),
            'expires_at': value,
          }),
          throwsA(clientFailure('invalid_session_record')),
        );
      }
      expect(
        () => SessionCredentials.fromJson({
          ...original.toJson(),
          'access_token': 'bad',
        }),
        throwsA(clientFailure('invalid_session_record')),
      );
    },
  );

  test('C-07 session reads latest record while copies retain separate auth contexts', () async {
    final observations = <int>[];
    final peer = await Peer.start((request) async {
      final bearer = request.headers.value('authorization');
      observations.add(
        bearer == null
            ? 0
            : bearer == 'Bearer $nextAccessToken'
            ? 1
            : 2,
      );
      await request.drain<void>();
      await reply(request, {});
    });
    final record = Record(null);
    final store = MemorySessionStore(peer.origin, 'fresh', record);
    final root = peer.transport();
    final session = root.withSession(store);
    await session.invoke('thing.get', {});
    await store.write(credentials(rotated: true));
    await session.invoke('thing.get', {});
    await root.invoke('thing.get', {});
    expect(observations, [0, 1, 0]);
  });

  test(
    'C-08 one refresh and one replay reuse the original serialized body',
    () async {
      var business = 0;
      var refreshes = 0;
      final refreshAnonymous = <bool>[];
      final refreshCredentials = <bool>[];
      final businessCredentials = <bool>[];
      final businessBodies = <Object?>[];
      final input = <String, Object?>{'value': 'original'};
      final peer = await Peer.start((request) async {
        final body = await readBody(request);
        if (request.uri.path == '/auth.refresh') {
          refreshes++;
          refreshAnonymous.add(request.headers.value('authorization') == null);
          refreshCredentials.add(
            (body as Map<String, Object?>)['refresh_token'] == refreshToken,
          );
          await reply(request, credentials(rotated: true).toJson());
        } else {
          business++;
          businessBodies.add(body);
          businessCredentials.add(
            request.headers.value('authorization') ==
                'Bearer ${business == 1 ? accessToken : nextAccessToken}',
          );
          input['value'] = 'changed';
          await reply(request, {'error': 'invalid_token'}, status: 401);
        }
      });
      final record = Record(credentials());
      final transport = peer.transport().withSession(
        MemorySessionStore(peer.origin, 'retry', record),
      );
      await expectLater(
        transport.invoke('thing.write', input),
        throwsA(operationFailure('invalid_token', 401)),
      );
      expect(business, 2);
      expect(refreshes, 1);
      expect(refreshAnonymous, [true]);
      expect(refreshCredentials, [true]);
      expect(businessCredentials, [true, true]);
      expect(businessBodies, [
        {'value': 'original'},
        {'value': 'original'},
      ]);
      expect(record.value == credentials(rotated: true), isTrue);
      expect(record.deletions, 0);
    },
  );

  test(
    'C-08 other errors and direct refresh never trigger automatic refresh',
    () async {
      final errors = [
        (401, 'account_blocked'),
        (403, 'invalid_token'),
        (429, 'rate_limited'),
        (500, 'internal_error'),
        (401, 'invalid_token'),
      ];
      final paths = <String>[];
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        paths.add(request.uri.path);
        final failure = errors.removeAt(0);
        if (request.uri.path == '/auth.refresh') {
          expect(request.headers.value('authorization') == null, isTrue);
        }
        await reply(request, {'error': failure.$2}, status: failure.$1);
      });
      final transport = peer.transport().withSession(
        MemorySessionStore(peer.origin, 'other-errors', Record(credentials())),
      );
      for (final failure in [
        (401, 'account_blocked'),
        (403, 'invalid_token'),
        (429, 'rate_limited'),
        (500, 'internal_error'),
      ]) {
        await expectLater(
          transport.invoke('thing.write', {}),
          throwsA(operationFailure(failure.$2, failure.$1)),
        );
      }
      await expectLater(
        transport.invoke('auth.refresh', {'refresh_token': refreshToken}),
        throwsA(operationFailure('invalid_token', 401)),
      );
      expect(paths, [
        '/thing.write',
        '/thing.write',
        '/thing.write',
        '/thing.write',
        '/auth.refresh',
      ]);
    },
  );

  for (final corrupt in [false, true]) {
    test(
      'C-08 ${corrupt ? 'corrupt' : 'unreadable'} store never becomes anonymous',
      () async {
        final peer = await Peer.start((request) async {
          await reply(request, {});
        });
        final record = Record(credentials())
          ..corrupt = corrupt
          ..failRead = !corrupt;
        final transport = peer.transport().withSession(
          MemorySessionStore(peer.origin, 'read-failure', record),
        );
        final events = <ConformanceEvent>[];
        final call = conformanceCall(
          'read-failure-$corrupt',
          'thing.get',
          Observer(onRecord: events.add),
        );
        await expectLater(
          withConformanceCall(call, () => transport.invoke('thing.get', {})),
          throwsA(
            clientFailure(
              corrupt ? 'invalid_session_record' : 'session_storage_error',
            ),
          ),
        );
        expect(peer.requests, 0);
        expect(record.value == credentials(), isTrue);
        expect(record.deletions, 0);
        if (conformanceEnabled) {
          expect(call.httpAttempts, 0);
          expect(call.httpObservation, isNull);
          expect(call.instrumentationFailed, isFalse);
          expect(events.whereType<ConformanceHttpEvent>(), isEmpty);
          expect(call.transportEvents, hasLength(1));
          final completed = call.transportEvents.single;
          expect(completed.phase, ConformanceTransportPhase.completed);
          expect(completed.attempt, isNull);
          expect(completed.status, isNull);
          expect(completed.readBytes, isNull);
          expect(completed.runtimeRetainedBytes, isNull);
          expect(completed.libraryRetainedBytes, isNull);
          expect(completed.retainedBytes, isNull);
          expect(completed.peakRetainedBytes, isNull);
          expect(completed.runtimePeakRetainedBytes, isNull);
          expect(events.single, same(completed));
        } else {
          expect(events, isEmpty);
        }
      },
    );
  }

  test('C-09 distinct store objects and independent transports merge refresh; late 401 adopts rotation', () async {
    var initial = 0;
    var refreshes = 0;
    var replays = 0;
    final allStarted = Completer<void>();
    final releaseLate = Completer<void>();
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    final participants = <String, ConformanceFacts>{};
    final rejected = <String>{};
    final entered = <String>{};
    final httpEvents = <String, List<ConformanceHttpEvent>>{};
    final joined = Completer<void>();
    final releaseParticipants = Completer<void>();
    final workerCompleted = Completer<void>();
    final refreshObservations = <ConformanceRefreshObservation>[];
    final observer = Observer(
      onArrive: (point, facts) {
        final call = currentConformanceCall!;
        expect(facts.operation, call.operation);
        if (point == ConformancePoint.sdkEntered) {
          entered.add(call.callId);
          expect(httpEvents[call.callId], isNull);
        } else if (point == ConformancePoint.originalsRejected) {
          rejected.add(call.callId);
          expect(entered, contains(call.callId));
          expect(facts.code, 'invalid_token');
          expect(facts.status, 401);
          expect(facts.credentials, credentials());
          expect(facts.attempt, 1);
          expect(httpEvents[call.callId]!.last.phase, ConformancePhase.failed);
        } else {
          expect(rejected, contains(call.callId));
          participants[call.callId] = facts;
          if (participants.length == 2) joined.complete();
          if (call.callId != 'late') return releaseParticipants.future;
        }
        return null;
      },
      onRecord: (event) {
        if (event is ConformanceRefreshEvent) {
          refreshObservations.add(event.observation!);
        }
        if (event is ConformanceHttpEvent) {
          (httpEvents[currentConformanceCall!.callId] ??= []).add(event);
          if (event.operation == 'auth.refresh' &&
              event.phase == ConformancePhase.completed) {
            workerCompleted.complete();
          }
        }
      },
    );
    addTearDown(() {
      for (final gate in [releaseRefresh, releaseParticipants, releaseLate]) {
        if (!gate.isCompleted) gate.complete();
      }
    });
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      if (request.uri.path == '/auth.refresh') {
        refreshes++;
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        await releaseRefresh.future;
        await reply(request, credentials(rotated: true).toJson());
      } else if (request.headers.value('authorization') ==
          'Bearer $accessToken') {
        initial++;
        if (initial == 3) allStarted.complete();
        await allStarted.future;
        if (request.uri.path == '/thing.late') await releaseLate.future;
        await reply(request, {'error': 'invalid_token'}, status: 401);
      } else {
        expect(
          request.headers.value('authorization') == 'Bearer $nextAccessToken',
          isTrue,
        );
        replays++;
        await reply(request, {'value': 'ok'});
      }
    });
    final record = Record(credentials());
    final firstStore = MemorySessionStore(
      peer.origin,
      'physical-record',
      record,
    );
    final secondStore = MemorySessionStore(
      peer.origin,
      'physical-record',
      record,
    );
    expect(identical(firstStore, secondStore), isFalse);
    final first = peer.transport().withSession(firstStore);
    final second = peer.transport().withSession(secondStore);
    final contexts = [
      conformanceCall('first', 'thing.first', observer),
      conformanceCall('second', 'thing.second', observer),
      conformanceCall('late', 'thing.late', observer),
    ];
    final calls = [
      for (final call in [
        withConformanceCall(contexts[0], () => first.invoke('thing.first', {})),
        withConformanceCall(
          contexts[1],
          () => second.invoke('thing.second', {}),
        ),
      ])
        call.then<Object?>((value) => value, onError: (Object error) => error),
    ];
    final late = withConformanceCall(
      contexts[2],
      () => first.invoke('thing.late', {}),
    ).then<Object?>((value) => value, onError: (Object error) => error);
    expect(
      await refreshStarted.future
          .then((_) => true)
          .timeout(const Duration(seconds: 1), onTimeout: () => false),
      isTrue,
    );
    if (conformanceEnabled) {
      expect(
        await joined.future
            .then((_) => true)
            .timeout(const Duration(seconds: 1), onTimeout: () => false),
        isTrue,
      );
      expect(participants.keys, unorderedEquals(['first', 'second']));
      expect(
        identical(
          participants['first']!.flight,
          participants['second']!.flight,
        ),
        isTrue,
      );
      expect(
        participants.values.map((facts) => facts.initiator),
        unorderedEquals([true, false]),
      );
    }
    releaseRefresh.complete();
    if (conformanceEnabled) {
      await workerCompleted.future;
      expect(replays, 0);
      releaseParticipants.complete();
    }
    await expectLater(
      Future.wait(calls),
      completion([
        {'value': 'ok'},
        {'value': 'ok'},
      ]),
    );
    releaseLate.complete();
    expect(await late, {'value': 'ok'});
    expect(refreshes, 1);
    expect(initial, 3);
    expect(replays, 3);
    expect(record.replacements, 1);
    if (conformanceEnabled) {
      expect(refreshObservations, isNotEmpty);
      expect(
        refreshObservations
            .where((observation) => observation.attempt != null)
            .every(
              (observation) =>
                  observation.credentialsValidated &&
                  observation.credentialsStored &&
                  !observation.rejected401 &&
                  observation.outcomeUnknown == false,
            ),
        isTrue,
      );
      expect(
        contexts.map((call) => call.instrumentationFailed),
        everyElement(isFalse),
      );
      expect(entered, unorderedEquals(['first', 'second', 'late']));
      expect(rejected, entered);
      final firstEvents = httpEvents['first']!;
      final secondEvents = httpEvents['second']!;
      expect(
        firstEvents
            .where((event) => event.phase == ConformancePhase.sending)
            .map((event) => event.attempt),
        participants['first']!.initiator! ? [1, 2, 3] : [1, 2],
      );
      expect(
        secondEvents
            .where((event) => event.phase == ConformancePhase.sending)
            .map((event) => event.attempt),
        participants['second']!.initiator! ? [1, 2, 3] : [1, 2],
      );
    } else {
      expect(entered, isEmpty);
      expect(httpEvents, isEmpty);
      expect(contexts.map((call) => call.httpAttempts), everyElement(0));
    }
  });

  test('C-09 different records refresh independently', () async {
    var refreshes = 0;
    final bothRefresh = Completer<void>();
    final peer = await Peer.start((request) async {
      await request.drain<void>();
      if (request.uri.path == '/auth.refresh') {
        if (++refreshes == 2) bothRefresh.complete();
        await bothRefresh.future;
        await reply(request, credentials(rotated: true).toJson());
      } else if (request.headers.value('authorization') ==
          'Bearer $accessToken') {
        await reply(request, {'error': 'invalid_token'}, status: 401);
      } else {
        await reply(request, {});
      }
    });
    final first = peer.transport().withSession(
      MemorySessionStore(peer.origin, 'record-one', Record(credentials())),
    );
    final second = peer.transport().withSession(
      MemorySessionStore(peer.origin, 'record-two', Record(credentials())),
    );
    await Future.wait([
      first.invoke('thing.get', {}),
      second.invoke('thing.get', {}),
    ]);
    expect(refreshes, 2);
  });

  test(
    'C-09 matching keys on different origins never exchange credentials',
    () async {
      var refreshes = 0;
      final ready = Completer<void>();
      Future<Peer> originPeer(String session) => Peer.start((request) async {
        await request.drain<void>();
        if (request.uri.path == '/auth.refresh') {
          if (++refreshes == 2) ready.complete();
          await ready.future;
          await reply(
            request,
            credentials(rotated: true, session: session).toJson(),
          );
        } else if (request.headers.value('authorization') ==
            'Bearer $accessToken') {
          await reply(request, {'error': 'invalid_token'}, status: 401);
        } else {
          await reply(request, {'session': session});
        }
      });
      final first = await originPeer('first-origin');
      final second = await originPeer('second-origin');
      final calls = [
        first
            .transport()
            .withSession(
              MemorySessionStore(
                first.origin,
                'same-key',
                Record(credentials(session: 'first-origin')),
              ),
            )
            .invoke('thing.get', {}),
        second
            .transport()
            .withSession(
              MemorySessionStore(
                second.origin,
                'same-key',
                Record(credentials(session: 'second-origin')),
              ),
            )
            .invoke('thing.get', {}),
      ];
      await expectLater(
        Future.wait(calls).timeout(const Duration(seconds: 1)),
        completion([
          {'session': 'first-origin'},
          {'session': 'second-origin'},
        ]),
      );
      expect(refreshes, 2);
    },
  );

  test(
    'C-10 rejected shared refresh deletes only expected credentials once',
    () async {
      var initial = 0;
      var refreshes = 0;
      final bothStarted = Completer<void>();
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        if (request.uri.path == '/auth.refresh') {
          refreshes++;
          await reply(request, {'error': 'session_revoked'}, status: 401);
        } else {
          if (++initial == 2) bothStarted.complete();
          await bothStarted.future;
          await reply(request, {'error': 'invalid_token'}, status: 401);
        }
      });
      final record = Record(credentials());
      final store = RecordingSessionStore(
        MemorySessionStore(peer.origin, 'reject', record),
      );
      final first = peer.transport().withSession(store);
      final second = peer.transport().withSession(store);
      final initiators = <String>[];
      final refreshObservations = <ConformanceRefreshObservation>[];
      final observer = Observer(
        onRecord: (event) {
          if (event is ConformanceRefreshEvent) {
            refreshObservations.add(event.observation!);
          }
        },
        onArrive: (point, facts) {
          if (point == ConformancePoint.refreshJoined && facts.initiator!) {
            initiators.add(currentConformanceCall!.callId);
          }
          return null;
        },
      );
      await Future.wait([
        expectLater(
          withConformanceCall(
            conformanceCall('first', 'thing.get', observer),
            () => first.invoke('thing.get', {}),
          ),
          throwsA(operationFailure('session_revoked', 401)),
        ),
        expectLater(
          withConformanceCall(
            conformanceCall('second', 'thing.get', observer),
            () => second.invoke('thing.get', {}),
          ),
          throwsA(operationFailure('session_revoked', 401)),
        ),
      ]);
      expect(record.value == null, isTrue);
      expect(record.deletions, 1);
      expect(initial, 2);
      expect(refreshes, 1);
      expect(record.revision, 2);
      if (conformanceEnabled) {
        expect(refreshObservations, isNotEmpty);
        expect(
          refreshObservations.every(
            (observation) =>
                !observation.credentialsValidated &&
                !observation.credentialsStored &&
                observation.rejected401 &&
                observation.outcomeUnknown == false,
          ),
          isTrue,
        );
        expect(store.clearAttempts, hasLength(1));
        expect(store.clearAttempts.single.callId, initiators.single);
        expect(store.clearAttempts.single.expected, credentials());
        expect(store.clearAttempts.single.removed, isTrue);
      }
    },
  );

  for (final succeeds in [false, true]) {
    test(
      'C-10 late refresh ${succeeds ? 'success' : 'rejection'} preserves login at CAS boundary',
      () async {
        var business = 0;
        final replacement = credentials(
          rotated: true,
          session: 'new-session',
          user: 'new-user',
        );
        final record = Record(credentials());
        final refreshStarted = Completer<void>();
        final releaseRefresh = Completer<void>();
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth.refresh') {
            refreshStarted.complete();
            await releaseRefresh.future;
            await reply(
              request,
              succeeds
                  ? credentials(rotated: true).toJson()
                  : {'error': 'session_revoked'},
              status: succeeds ? 200 : 401,
            );
          } else {
            business++;
            await reply(request, {'error': 'invalid_token'}, status: 401);
          }
        });
        final store = RecordingSessionStore(
          MemorySessionStore(peer.origin, 'cas-race-$succeeds', record),
        );
        final outcome = expectLater(
          withConformanceCall(
            conformanceCall('replace', 'thing.write', Observer()),
            () => peer.transport().withSession(store).invoke('thing.write', {}),
          ),
          throwsA(
            succeeds
                ? clientFailure('session_changed')
                : operationFailure('session_revoked', 401),
          ),
        );
        await refreshStarted.future;
        await store.write(replacement);
        releaseRefresh.complete();
        await outcome;
        expect(record.value == replacement, isTrue);
        expect(record.replacements, 0);
        expect(record.deletions, 0);
        expect(business, 1);
        expect(record.snapshot, (value: replacement, revision: 2));
        if (conformanceEnabled && !succeeds) {
          expect(store.clearAttempts, hasLength(1));
          expect(store.clearAttempts.single.callId, 'replace');
          expect(store.clearAttempts.single.expected, credentials());
          expect(store.clearAttempts.single.removed, isFalse);
        }
      },
    );
  }

  test(
    'C-10 replacement before refresh prevents sending old credentials',
    () async {
      final record = Record(credentials());
      var refreshes = 0;
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        if (request.uri.path == '/auth.refresh') refreshes++;
        record.value = credentials(rotated: true, session: 'new-session');
        await reply(request, {'error': 'invalid_token'}, status: 401);
      });
      await expectLater(
        peer
            .transport()
            .withSession(
              MemorySessionStore(peer.origin, 'already-changed', record),
            )
            .invoke('thing.get', {}),
        throwsA(clientFailure('session_changed')),
      );
      expect(refreshes, 0);
      expect(peer.requests, 1);
    },
  );

  test(
    'C-10 failed conditional deletion retains server error and stored record',
    () async {
      final record = Record(credentials())..failReplace = true;
      final peer = await Peer.start((request) async {
        await request.drain<void>();
        await reply(request, {
          'error': request.uri.path == '/auth.refresh'
              ? 'session_revoked'
              : 'invalid_token',
        }, status: 401);
      });
      await expectLater(
        peer
            .transport()
            .withSession(
              MemorySessionStore(peer.origin, 'delete-failure', record),
            )
            .invoke('thing.get', {}),
        throwsA(
          clientFailure('session_storage_error')
              .having(
                (error) => error.operationError?.code,
                'server code',
                'session_revoked',
              )
              .having(
                (error) => error.operationError?.status,
                'server status',
                401,
              ),
        ),
      );
      expect(record.value == credentials(), isTrue);
      expect(record.deletions, 0);
    },
  );

  for (final kind in [
    'timeout',
    'connection',
    'storage',
    'oversized',
    'malformed',
    'server',
    'rate-limited',
  ]) {
    test(
      'C-08 uncertain refresh $kind is shared, retained and not sent again until new login',
      () async {
        var business = 0;
        var refreshes = 0;
        final bothStarted = Completer<void>();
        final record = Record(credentials())..failReplace = kind == 'storage';
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth.refresh') {
            refreshes++;
            if (refreshes > 1) {
              await reply(request, credentials(rotated: true).toJson());
              return;
            }
            if (kind == 'storage') {
              await reply(request, credentials(rotated: true).toJson());
            } else if (kind == 'oversized') {
              request.response.write(
                '${jsonEncode(credentials(rotated: true).toJson())}${' ' * (1024 * 1024)}',
              );
              await request.response.close();
            } else if (kind == 'malformed') {
              request.response.write('[');
              await request.response.close();
            } else if (kind == 'server') {
              await reply(request, {'error': 'operation_failed'}, status: 500);
            } else if (kind == 'rate-limited') {
              await reply(request, {'error': 'rate_limited'}, status: 429);
            } else {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              addTearDown(socket.destroy);
              if (kind == 'connection') {
                socket.destroy();
              } else {
                socket.listen((_) {});
              }
            }
          } else {
            business++;
            if (business == 2) bothStarted.complete();
            if (business <= 2) await bothStarted.future;
            await reply(request, {'error': 'invalid_token'}, status: 401);
          }
        });
        final firstStore = MemorySessionStore(
          peer.origin,
          'uncertain-$kind',
          record,
        );
        final secondStore = MemorySessionStore(
          peer.origin,
          'uncertain-$kind',
          record,
        );
        final first = peer
            .transport(timeout: const Duration(milliseconds: 300))
            .withSession(firstStore);
        final second = peer
            .transport(timeout: const Duration(milliseconds: 300))
            .withSession(secondStore);
        final failure = switch (kind) {
          'timeout' => clientFailure('request_timeout'),
          'connection' => clientFailure('network_error'),
          'storage' => clientFailure('session_storage_error'),
          'oversized' => clientFailure('response_too_large', status: 200),
          'malformed' => clientFailure('invalid_response', status: 200),
          'rate-limited' => operationFailure('rate_limited', 429),
          _ => operationFailure('operation_failed', 500),
        };
        final refreshEvents = <String, ConformanceRefreshEvent>{};
        final httpEvents = <String, List<ConformanceHttpEvent>>{};
        final observer = Observer(
          onRecord: (event) {
            final id = currentConformanceCall!.callId;
            if (event is ConformanceRefreshEvent) refreshEvents[id] = event;
            if (event is ConformanceHttpEvent) {
              (httpEvents[id] ??= []).add(event);
            }
          },
        );
        await Future.wait([
          expectLater(
            withConformanceCall(
              conformanceCall('first', 'thing.write', observer),
              () => first.invoke('thing.write', {}),
            ),
            throwsA(failure),
          ),
          expectLater(
            withConformanceCall(
              conformanceCall('second', 'thing.write', observer),
              () => second.invoke('thing.write', {}),
            ),
            throwsA(failure),
          ),
        ]);
        expect(business, 2);
        expect(refreshes, 1);
        expect(record.value == credentials(), isTrue);
        expect(record.deletions, 0);
        if (conformanceEnabled) {
          expect(refreshEvents.keys, unorderedEquals(['first', 'second']));
          expect(
            identical(
              refreshEvents['first']!.flight,
              refreshEvents['second']!.flight,
            ),
            isTrue,
          );
          final expectedStatus = switch (kind) {
            'oversized' || 'malformed' => 200,
            'server' => 500,
            'rate-limited' => 429,
            _ => null,
          };
          expect(
            refreshEvents.values.map((event) => event.status),
            everyElement(expectedStatus),
          );
          final worker = httpEvents.values
              .expand((events) => events)
              .where((event) => event.operation == 'auth.refresh')
              .toList();
          expect(worker.first.phase, ConformancePhase.sending);
          expect(
            worker.last.phase,
            kind == 'storage'
                ? ConformancePhase.completed
                : ConformancePhase.failed,
          );
          expect(worker.last.status, kind == 'storage' ? 200 : expectedStatus);
          expect(
            worker.last.bodyComplete,
            ['storage', 'malformed', 'server', 'rate-limited'].contains(kind),
          );
          final observation = refreshEvents['first']!.observation!;
          expect(
            identical(observation, refreshEvents['second']!.observation),
            isTrue,
          );
          expect(observation.credentialsValidated, kind == 'storage');
          expect(observation.credentialsStored, isFalse);
          expect(observation.rejected401, isFalse);
          expect(observation.attempt!.socketBytesWritten, greaterThan(0));
          expect(observation.outcomeUnknown, isTrue);
        }
        final suppressed = conformanceCall(
          'suppressed',
          'thing.write',
          Observer(),
        );
        await expectLater(
          withConformanceCall(
            suppressed,
            () => second.invoke('thing.write', {}),
          ),
          throwsA(operationFailure('invalid_token', 401)),
        );
        expect(refreshes, 1);
        if (conformanceEnabled) {
          expect(suppressed.refreshObservation, isNull);
          expect(suppressed.httpObservation!.operation, 'thing.write');
          expect(suppressed.httpObservation!.outcomeUnknown, isFalse);
        }
        expect(record.value == credentials(), isTrue);
        expect(record.replacements, 0);
        expect(record.deletions, 0);
        record.failReplace = false;
        await firstStore.write(
          credentials(rotated: true, session: 'new-session'),
        );
        await expectLater(
          first.invoke('thing.write', {}),
          throwsA(clientFailure('invalid_response')),
        );
        expect(refreshes, 2);
      },
    );
  }

  test(
    'C-08 late unknown outcome cannot erase suspension of a newer login',
    () async {
      final oldStarted = Completer<void>();
      final releaseOld = Completer<void>();
      final record = Record(credentials())..failReplace = true;
      var refreshes = 0;
      final peer = await Peer.start((request) async {
        final body = await readBody(request);
        if (request.uri.path == '/auth.refresh') {
          refreshes++;
          if ((body as Map<String, Object?>)['refresh_token'] == refreshToken) {
            oldStarted.complete();
            await releaseOld.future;
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
          } else {
            await reply(
              request,
              credentials(rotated: true, session: 'new-session').toJson(),
            );
          }
        } else {
          await reply(request, {'error': 'invalid_token'}, status: 401);
        }
      });
      final firstStore = MemorySessionStore(
        peer.origin,
        'overlapping-unknown',
        record,
      );
      final secondStore = MemorySessionStore(
        peer.origin,
        'overlapping-unknown',
        record,
      );
      final old = expectLater(
        peer.transport().withSession(firstStore).invoke('thing.write', {}),
        throwsA(clientFailure('network_error')),
      );
      await oldStarted.future;
      await secondStore.write(
        credentials(rotated: true, session: 'new-session'),
      );
      final newer = peer.transport().withSession(secondStore);
      await expectLater(
        newer.invoke('thing.write', {}),
        throwsA(clientFailure('session_storage_error')),
      );
      releaseOld.complete();
      await old;
      await expectLater(
        newer.invoke('thing.write', {}),
        throwsA(operationFailure('invalid_token', 401)),
      );
      expect(refreshes, 2);
      expect(
        record.value == credentials(rotated: true, session: 'new-session'),
        isTrue,
      );
    },
  );

  for (final change in ['user', 'session', 'expiry', 'shape']) {
    test(
      'C-08 refresh rejects $change change without replacing credentials or replaying',
      () async {
        var business = 0;
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth.refresh') {
            await reply(
              request,
              change == 'shape'
                  ? {'access_token': 'bad'}
                  : credentials(
                      rotated: true,
                      user: change == 'user' ? 'other' : 'user-one',
                      session: change == 'session' ? 'other' : 'session-one',
                      refreshExpiry: change == 'expiry'
                          ? '2026-10-21T12:00:00Z'
                          : '2026-10-20T12:00:00.000000Z',
                    ).toJson(),
            );
          } else {
            business++;
            await reply(request, {'error': 'invalid_token'}, status: 401);
          }
        });
        final record = Record(credentials());
        await expectLater(
          peer
              .transport()
              .withSession(
                MemorySessionStore(peer.origin, 'identity-$change', record),
              )
              .invoke('thing.write', {}),
          throwsA(clientFailure('invalid_response')),
        );
        expect(business, 1);
        expect(record.value == credentials(), isTrue);
        expect(record.replacements, 0);
      },
    );
  }

  for (final newLogin in [false, true]) {
    test(
      'C-10 logout ${newLogin ? 'preserves a new login' : 'clears rotated credentials'}',
      () async {
        final record = Record(credentials());
        final peer = await Peer.start((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth.refresh') {
            await reply(request, credentials(rotated: true).toJson());
          } else if (request.headers.value('authorization') ==
              'Bearer $accessToken') {
            await reply(request, {'error': 'invalid_token'}, status: 401);
          } else {
            if (newLogin) {
              record.value = credentials(rotated: true, session: 'new-session');
            }
            await reply(request, {'status': 'ok'});
          }
        });
        final store = MemorySessionStore(
          peer.origin,
          'logout-$newLogin',
          record,
        );
        final expected = await store.read();
        await peer.transport().withSession(store).invoke('auth.logout', {});
        final latest = await store.read();
        if (latest != null &&
            latest.userId == expected?.userId &&
            latest.sessionId == expected?.sessionId) {
          await store.compareAndSet(latest, null);
        }
        expect(
          newLogin
              ? record.value?.sessionId == 'new-session'
              : record.value == null,
          isTrue,
        );
        expect(record.deletions, newLogin ? 0 : 1);
      },
    );
  }
}

class FaultyStore extends MemorySessionStore {
  FaultyStore(Record record, this.fails)
    : super('http://127.0.0.1', 'faulty', record);
  final bool fails;
  final failure = StateError('delegate');
  final arguments = <(SessionCredentials, SessionCredentials?)>[];
  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) async {
    arguments.add((expected, next));
    if (fails) throw failure;
    // Use a broken store deliberately to detect policy changes in the decorator.
    record.value = next;
    return true;
  }
}
