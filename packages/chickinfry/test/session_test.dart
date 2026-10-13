import 'dart:async';
import 'dart:convert';

import 'package:chickinfry/chickinfry.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
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
        await expectLater(
          transport.invoke('thing.get', {}),
          throwsA(
            clientFailure(
              corrupt ? 'invalid_session_record' : 'session_storage_error',
            ),
          ),
        );
        expect(peer.requests, 0);
        expect(record.value == credentials(), isTrue);
        expect(record.deletions, 0);
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
    final calls = [
      for (final call in [
        first.invoke('thing.first', {}),
        second.invoke('thing.second', {}),
      ])
        call.then<Object?>((value) => value, onError: (Object error) => error),
    ];
    final late = first
        .invoke('thing.late', {})
        .then<Object?>((value) => value, onError: (Object error) => error);
    await refreshStarted.future;
    releaseRefresh.complete();
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
      final first = peer.transport().withSession(
        MemorySessionStore(peer.origin, 'reject', record),
      );
      final second = peer.transport().withSession(
        MemorySessionStore(peer.origin, 'reject', record),
      );
      await Future.wait([
        expectLater(
          first.invoke('thing.get', {}),
          throwsA(operationFailure('session_revoked', 401)),
        ),
        expectLater(
          second.invoke('thing.get', {}),
          throwsA(operationFailure('session_revoked', 401)),
        ),
      ]);
      expect(record.value == null, isTrue);
      expect(record.deletions, 1);
      expect(initial, 2);
      expect(refreshes, 1);
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
        final store = MemorySessionStore(
          peer.origin,
          'cas-race-$succeeds',
          record,
        );
        final outcome = expectLater(
          peer.transport().withSession(store).invoke('thing.write', {}),
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
          _ => operationFailure('operation_failed', 500),
        };
        await Future.wait([
          expectLater(first.invoke('thing.write', {}), throwsA(failure)),
          expectLater(second.invoke('thing.write', {}), throwsA(failure)),
        ]);
        expect(business, 2);
        expect(refreshes, 1);
        expect(record.value == credentials(), isTrue);
        expect(record.deletions, 0);
        await expectLater(
          second.invoke('thing.write', {}),
          throwsA(operationFailure('invalid_token', 401)),
        );
        expect(refreshes, 1);
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
