@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/browser_session.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

@JS('Function')
external JSFunction _function(JSString body);
@JS('readerCancels')
external int get readerCancels;

const fixtureOrigin = 'http://127.0.0.1:18739';

Matcher local(String code, [int? status]) => isA<ClientException>()
    .having((e) => e.code, 'code', code)
    .having((e) => e.status, 'status', status);
Matcher remote(String code, int status) => isA<OperationError>()
    .having((e) => e.code, 'code', code)
    .having((e) => e.status, 'status', status);

void main() {
  setUpAll(() {
    _function(
      r'''
      globalThis.readerCancels = 0;
      const prototype = ReadableStreamDefaultReader.prototype;
      const original = prototype.cancel;
      prototype.cancel = function(...args) {
        globalThis.readerCancels++;
        return original.apply(this, args);
      };
      globalThis.restoreReader = () => { prototype.cancel = original; };
    '''
          .toJS,
    ).callAsFunction();
  });
  tearDownAll(
    () => _function('globalThis.restoreReader();'.toJS).callAsFunction(),
  );
  late HttpTransport transport;
  late BrowserAuth auth;
  Future<Map<String, Object?>> control([
    Map<String, Object?> input = const {},
  ]) async =>
      (await transport.invoke('test.control', input)) as Map<String, Object?>;
  Future<void> arrived(String key) async {
    for (var i = 0; i < 100; i++) {
      final state = await control();
      if ((state['arrived'] as List).contains(key)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Response barrier was not reached.');
  }

  setUp(() async {
    transport = HttpTransport(fixtureOrigin);
    auth = BrowserAuth(transport);
    await control({'reset': true});
  });
  tearDown(() => transport.close());

  test('browser HttpTransport sends JSON through Fetch', () async {
    expect(
      () => HttpTransport('http://localhost:18739'),
      throwsA(local('invalid_origin')),
    );
    expect(await transport.invoke('thing.echo', {'value': 7}), {'value': 7});
    expect((await control())['boundary'], isTrue);
    expect(
      () => transport.withBearer(''),
      throwsA(local('unsupported_auth_transport')),
    );
    expect(
      () => transport.withSession(_UnreachableStore()),
      throwsA(local('unsupported_auth_transport')),
    );
  });

  test('cookie login confirms session and survives a fresh document', () async {
    final session = await auth.authenticate('auth.signin', {'account': 'a'});
    expect(session.id, 'a');
    expect(await transport.invoke('thing.protected', {}), {'id': 'a'});
    final recreated = HttpTransport(fixtureOrigin);
    addTearDown(recreated.close);
    expect(
      (await BrowserAuth(recreated).session()).sessionId,
      session.sessionId,
    );
    final frame = web.HTMLIFrameElement()..src = '$fixtureOrigin/restore.html';
    web.document.body!.append(frame);
    try {
      final watch = Stopwatch()..start();
      Object? restored;
      while (watch.elapsed < const Duration(seconds: 10)) {
        final state = await control();
        restored = state['restored'];
        if (restored != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(restored, {'id': 'a'});
    } finally {
      frame.remove();
    }
    expect((await control())['calls'], {
      'auth.signin': 1,
      'auth.session': 3,
      'thing.protected': 1,
    });
    await auth.logout();
    await expectLater(auth.session(), throwsA(remote('invalid_token', 401)));
  });

  test(
    'cookie rejection and invalid auth operation do not fall back',
    () async {
      await expectLater(
        auth.authenticate('auth.signup', {'omitCookie': true}),
        throwsA(remote('invalid_token', 401)),
      );
      await expectLater(
        auth.authenticate('auth.refresh', {}),
        throwsA(local('invalid_input')),
      );
      expect((await control())['calls'], {'auth.signup': 1, 'auth.session': 1});
    },
  );

  test('authentication confirms user and session identity without automatic logout', () async {
    for (final field in ['id', 'sessionId']) {
      await control({'mismatch': field});
      await expectLater(
        auth.authenticate('auth.identity', {'account': 'a'}),
        throwsA(local('session_changed')),
      );
      expect((await auth.session()).id, 'a');
    }
    expect((await control())['calls'], {'auth.identity': 2, 'auth.session': 4});
  });

  for (final status in [401, 403]) {
    test(
      '$status preserves code and cookie without refresh logout or replay',
      () async {
        await auth.authenticate('auth.signin', {'account': 'b'});
        await expectLater(
          transport.invoke('thing.reject', {'status': status}),
          throwsA(
            remote(status == 401 ? 'invalid_token' : 'not_allowed', status),
          ),
        );
        expect((await auth.session()).id, 'b');
        expect((await control())['calls'], {
          'auth.signin': 1,
          'auth.session': 2,
          'thing.reject': 1,
        });
      },
    );
  }

  test('failed logout preserves the active server session', () async {
    await auth.authenticate('auth.signin', {'account': 'a'});
    await expectLater(
      transport.invoke('auth.logout', {'fail': true}),
      throwsA(remote('database_error', 500)),
    );
    expect((await auth.session()).id, 'a');
  });

  test('all manual redirects preserve opaque status and never reach either destination', () async {
    await auth.authenticate('auth.signin', {'account': 'a'});
    for (final status in [301, 302, 303, 307, 308]) {
      for (final external in [false, true]) {
        await expectLater(
          transport.invoke('thing.redirect', {
            'status': status,
            'external': external,
          }),
          throwsA(remote('redirect_not_allowed', 0)),
        );
      }
    }
    final state = await control();
    expect(state['destinations'], 0);
    expect((state['calls'] as Map)['thing.redirect'], 10);
  });

  test(
    'UTF-8 request boundary sends once and rejects oversize before Fetch',
    () async {
      final input = {'data': 'x' * (4 * 1024 * 1024 - 11)};
      await expectLater(
        transport.invoke('thing.echo', input),
        throwsA(local('response_too_large', 200)),
      );
      input['data'] = '${input['data']}x';
      await expectLater(
        transport.invoke('thing.echo', input),
        throwsA(local('request_too_large')),
      );
      await expectLater(
        transport.invoke('invalid/name', {}),
        throwsA(local('invalid_input')),
      );
      await expectLater(
        transport.invoke('thing.echo', {'bad': Object()}),
        throwsA(local('invalid_input')),
      );
      expect((await control())['calls'], {'thing.echo': 1});
    },
  );

  test('response stream byte limit is inclusive', () async {
    final result =
        await transport.invoke('thing.bytes', {'size': 1024 * 1024}) as Map;
    expect((result['data'] as String).length, 1024 * 1024 - 11);
    final cancellations = readerCancels;
    await expectLater(
      transport.invoke('thing.bytes', {'size': 1024 * 1024 + 1}),
      throwsA(local('response_too_large', 200)),
    );
    expect(readerCancels, cancellations + 1);
  });

  test('deadline covers a stalled body and cancels its reader', () async {
    final short = HttpTransport(
      fixtureOrigin,
      timeout: const Duration(milliseconds: 250),
    );
    addTearDown(short.close);
    final cancellations = readerCancels;
    final watch = Stopwatch()..start();
    await expectLater(
      short.invoke('thing.slow', {}),
      throwsA(local('request_timeout', 200)),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(readerCancels, cancellations + 1);
  });

  test('invalid JSON UTF-8 roots and error envelopes retain status', () async {
    for (final body in ['[', '[]', 'null', '{}', '{"error":"Not.Valid"}']) {
      final status = body == '{}' || body.contains('error') ? 503 : 200;
      await expectLater(
        transport.invoke('thing.invalid', {'body': body, 'status': status}),
        throwsA(local('invalid_response', status)),
      );
    }
    await expectLater(
      transport.invoke('thing.invalid', {'utf8': false}),
      throwsA(local('invalid_response', 200)),
    );
    await expectLater(
      transport.invoke('thing.cors', {}),
      throwsA(local('network_error')),
    );
    final closed = HttpTransport(fixtureOrigin)..close();
    await expectLater(
      closed.invoke('thing.echo', {}),
      throwsA(local('network_error')),
    );
  });

  for (final reject in [false, true]) {
    test(
      'late business ${reject ? '401' : 'success'} leaves B signed in',
      () async {
        await auth.authenticate('auth.signin', {'account': 'a'});
        final pending = transport.invoke(
          reject ? 'thing.reject' : 'thing.protected',
          {'hold': 'business', if (reject) 'status': 401},
        );
        final check = reject
            ? expectLater(pending, throwsA(remote('invalid_token', 401)))
            : null;
        await arrived('business');
        await auth.authenticate('auth.signin', {'account': 'b'});
        await control({'release': 'business'});
        if (check != null) {
          await check;
        } else {
          expect(await pending, {'id': 'a'});
        }
        expect((await auth.session()).id, 'b');
        expect((await control())['calls'], {
          'auth.signin': 2,
          'auth.session': 3,
          (reject ? 'thing.reject' : 'thing.protected'): 1,
        });
      },
    );
  }

  test(
    'late committed logout may delete B cookie without revoking B',
    () async {
      await auth.authenticate('auth.signin', {'account': 'a'});
      final held = transport.invoke('auth.logout', {'hold': 'logout'});
      await arrived('logout');
      await auth.authenticate('auth.signin', {'account': 'b'});
      await control({'release': 'logout'});
      await held;
      await expectLater(auth.session(), throwsA(remote('invalid_token', 401)));
      final state = await control();
      expect(state['calls'], {
        'auth.signin': 2,
        'auth.session': 3,
        'auth.logout': 1,
      });
      expect(state['active'], contains('b'));
    },
  );

  for (final revoke in [false, true]) {
    test(
      'late issuance ${revoke ? 'revoked A is rejected' : 'valid A can replace B'}',
      () async {
        final pending = transport.invoke('auth.signin', {
          'account': 'a',
          'hold': 'issue',
        });
        await arrived('issue');
        if (revoke) await control({'revoke': 'a'});
        await auth.authenticate('auth.signin', {'account': 'b'});
        await control({'release': 'issue'});
        await pending;
        if (revoke) {
          await expectLater(
            transport.invoke('thing.protected', {}),
            throwsA(remote('invalid_token', 401)),
          );
          expect((await control())['executions'], 0);
        } else {
          expect((await auth.session()).id, 'a');
        }
      },
    );
  }
}

class _UnreachableStore implements SessionStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Native store was accessed.');
}
