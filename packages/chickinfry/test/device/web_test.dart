@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/browser_session.dart';
import 'package:chickinfry/src/device/bridge.dart';
import 'package:chickinfry/src/device/store.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

@JS('Function')
external JSFunction _function(JSString body);

const _origin = 'http://127.0.0.1:18739';
const _prefix = 'chickinfry:device:';

void js(String body) => _function(body.toJS).callAsFunction();
Matcher local(String code) =>
    isA<ClientError>().having((e) => e.code, 'code', code);
Matcher remote(String code) =>
    isA<OperationError>().having((e) => e.code, 'code', code);

void main() {
  late HttpTransport controlTransport;
  Future<Map<String, Object?>> control([
    Map<String, Object?> input = const {},
  ]) async =>
      await controlTransport.invoke('test.control', input)
          as Map<String, Object?>;
  DeviceTransport device({
    String app = 'web.test',
    String project = 'project',
    String environment = 'test',
    String origin = _origin,
    String screen = 'signup',
    Persist? persist,
  }) {
    final value = createDeviceTransport(
      app: app,
      origin: origin,
      project: project,
      environment: environment,
      screen: screen,
      persist: persist,
    );
    addTearDown(value.close);
    return value;
  }

  Future<Map<String, Object?>> restored(String phase) async {
    for (var i = 0; i < 250; i++) {
      final value = (await control())['restored'];
      if (value is Map<String, Object?> && value['phase'] == phase) {
        return value;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Document did not finish the storage check.');
  }

  Future<void> arrived(String name) async {
    for (var i = 0; i < 100; i++) {
      if (((await control())['arrived'] as List).contains(name)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Response barrier was not reached.');
  }

  void blockStorage() {
    js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new DOMException('Blocked', 'SecurityError'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
    addTearDown(() => js('globalThis.restoreStorage();'));
  }

  setUp(() async {
    controlTransport = HttpTransport(_origin);
    await control({'reset': true});
    js("""
      for (const key of Object.keys(localStorage)) {
        if (key.startsWith('chickinfry:device:') || key === 'device-quota-fill')
          localStorage.removeItem(key);
      }
    """);
  });
  tearDown(() => controlTransport.close());

  test('verified signin write retains proof after peer signup', () async {
    final actor = device(screen: 'actor6');
    final peer = device(screen: 'peer6');
    final before = await actor.store.load();
    js("""
      const original = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) {
        original.call(this, key, value);
        if (key.startsWith('chickinfry:device:')) throw new DOMException('After write', 'SecurityError');
      };
      globalThis.restoreReview6Write = () => { Storage.prototype.setItem = original; };
    """);
    addTearDown(() => js('globalThis.restoreReview6Write();'));
    await actor.invoke('auth.signin', {'email': 'a@example.test'});
    js('globalThis.restoreReview6Write();');
    expect(actor.store.transientState != null, isTrue);
    expect(actor.store.consumedAttemptEmails.values.single.settled, isTrue);
    final persisted = await peer.store.load();
    expect(actor.store.recoveryWasApplied(persisted), isTrue);
    expect(persisted.authGeneration, before.authGeneration + 1);
    await peer.invoke('auth.signup', {
      'pending': true,
      'email': 'a@example.test',
    });
    final afterPeer = await peer.store.load();
    expect(afterPeer.authGeneration, persisted.authGeneration);
    expect(afterPeer.attempts.containsKey('peer6'), isTrue);
    final raw = web.window.localStorage.getItem(peer.store.coordinationKey);
    String? code;
    try {
      await actor.invoke('auth.send_verification_email', {
        'attempt': afterPeer.attempts['peer6']!.id,
      });
    } on ClientError catch (error) {
      code = error.code;
    }
    final retained =
        web.window.localStorage.getItem(peer.store.coordinationKey) == raw;

    final calls = (await control())['calls'] as Map;
    expect(calls['auth.signin'], 1);
    expect(calls['auth.signup'], 1);
    expect(calls['auth.session'], 1);
    expect(retained, isTrue);
    String? laterCode;
    try {
      await actor.invoke('auth.session', {});
    } on ClientError catch (error) {
      laterCode = error.code;
    }

    expect(
      code,
      isNull,
      reason: 'Peer signup attempts must not invalidate a verified own auth boundary.',
    );
    expect(laterCode, isNull);
    expect(actor.store.blocked, isFalse);
    expect(actor.store.transientState, isNull);
  });

  test(
    'device storage survives document reload and close and uses server cookies',
    () async {
      final parent = device(screen: 'parent');
      final initial = await parent.store.load();
      await parent.store.commit(
        initial,
        DeviceState(
          generation: initial.generation + 1,
          attempts: {
            'parent': DeviceAttempt(
              web.window.crypto.randomUUID(),
              'parent@example.test',
              DateTime.now().millisecondsSinceEpoch,
            ),
          },
        ),
      );
      var frame = web.HTMLIFrameElement()
        ..src = '$_origin/restore.html?device=seed';
      web.document.body!.append(frame);
      try {
        final result = await restored('reload');
        expect(result['ok'], isTrue);
        expect((await control())['loads'], {
          '/restore.html': 2,
          '/restore.js': 2,
        });
        frame.remove();
        frame = web.HTMLIFrameElement()
          ..src = '$_origin/restore.html?device=closed';
        web.document.body!.append(frame);
        expect((await restored('closed'))['ok'], isTrue);
        frame.remove();
        frame = web.HTMLIFrameElement()
          ..src = '$_origin/restore.html?device=logout';
        web.document.body!.append(frame);
        expect((await restored('logout'))['ok'], isTrue);
        expect((await parent.store.load()).attempts.keys.toList(), ['parent']);
        final calls = (await control())['calls'] as Map;
        expect(calls['auth.signup'], 1);
        expect(calls['auth.verify_email'], 1);
        expect(calls['auth.logout'], 1);
        expect(calls.containsKey('auth.refresh'), isFalse);
      } finally {
        frame.remove();
      }
    },
  );

  test('owner contexts stay separate and each screen restores only its own attempt', () async {
    final a = device(screen: 'a');
    final b = device(screen: 'b');
    await a.invoke('auth.signup', {'pending': true, 'email': 'a@example.test'});
    await b.invoke('auth.signup', {'pending': true, 'email': 'b@example.test'});
    expect(
      (await a.invoke('auth.send_verification_email', {
        'expectedEmail': 'a@example.test',
      }) as Map)['matches'],
      isTrue,
    );
    expect(
      (await b.invoke('auth.send_verification_email', {
        'expectedEmail': 'b@example.test',
      }) as Map)['matches'],
      isTrue,
    );
    final state = await a.store.load();
    expect(state.attempts.keys.toSet(), {'a', 'b'});
    final otherScreen = device(screen: 'c');
    await expectLater(
      otherScreen.invoke('auth.send_verification_email', {}),
      throwsA(remote('invalid_code')),
    );
    for (final other in [
      device(app: 'other'),
      device(project: 'other'),
      device(environment: 'other'),
      device(origin: 'https://other.example.test'),
    ]) {
      expect((await other.store.load()).attempts.isEmpty, isTrue);
      expect(other.store.coordinationKey != a.store.coordinationKey, isTrue);
    }
    expect((await control())['attemptScreens'], 2);
  });

  test('storage getter denial exposes unavailable but server success stays in memory', () async {
    final client = device();
    js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new DOMException('Blocked', 'SecurityError'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
    addTearDown(() => js('globalThis.restoreStorage();'));
    await expectLater(
      client.store.load(),
      throwsA(local('failed_precondition')),
    );
    final pending = await client.invoke('auth.signup', {
      'pending': true,
      'email': 'blocked@example.test',
    }) as Map;
    expect(pending['accepted'], isTrue);
    expect((await client.store.load()).attempts.length, 1);
    await client.invoke('auth.send_verification_email', {});
    await client.invoke('auth.verify_email', {'code': '123456'});
    expect((await BrowserAuth(client).session()).id, 'a');
    expect((await control())['calls'], {
      'auth.signup': 1,
      'auth.send_verification_email': 1,
      'auth.verify_email': 1,
      'auth.session': 2,
    });
  });

  test('real localStorage quota preserves disk and keeps successful signup in memory', () async {
    final client = device();
    final before = await client.store.load();
    js("""
      let low = 0, high = 8 * 1024 * 1024;
      while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        try { localStorage.setItem('device-quota-fill', 'x'.repeat(mid)); low = mid + 1; }
        catch (e) { if (e.name !== 'QuotaExceededError') throw e; high = mid - 1; }
      }
    """);
    addTearDown(() => web.window.localStorage.removeItem('device-quota-fill'));
    await expectLater(
      client.store.commit(before, DeviceState(generation: 1)),
      throwsA(local('resource_exhausted')),
    );
    final result = await client.invoke('auth.signup', {
      'pending': true,
      'email': 'quota@example.test',
    }) as Map;
    expect(result['accepted'], isTrue);
    expect((await client.store.load()).attempts.length, 1);
    await client.invoke('auth.send_verification_email', {});
    expect(
      web.window.localStorage.getItem(client.store.coordinationKey) == null,
      isTrue,
    );
    expect((await control())['calls'], {
      'auth.signup': 1,
      'auth.send_verification_email': 1,
    });
  });

  test('throwing writes stay unavailable and failed local deletion blocks the instance', () async {
    final client = device();
    await client.invoke('auth.signup', {
      'pending': true,
      'email': 'delete@example.test',
    });
    js("""
      const original = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) {
        if (key.startsWith('chickinfry:device:')) throw new DOMException('Blocked', 'SecurityError');
        return original.call(this, key, value);
      };
      globalThis.restoreStorage = () => { Storage.prototype.setItem = original; };
    """);
    addTearDown(() => js('globalThis.restoreStorage();'));
    await expectLater(
      client.invoke('auth.logout', {}),
      throwsA(local('failed_precondition')),
    );
    expect(client.store.blocked, isTrue);
    js('globalThis.restoreStorage();');
    final peer = device();
    await peer.store.commit(
      await peer.store.load(),
      DeviceState(generation: 2),
    );
    await expectLater(
      client.invoke('auth.signin', {}),
      throwsA(local('failed_precondition')),
    );
    expect((await control())['calls'], {'auth.signup': 1, 'auth.logout': 1});
  });

  test('disabled persistence never accesses localStorage and directory remains rejected', () async {
    expect(() => Persist.dir('unused'), throwsA(local('failed_precondition')));
    js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new Error('Storage must not be used'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
    addTearDown(() => js('globalThis.restoreStorage();'));
    final client = device(persist: Persist.disabled);
    await client.invoke('auth.signup', {
      'pending': true,
      'email': 'memory@example.test',
    });
    await client.invoke('auth.verify_email', {'code': '123456'});
    expect((await BrowserAuth(client).session()).id, 'a');
    expect(
      (await device(persist: Persist.disabled).store.load()).attempts.isEmpty,
      isTrue,
    );
  });

  test('browser storage uses shared limits and preserves corrupt or future bundles', () async {
    final client = device();
    final first = await client.store.load();
    final attempts = {
      for (var i = 0; i < 3; i++)
        'screen-$i': DeviceAttempt(
          web.window.crypto.randomUUID(),
          'person-$i@example.test',
          DateTime.now().millisecondsSinceEpoch,
        ),
    };
    expect(
      await client.store.commit(
        first,
        DeviceState(generation: 1, attempts: attempts),
      ),
      isTrue,
    );
    final key = client.store.coordinationKey;
    final original = web.window.localStorage.getItem(key)!;
    final current = await client.store.load();
    expect(
      await client.store.commit(first, DeviceState(generation: 1)),
      isFalse,
    );
    await expectLater(
      client.store.commit(
        current,
        DeviceState(
          generation: 2,
          attempts: {
            ...attempts,
            'extra': DeviceAttempt(
              web.window.crypto.randomUUID(),
              'extra@example.test',
              DateTime.now().millisecondsSinceEpoch,
            ),
          },
        ),
      ),
      throwsA(local('resource_exhausted')),
    );
    expect(web.window.localStorage.getItem(key) == original, isTrue);
    final envelope = jsonDecode(original) as Map<String, Object?>;
    for (final entry in <(String, String)>[
      ('{', 'data_loss'),
      (jsonEncode({...envelope, 'version': 2}), 'unimplemented'),
      (
        jsonEncode({
          ...envelope,
          'owner': ['other'],
        }),
        'data_loss',
      ),
      (' ' * (devicePayloadLimit + 1), 'data_loss'),
    ]) {
      web.window.localStorage.setItem(key, entry.$1);
      await expectLater(client.store.load(), throwsA(local(entry.$2)));
      expect(web.window.localStorage.getItem(key) == entry.$1, isTrue);
    }
  });

  test(
    'unsafe stored generations and attempt times are corrupt and preserved',
    () async {
      final client = device();
      final key = client.store.coordinationKey;
      final unsafe = int.parse('20000000000000', radix: 16);
      final attempt = DeviceAttempt(
        web.window.crypto.randomUUID(),
        'range@example.test',
        DateTime.now().millisecondsSinceEpoch,
      );
      final initial = client.store.bundle(
        DeviceState(attempts: {'signup': attempt}),
      );
      for (final field in ['generation', 'auth_generation', 'started_at']) {
        final envelope =
            jsonDecode(jsonEncode(initial)) as Map<String, Object?>;
        final auth = envelope['auth']! as Map<String, Object?>;
        if (field == 'started_at') {
          (((auth['attempts']! as Map)['signup']) as Map)['started_at'] =
              unsafe;
        } else {
          auth[field] = unsafe;
        }
        final raw = jsonEncode(envelope);
        web.window.localStorage.setItem(key, raw);
        await expectLater(client.store.load(), throwsA(local('data_loss')));
        expect(web.window.localStorage.getItem(key) == raw, isTrue);
      }
    },
  );

  test('next generations and attempt times outside the safe range fail without writing', () async {
    final client = device();
    final key = client.store.coordinationKey;
    const limit = 9007199254740991;
    for (final authLimit in [false, true]) {
      final raw = jsonEncode(
        client.store.bundle(
          DeviceState(
            generation: authLimit ? 0 : limit,
            authGeneration: authLimit ? limit : 0,
          ),
        ),
      );
      web.window.localStorage.setItem(key, raw);
      final before = await client.store.load();
      await expectLater(
        client.store.commit(
          before,
          DeviceState(
            generation: before.generation + 1,
            authGeneration: before.authGeneration + (authLimit ? 1 : 0),
          ),
        ),
        throwsA(local('resource_exhausted')),
      );
      expect(web.window.localStorage.getItem(key) == raw, isTrue);
    }
    final raw = jsonEncode(client.store.bundle(DeviceState()));
    web.window.localStorage.setItem(key, raw);
    final before = await client.store.load();
    await expectLater(
      client.store.commit(
        before,
        DeviceState(
          generation: 1,
          attempts: {
            'signup': DeviceAttempt(
              web.window.crypto.randomUUID(),
              'range@example.test',
              limit + 1,
            ),
          },
        ),
      ),
      throwsA(local('resource_exhausted')),
    );
    expect(web.window.localStorage.getItem(key) == raw, isTrue);
  });

  test('late signup cannot restore attempts after logout', () async {
    final client = device();
    final pending = client.invoke('auth.signup', {
      'pending': true,
      'email': 'late@example.test',
      'hold': 'signup',
    });
    await arrived('signup');
    await client.invoke('auth.logout', {});
    await control({'release': 'signup'});
    expect((await pending as Map)['accepted'], isTrue);
    expect((await client.store.load()).attempts.isEmpty, isTrue);
  });

  group('recovery contract STORE-REJOIN', () {
    for (final priorAttempt in [false, true]) {
      test(
        'unsaved consumption is not settled by peer replacement prior=$priorAttempt',
        () async {
          final actor = device(screen: 'actor');
          final peer = device(screen: 'peer');
          if (priorAttempt) {
            await peer.invoke('auth.signup', {
              'pending': true,
              'email': 'a@example.test',
            });
          }
          final base = await actor.store.load();
          final rawBefore = web.window.localStorage.getItem(
            actor.store.coordinationKey,
          );
          js("""
        const original = Storage.prototype.setItem;
        Storage.prototype.setItem = function() {
          throw new DOMException('Blocked', 'SecurityError');
        };
        globalThis.restoreReview5Write = () => { Storage.prototype.setItem = original; };
      """);
          addTearDown(() => js('restoreReview5Write();'));
          await actor.invoke('auth.signin', {
            'account': 'a',
            'email': 'a@example.test',
          });
          expect(actor.store.transientState, isNotNull);
          expect(
            actor.store.consumedAttemptEmails.containsKey('a@example.test'),
            isTrue,
          );
          expect(
            web.window.localStorage.getItem(actor.store.coordinationKey) ==
                rawBefore,
            isTrue,
          );
          js('restoreReview5Write();');
          final result = await peer.invoke('auth.signup', {
            'pending': true,
            'email': 'a@example.test',
          }) as Map;
          final beforeRecovery = await peer.store.load();
          expect(beforeRecovery.authGeneration, base.authGeneration);
          expect(
            beforeRecovery.attempts['peer']?.id == result['attempt'],
            isTrue,
          );
          expect(
            beforeRecovery.generation >= actor.store.uncertainWrite!.generation,
            isTrue,
          );
          expect(actor.store.recoveryWasApplied(beforeRecovery), isFalse);
          await actor.store.load();
          final after = await peer.store.load();
          final retained = after.attempts['peer']?.id == result['attempt'];
          final counts = (await control())['calls'] as Map;
          expect(counts['auth.signin'], 1);
          expect(counts['auth.signup'], priorAttempt ? 2 : 1);
          expect(after.authGeneration, base.authGeneration + 1);
          expect(actor.store.transientState, isNull);
          expect(
            retained,
            isFalse,
            reason:
                'Unsaved consumption must apply to the first successful write.',
          );
        },
      );
    }
    test(
      'settled consumption stays settled after commit CAS conflict',
      () async {
        final actor = device();
        final peer = device(screen: 'later');
        final first = DeviceAttempt(
          web.window.crypto.randomUUID(),
          'a@example.test',
          DateTime.now().millisecondsSinceEpoch,
        );
        final second = DeviceAttempt(
          web.window.crypto.randomUUID(),
          'b@example.test',
          first.startedAt,
        );
        final later = DeviceAttempt(
          web.window.crypto.randomUUID(),
          first.email,
          first.startedAt + 1,
        );
        await actor.store.commit(
          await actor.store.load(),
          DeviceState(
            generation: 1,
            authGeneration: 1,
            attempts: {'a': first, 'b': second},
          ),
        );
        final base = await actor.store.load();
        js("""
      const original = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) {
        original.call(this, key, value);
        throw new DOMException('Blocked', 'SecurityError');
      };
      globalThis.restoreReviewWrite = () => { Storage.prototype.setItem = original; };
    """);
        addTearDown(() => js('globalThis.restoreReviewWrite();'));
        await actor.store.commitAfterSuccess(
          base,
          DeviceState(
            generation: 2,
            authGeneration: 1,
            attempts: {'b': second},
          ),
          consumedEmail: first.email,
        );
        js('globalThis.restoreReviewWrite();');
        final durable = await peer.store.load();
        expect(durable.attempts.containsKey('a'), isFalse);
        expect(actor.store.uncertainWrite, isNotNull);
        final concurrent = jsonEncode(
          actor.store.bundle(
            DeviceState(
              generation: 3,
              authGeneration: 1,
              attempts: {...durable.attempts, 'later': later},
            ),
          ),
        );
        js("""
      const original = Storage.prototype.getItem;
      let reads = 0;
      Storage.prototype.getItem = function(key) {
        if (key === ${jsonEncode(actor.store.coordinationKey)} && ++reads === 2)
          this.setItem(key, ${jsonEncode(concurrent)});
        return original.call(this, key);
      };
      globalThis.restoreReviewRead = () => { Storage.prototype.getItem = original; };
    """);
        addTearDown(() => js('globalThis.restoreReviewRead();'));
        final memory = actor.store.transientState!;
        expect(
          await actor.store.commitAfterSuccess(
            memory,
            DeviceState(generation: memory.generation + 1, authGeneration: 1),
          ),
          isFalse,
        );
        final beforeRecovery = await peer.store.load();
        expect(beforeRecovery.attempts['later']?.id == later.id, isTrue);
        final revived = actor.store.consumedAttemptEmails.containsKey(
          first.email,
        );
        await actor.store.load();
        final saved = await peer.store.load();
        final kept = saved.attempts['later']?.id == later.id;
        expect(revived, isFalse);
        expect(saved.attempts.containsKey('b'), isFalse);
        expect(
          kept,
          isTrue,
          reason: 'A failed write must not restore settled consumption.',
        );
      },
    );

    for (final persisted in [false, true]) {
      for (final consumeAgain in persisted ? [false, true] : [true]) {
        test(
          'consumption settles persisted=$persisted with later consumption=$consumeAgain',
          () async {
            final actor = device();
            final peer = device(screen: 'later');
            final first = DeviceAttempt(
              web.window.crypto.randomUUID(),
              'a@example.test',
              DateTime.now().millisecondsSinceEpoch,
            );
            final second = DeviceAttempt(
              web.window.crypto.randomUUID(),
              'b@example.test',
              first.startedAt,
            );
            final later = DeviceAttempt(
              web.window.crypto.randomUUID(),
              first.email,
              first.startedAt + 1,
            );
            await actor.store.commit(
              await actor.store.load(),
              DeviceState(
                generation: 1,
                authGeneration: 1,
                attempts: {'a': first, 'b': second},
              ),
            );
            final base = await actor.store.load();
            js("""
            const original = Storage.prototype.setItem;
            Storage.prototype.setItem = function(key, value) {
              ${persisted ? 'original.call(this, key, value);' : ''}
              throw new DOMException('Blocked', 'SecurityError');
            };
            globalThis.restoreConsumptionWrite = () => { Storage.prototype.setItem = original; };
          """);
            addTearDown(() => js('globalThis.restoreConsumptionWrite();'));
            await actor.store.commitAfterSuccess(
              base,
              DeviceState(
                generation: 2,
                authGeneration: 1,
                attempts: {'b': second},
              ),
              consumedEmail: first.email,
            );
            expect(actor.store.uncertainWrite, isNotNull);
            js('globalThis.restoreConsumptionWrite();');
            final durable = await peer.store.load();
            expect(durable.attempts.containsKey('a'), !persisted);
            final concurrent = jsonEncode(
              actor.store.bundle(
                DeviceState(
                  generation: durable.generation + 1,
                  authGeneration: 1,
                  attempts: {...durable.attempts, 'later': later},
                ),
              ),
            );
            blockStorage();
            final memory = actor.store.transientState!;
            await actor.store.commitAfterSuccess(
              memory,
              DeviceState(generation: memory.generation + 1, authGeneration: 1),
              consumedEmail: consumeAgain ? first.email : null,
            );
            js('globalThis.restoreStorage();');
            // Let recovery prove the exact candidate before a peer wins the CAS.
            js("""
            const original = Storage.prototype.getItem;
            let reads = 0;
            Storage.prototype.getItem = function(key) {
              if (key === ${jsonEncode(actor.store.coordinationKey)} && ++reads === 2)
                this.setItem(key, ${jsonEncode(concurrent)});
              return original.call(this, key);
            };
            globalThis.restoreConsumptionRead = () => { Storage.prototype.getItem = original; };
          """);
            addTearDown(() => js('globalThis.restoreConsumptionRead();'));
            final recovered = await actor.store.load();
            final saved = await peer.store.load();
            expect(recovered.authGeneration, 1);
            expect(saved.authGeneration, 1);
            expect(saved.attempts.containsKey('b'), isFalse);
            expect(
              saved.attempts['later']?.id == later.id,
              !consumeAgain,
              reason: 'Only consumption not reflected in the persisted candidate may clear the later signup.',
            );
            expect(recovered.attempts['later']?.id == later.id, !consumeAgain);
            expect(actor.store.transientState, isNull);
          },
        );
      }
    }
    for (final sameEmail in [false, true]) {
      test(
        sameEmail
            ? 'authentication consumption clears peer attempt for matching email'
            : 'expiry cleanup retains peer attempt after unrelated signin',
        () async {
          final actor = device();
          final peer = device(screen: 'peer');
          await actor.store.commit(
            await actor.store.load(),
            DeviceState(
              generation: 1,
              attempts: {
                'old': DeviceAttempt(
                  web.window.crypto.randomUUID(),
                  'pending@example.test',
                  DateTime.now().millisecondsSinceEpoch,
                ),
              },
            ),
          );
          final key = actor.store.coordinationKey;
          final bundle = jsonDecode(
            web.window.localStorage.getItem(key)!,
          ) as Map<String, Object?>;
          final auth = bundle['auth']! as Map<String, Object?>;
          final attempts = auth['attempts']! as Map<String, Object?>;
          (attempts['old']! as Map<String, Object?>)['started_at'] =
              DateTime.now().millisecondsSinceEpoch -
              const Duration(hours: 25).inMilliseconds;
          web.window.localStorage.setItem(key, jsonEncode(bundle));
          final signin = actor.invoke('auth.signin', {
            'email': sameEmail
                ? 'pending@example.test'
                : 'signedin@example.test',
            'hold': 'expiry-signin',
          });
          await arrived('expiry-signin');
          final pending = await peer.invoke('auth.signup', {
            'email': 'pending@example.test',
            'pending': true,
          }) as Map<String, Object?>;
          final afterPeer = await peer.store.load();
          expect(afterPeer.attempts['peer']?.id == pending['attempt'], isTrue);
          expect(afterPeer.attempts.containsKey('old'), isFalse);
          blockStorage();
          await control({'release': 'expiry-signin'});
          await signin;
          expect(actor.store.transientState, isNotNull);
          js('globalThis.restoreStorage();');
          final recovered = await actor.store.load();
          final durable = await device().store.load();
          expect(durable.authGeneration, 1);
          expect(
            durable.attempts['peer']?.id == pending['attempt'],
            !sameEmail,
            reason: 'Only authentication for the matching email consumes peer attempts.',
          );
          expect(
            recovered.attempts['peer']?.id == pending['attempt'],
            !sameEmail,
          );
          expect((await control())['calls'], containsPair('auth.signin', 1));
          expect((await control())['calls'], containsPair('auth.signup', 1));
        },
      );
    }

    test('recovery 1 attempt kept after recovery', () async {
      final client = device();
      final before = await client.store.load();
      await client.store.commit(
        before,
        DeviceState(generation: 1, authGeneration: 1),
      );
      js("""
        const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
        Object.defineProperty(window, 'localStorage', { configurable: true,
          get() { throw new DOMException('Blocked', 'SecurityError'); } });
        globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
      """);
      addTearDown(() => js('globalThis.restoreStorage();'));
      final result = await client.invoke('auth.signup', {
        'pending': true,
        'email': 'recovery@example.test',
      }) as Map;
      expect(result['accepted'], isTrue);
      expect((await client.store.load()).attempts.length, 1);
      js('globalThis.restoreStorage();');
      // No other request or storage write happened while access was blocked.
      expect(
        (await client.store.load()).attempts.length,
        1,
        reason: 'Recovery must not erase the accepted attempt from memory',
      );
      await client.invoke('auth.send_verification_email', {});
      expect(client.store.transientState, isNull);
      expect(
        (await device().store.load()).attempts['signup']?.id ==
            result['attempt'],
        isTrue,
      );
      final late = client.invoke('auth.signup', {
        'pending': true,
        'email': 'late-recovery@example.test',
        'hold': 'recovery',
      });
      await arrived('recovery');
      await device(screen: 'other').invoke('auth.logout', {});
      await control({'release': 'recovery'});
      expect((await late as Map)['accepted'], isTrue);
      expect((await client.store.load()).attempts.isEmpty, isTrue);
    });

    test('recovery 2a same object logout fences late signup', () async {
      final client = device();
      await client.store.commit(
        await client.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      js("""
        const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
        Object.defineProperty(window, 'localStorage', { configurable: true,
          get() { throw new DOMException('Blocked', 'SecurityError'); } });
        globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
      """);
      addTearDown(() => js('globalThis.restoreStorage();'));
      final pending = client.invoke('auth.signup', {
        'pending': true,
        'email': 'review2@example.test',
        'hold': 'review2-late',
      });
      await arrived('review2-late');
      js('globalThis.restoreStorage();');
      final other = device(screen: 'other');
      await client.invoke('auth.logout', {});
      expect((await other.store.load()).authGeneration, 2);
      expect((await other.store.load()).attempts.length, 0);
      await control({'release': 'review2-late'});
      expect((await pending as Map)['accepted'], isTrue);
      expect(
        (await device().store.load()).attempts.length,
        0,
        reason: 'A completed logout must fence a previously sent signup',
      );
    });

    test('recovery 2b other object logout drops memory', () async {
      final client = device();
      await client.store.commit(
        await client.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      js("""
        const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
        Object.defineProperty(window, 'localStorage', { configurable: true,
          get() { throw new DOMException('Blocked', 'SecurityError'); } });
        globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
      """);
      addTearDown(() => js('globalThis.restoreStorage();'));
      expect(
        (await client.invoke('auth.signup', {
          'pending': true,
          'email': 'review2@example.test',
        }) as Map)['accepted'],
        isTrue,
      );
      expect((await client.store.load()).attempts.length, 1);
      js('globalThis.restoreStorage();');
      final other = device(screen: 'other');
      await other.invoke('auth.logout', {});
      expect((await other.store.load()).authGeneration, 2);
      expect((await other.store.load()).attempts.length, 0);
      expect(
        (await client.store.load()).attempts.length,
        0,
        reason: 'A completed logout must invalidate memory from before it',
      );
    });

    test('recovery 3 generation collision cannot resurrect', () async {
      final client = device();
      await client.store.commit(
        await client.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      blockStorage();
      await client.invoke('auth.signup', {
        'pending': true,
        'email': 'first@example.test',
      });
      expect((await client.store.load()).generation, 2);
      final pending = client.invoke('auth.signup', {
        'pending': true,
        'email': 'late@example.test',
        'hold': 'collision',
      });
      await arrived('collision');
      js('globalThis.restoreStorage();');
      await client.invoke('auth.logout', {});
      final observer = device();
      expect((await observer.store.load()).authGeneration, 2);
      expect((await observer.store.load()).attempts.isEmpty, isTrue);
      await control({'release': 'collision'});
      expect((await pending as Map)['accepted'], isTrue);
      final restored = await observer.store.load();
      expect([restored.attempts.length, restored.authGeneration], [0, 2]);
    });

    test('recovery 4 account change after recovery is persisted', () async {
      final actor = device(screen: 'actor');
      await actor.store.commit(
        await actor.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final pendingClient = device(screen: 'pending');
      await pendingClient.store.load();
      blockStorage();
      await actor.invoke('auth.signup', {
        'pending': true,
        'email': 'actor@example.test',
      });
      final pending = pendingClient.invoke('auth.signup', {
        'pending': true,
        'email': 'late@example.test',
        'hold': 'memory-account',
      });
      await arrived('memory-account');
      js('globalThis.restoreStorage();');
      await actor.invoke('auth.signin', {'account': 'b'});
      expect((await actor.store.load()).authGeneration, 2);
      final durableBefore = await device(screen: 'before-observer').store
          .load();
      await control({'release': 'memory-account'});
      final result = await pending as Map;
      expect(result['accepted'], isTrue);
      final restored = await device(screen: 'observer').store.load();
      final retained = restored.attempts.values.any(
        (a) => a.id == result['attempt'],
      );
      expect(
        retained,
        isFalse,
        reason: 'An account change after recovery must fence an older response from another object',
      );
      expect(durableBefore.authGeneration, 2);
    });
    test(
      'recovery 6 unchanged auth preserves peer attempt additions and removals',
      () async {
        for (final removed in [false, true]) {
          final app = 'rejoin.$removed';
          final actor = device(app: app);
          final peer = device(app: app, screen: 'peer');
          final now = DateTime.now().millisecondsSinceEpoch;
          DeviceAttempt attempt(String email) =>
              DeviceAttempt(web.window.crypto.randomUUID(), email, now);
          final old = attempt('old@example.test');
          final mine = attempt('mine@example.test');
          final theirs = attempt('peer@example.test');
          await actor.store.commit(
            await actor.store.load(),
            DeviceState(generation: 1, attempts: {'old': old}),
          );
          final base = await actor.store.load();
          blockStorage();
          await actor.store.commitAfterSuccess(
            base,
            DeviceState(generation: 2, attempts: {'old': old, 'mine': mine}),
          );
          js('globalThis.restoreStorage();');
          await peer.store.commit(
            await peer.store.load(),
            DeviceState(
              generation: 2,
              attempts: {if (!removed) 'old': old, 'peer': theirs},
            ),
          );
          expect((await peer.store.load()).authGeneration, base.authGeneration);
          final recovered = await actor.store.load();
          expect(
            recovered.attempts.keys,
            unorderedEquals([if (!removed) 'old', 'mine', 'peer']),
          );
          expect(
            (await device(app: app).store.load()).attempts.keys,
            unorderedEquals(recovered.attempts.keys),
          );
          expect(actor.store.transientState, isNull);
        }
      },
    );

    test(
      'CAS conflict recomputes peer changes and stops at auth boundary',
      () async {
        for (final variant in ['peer', 'boundary', 'raw']) {
          final authChanged = variant == 'boundary';
          final app = 'conflict.$variant';
          final actor = device(app: app);
          final peer = device(app: app);
          final base = await actor.store.load();
          final now = DateTime.now().millisecondsSinceEpoch;
          final mine = DeviceAttempt(
            web.window.crypto.randomUUID(),
            'mine@example.test',
            now,
          );
          final theirs = DeviceAttempt(
            web.window.crypto.randomUUID(),
            'peer@example.test',
            now,
          );
          blockStorage();
          await actor.store.commitAfterSuccess(
            base,
            DeviceState(generation: 1, attempts: {'mine': mine}),
          );
          js('globalThis.restoreStorage();');
          final key = actor.store.coordinationKey;
          final replacement = jsonEncode(
            peer.store.bundle(
              DeviceState(
                generation: 1,
                authGeneration: authChanged ? 1 : 0,
                attempts: {'peer': theirs},
              ),
            ),
          );
          final changedRaw = ' ${jsonEncode(peer.store.bundle(DeviceState()))}';
          js('''
          globalThis.rejoinGet = Storage.prototype.getItem;
          globalThis.rejoinReads = 0;
          Storage.prototype.getItem = function(key) {
            if (key === ${jsonEncode(key)}) {
              const count = ++globalThis.rejoinReads;
              if (count === 2)
                this.setItem(key, ${jsonEncode(variant == 'raw' ? changedRaw : replacement)});
              if (${variant == 'raw'} && count === 3)
                this.setItem(key, ${jsonEncode(replacement)});
            }
            return globalThis.rejoinGet.call(this, key);
          };
        ''');
          try {
            final recovered = await actor.store.load();
            expect(
              recovered.attempts.keys,
              unorderedEquals([if (!authChanged) 'mine', 'peer']),
            );
            expect(recovered.authGeneration, authChanged ? 1 : 0);
            expect(actor.store.transientState, isNull);
          } finally {
            js('Storage.prototype.getItem = globalThis.rejoinGet;');
          }
        }
      },
    );

    test(
      'explicit signin retains unsaved signup and peer screen on web',
      () async {
        final actor = device();
        final peer = device(screen: 'peer');
        await actor.store.load();
        blockStorage();
        final own = await actor.invoke('auth.signup', {
          'pending': true,
          'email': 'signup@example.test',
        }) as Map;
        js('globalThis.restoreStorage();');
        final other = await peer.invoke('auth.signup', {
          'pending': true,
          'email': 'peer@example.test',
        }) as Map;
        final reply = actor.invoke('auth.signin', {
          'email': 'own@example.test',
          'hold': 'explicit-preserve',
        });
        await arrived('explicit-preserve');
        final started = await device().store.load();
        await control({'release': 'explicit-preserve'});
        await reply;
        final restored = await device().store.load();
        for (final state in [started, restored]) {
          expect(state.attempts['signup']?.id == own['attempt'], isTrue);
          expect(state.attempts['peer']?.id == other['attempt'], isTrue);
        }
        expect(started.authGeneration, 0);
        expect(restored.authGeneration, 1);
        final sent = await device().invoke('auth.send_verification_email', {
          'expectedEmail': 'signup@example.test',
        }) as Map;
        expect(sent['matches'], isTrue);
        final calls = (await control())['calls'] as Map;
        expect(calls['auth.signup'], 2);
        expect(calls['auth.signin'], 1);
      },
    );

    test('merge bounds keep durable attempts without eviction', () async {
      final actor = device();
      final peer = device();
      final now = DateTime.now().millisecondsSinceEpoch;
      DeviceAttempt attempt() => DeviceAttempt(
        web.window.crypto.randomUUID(),
        'bounds@example.test',
        now,
      );
      final base = await actor.store.load();
      blockStorage();
      await actor.store.commitAfterSuccess(
        base,
        DeviceState(generation: 1, attempts: {'mine': attempt()}),
      );
      js('globalThis.restoreStorage();');
      await peer.store.commit(
        await peer.store.load(),
        DeviceState(
          generation: 1,
          attempts: {for (var i = 0; i < 3; i++) 'peer$i': attempt()},
        ),
      );
      final committed = jsonEncode((await peer.store.load()).toJson());
      expect((await actor.store.load()).attempts.containsKey('mine'), isTrue);
      expect(actor.store.transientState != null, isTrue);
      expect(
        jsonEncode((await peer.store.load()).toJson()) == committed,
        isTrue,
      );
    });
  });

  test(
    'storage recovery before signup reply retains the accepted attempt',
    () async {
      final client = device();
      await client.store.commit(
        await client.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new DOMException('Blocked', 'SecurityError'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
      addTearDown(() => js('globalThis.restoreStorage();'));
      final pending = client.invoke('auth.signup', {
        'pending': true,
        'email': 'recovery@example.test',
        'hold': 'recovery',
      });
      await arrived('recovery');
      js('globalThis.restoreStorage();');
      await control({'release': 'recovery'});
      expect((await pending as Map)['accepted'], isTrue);
      expect((await client.store.load()).attempts.length, 1);
      await client.invoke('auth.send_verification_email', {});
    },
  );

  test(
    'recovery without an observed base discards an ambiguous attempt',
    () async {
      final writer = device();
      await writer.store.commit(
        await writer.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final client = device();
      js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new DOMException('Blocked', 'SecurityError'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
      addTearDown(() => js('globalThis.restoreStorage();'));
      expect(
        (await client.invoke('auth.signup', {
          'pending': true,
          'email': 'unknown@example.test',
        }) as Map)['accepted'],
        isTrue,
      );
      expect((await client.store.load()).attempts.length, 1);
      js('globalThis.restoreStorage();');
      expect(
        (await client.store.load()).attempts.isEmpty,
        isTrue,
        reason:
            'No observation can distinguish an old base from a later logout',
      );
      expect((await device().store.load()).attempts.isEmpty, isTrue);
    },
  );

  test('account change before recovery fences a late signup', () async {
    final client = device();
    await client.store.commit(
      await client.store.load(),
      DeviceState(generation: 1, authGeneration: 1),
    );
    js("""
      const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', { configurable: true,
        get() { throw new DOMException('Blocked', 'SecurityError'); } });
      globalThis.restoreStorage = () => Object.defineProperty(window, 'localStorage', descriptor);
    """);
    addTearDown(() => js('globalThis.restoreStorage();'));
    final pending = client.invoke('auth.signup', {
      'pending': true,
      'email': 'old@example.test',
      'hold': 'account-recovery',
    });
    await arrived('account-recovery');
    js('globalThis.restoreStorage();');
    await client.invoke('auth.signin', {'account': 'b'});
    expect((await client.store.load()).authGeneration, 2);
    await control({'release': 'account-recovery'});
    expect((await pending as Map)['accepted'], isTrue);
    expect((await device().store.load()).attempts.isEmpty, isTrue);
  });

  test(
    'browser read leaves a displaced memory account unauthenticated',
    () async {
      final client = device();
      await client.store.commit(
        await client.store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      blockStorage();
      await client.invoke('auth.signin', {'account': 'a'});
      final pending = client.invoke('auth.signup', {
        'pending': true,
        'email': 'before-read@example.test',
        'hold': 'read-fence',
      });
      await arrived('read-fence');
      js('restoreStorage();');
      final other = device(screen: 'switch');
      await other.invoke('auth.signin', {'account': 'b'});
      final durable = await other.store.load();
      expect(await client.store.read(), isNull);
      expect(client.store.blocked, isFalse);
      expect((await client.store.load()).toJson(), durable.toJson());
      await control({'release': 'read-fence'});
      expect((await pending as Map)['accepted'], isTrue);
      expect((await device().store.load()).attempts.isEmpty, isTrue);
      await client.invoke('auth.signup', {
        'pending': true,
        'email': 'after-read@example.test',
      });
      expect((await device().store.load()).attempts.length, 1);
    },
  );

  test('recovery orderings preserve successful attempts and authentication fences', () async {
    var row = 0;
    for (final (observed, baseAuth) in [
      (false, 0),
      (false, 1),
      (true, 0),
      (true, 1),
    ]) {
      for (final memoryAccount in [false, true]) {
        for (final memoryWrites in [0, 1, 2, 3]) {
          for (final recoveredRead in [false, true]) {
            for (final boundary in [
              'attempt elsewhere',
              'none',
              'logout here',
              'logout elsewhere',
              'account here',
              'account elsewhere',
              'logout recovered actor',
              'account recovered actor',
            ]) {
              final app = 'table-${row++}';
              final writer = device(app: app);
              await writer.store.commit(
                await writer.store.load(),
                DeviceState(generation: 1, authGeneration: baseAuth),
              );
              final client = observed ? writer : device(app: app);
              final memoryActor = boundary.endsWith('recovered actor')
                  ? device(app: app, screen: 'switch')
                  : null;
              await memoryActor?.store.load();
              blockStorage();
              for (var i = 0; i < memoryWrites; i++) {
                await client.invoke('auth.signup', {
                  'pending': true,
                  'email': 'person@example.test',
                });
              }
              if (memoryAccount) {
                await client.invoke('auth.signin', {'account': 'a'});
              }
              await memoryActor?.invoke('auth.signup', {
                'pending': true,
                'email': 'actor@example.test',
              });
              final pending = client
                  .invoke('auth.signup', {
                    'pending': true,
                    'email': 'person@example.test',
                    'hold': app,
                  })
                  .then<Object?>(
                    (value) => value,
                    onError: (Object error) => error,
                  );
              await arrived(app);
              js('restoreStorage();');
              var fenced = false;
              Object? peerAttempt;
              try {
                if (recoveredRead) await client.store.load();
                final actor =
                    memoryActor ??
                    (boundary.endsWith('elsewhere')
                        ? device(app: app, screen: 'switch')
                        : client);
                if (boundary == 'attempt elsewhere') {
                  peerAttempt = (await actor.invoke('auth.signup', {
                    'pending': true,
                    'email': 'peer@example.test',
                  }) as Map)['attempt'];
                } else if (boundary.startsWith('logout')) {
                  await actor.invoke('auth.logout', {});
                } else if (boundary.startsWith('account')) {
                  await actor.invoke('auth.signin', {'account': 'b'});
                }
              } on ClientError catch (error) {
                expect(error.code, 'failed_precondition');
                fenced = true;
              }
              final durable = await device(app: app).store.load();
              if (boundary != 'none' &&
                  boundary != 'attempt elsewhere' &&
                  !fenced) {
                expect(durable.authGeneration, greaterThan(baseAuth));
              }
              await control({'release': app});
              final result = await pending;
              DeviceState? current;
              try {
                current = await client.store.load();
              } on ClientError catch (error) {
                expect(error.code, 'failed_precondition');
                fenced = true;
              }
              final persisted = await device(app: app).store.load();
              final reason =
                  '$observed/$baseAuth/$memoryAccount/$memoryWrites/$recoveredRead/$boundary';
              final shouldFence =
                  memoryAccount &&
                  (!observed ||
                      (!recoveredRead &&
                          ((boundary.endsWith('elsewhere') &&
                                  boundary != 'attempt elsewhere') ||
                              boundary.endsWith('recovered actor'))));
              expect(fenced, shouldFence, reason: reason);
              if (shouldFence) {
                expect(client.store.blocked, isTrue, reason: reason);
                expect(persisted.toJson(), durable.toJson(), reason: reason);
                if (result is ClientError) {
                  expect(result.code, 'failed_precondition');
                } else {
                  expect((result as Map)['accepted'], isTrue);
                  expect(
                    persisted.attempts.values.any(
                      (a) => a.id == result['attempt'],
                    ),
                    isFalse,
                  );
                }
              } else {
                expect((result as Map)['accepted'], isTrue);
                expect(
                  current!.attempts.values.any(
                    (a) => a.id == result['attempt'],
                  ),
                  observed &&
                      (boundary == 'none' || boundary == 'attempt elsewhere'),
                  reason: reason,
                );
                if (boundary.startsWith('logout')) {
                  expect(current.attempts, isEmpty, reason: reason);
                  expect(persisted.attempts, isEmpty, reason: reason);
                }
              }
              if (peerAttempt != null) {
                expect(
                  persisted.attempts['switch']?.id == peerAttempt,
                  isTrue,
                  reason: reason,
                );
              }
              expect(
                persisted.authGeneration,
                greaterThanOrEqualTo(durable.authGeneration),
                reason: reason,
              );
            }
          }
        }
      }
    }
    expect(row, 512);
  });

  test(
    'persistent commits reject mismatched or decreasing auth generations',
    () async {
      final store = device().store;
      await store.commit(
        await store.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final current = await store.load();
      expect(
        await store.commit(
          DeviceState(generation: 1),
          DeviceState(generation: 2),
        ),
        isFalse,
      );
      await expectLater(
        store.commit(current, DeviceState(generation: 2)),
        throwsA(local('internal')),
      );
      expect((await store.load()).toJson(), current.toJson());
    },
  );

  test('stored values contain no credentials or request secrets and 401 is never resent', () async {
    final client = device();
    final secret = web.window.crypto.randomUUID();
    await client.invoke('auth.signup', {
      'pending': true,
      'email': 'scan@example.test',
      'password': secret,
    });
    await client.invoke('auth.verify_email', {'code': '123456'});
    await expectLater(
      client.invoke('thing.reject', {'status': 401}),
      throwsA(remote('invalid_token')),
    );
    expect((await BrowserAuth(client).session()).id, 'a');
    var count = 0;
    var clean = true;
    final storage = web.window.localStorage;
    for (var i = 0; i < storage.length; i++) {
      final key = storage.key(i)!;
      if (!key.startsWith(_prefix)) continue;
      count++;
      final value = storage.getItem(key)!;
      clean =
          clean &&
          !RegExp(
            r'access_token|refresh_token|password|cookie|__Host-|[A-Za-z0-9_-]{43}',
          ).hasMatch(value) &&
          !value.contains(secret) &&
          !value.contains('123456');
    }
    expect(count, 1);
    expect(clean, isTrue);
    expect((await client.store.load()).session == null, isTrue);
    expect((await control())['calls'], {
      'auth.signup': 1,
      'auth.verify_email': 1,
      'auth.session': 2,
      'thing.reject': 1,
    });
  });
}
