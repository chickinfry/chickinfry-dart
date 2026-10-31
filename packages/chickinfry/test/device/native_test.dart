import 'dart:async';
import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/device/bridge.dart';
import 'package:chickinfry/src/device/native.dart';
import 'package:chickinfry/src/device/store.dart';
import 'package:chickinfry/src/device/files.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final unsupportedPosix = Platform.isMacOS || Platform.isLinux
      ? false
      : 'Requires the macOS or Linux POSIX file device.';
  for (final outcome in ['rejected', 'same-session']) {
    test(
      'business read recovery observes peer before explicit signin $outcome',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final first = credentials();
        final second = credentials();
        final lateSession = credentials();
        final arrived = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var signins = 0;
        var signups = 0;
        var business = 0;
        var cleanups = 0;
        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth.signin') {
            signins++;
            if (signins <= 2 || outcome == 'same-session') {
              request.response.write(
                jsonEncode((signins == 1 ? first : second).toJson()),
              );
            } else {
              request.response.statusCode = 401;
              request.response.write(
                jsonEncode({'error': 'invalid_credentials'}),
              );
            }
          } else if (request.uri.path == '/auth.signup') {
            signups++;
            arrived.complete();
            await release.future;
            request.response.write(jsonEncode(lateSession.toJson()));
          } else if (request.uri.path == '/catalog.list') {
            business++;
            request.response.statusCode = 401;
            request.response.write(jsonEncode({'error': 'invalid_token'}));
          } else {
            cleanups++;
            request.response.write(jsonEncode({'accepted': true}));
          }
          await request.response.close();
        });
        final peerStore = device(root, origin, screen: 'peer8');
        final peer = DeviceTransport(peerStore);
        addTearDown(peer.close);
        await peer.invoke('auth.signin', {'email': 'first@example.test'});
        final file = File('${peerStore.directory}/auth.json');
        final fixture =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        (fixture['auth'] as Map<String, Object?>)['attempts'] = {
          'old': DeviceAttempt(
            randomId(),
            'expired@example.test',
            DateTime.now()
                .subtract(const Duration(hours: 25))
                .millisecondsSinceEpoch,
          ).toJson(),
        };
        await file.writeAsString(jsonEncode(fixture));
        final store = NativeDeviceStore(
          scope(origin, screen: 'actor8'),
          directory: root,
          files: FailWrite(1),
        );
        final actor = DeviceTransport(store);
        addTearDown(actor.close);
        await actor.invoke('auth.send_verification_email', {
          'email': 'first@example.test',
        });
        expect(store.transientState?.session == first, isTrue);
        final anchorGeneration = store.transientBaseAuthGeneration!;
        await peer.invoke('auth.signin', {'email': 'second@example.test'});
        final pending = peer.invoke('auth.signup', {
          'email': 'late@example.test',
        });
        await arrived.future;
        final marked = await peerStore.load();
        expect(marked.authTransitionUnknown, isTrue);
        expect(marked.authGeneration > anchorGeneration, isTrue);
        await expectLater(
          actor.invoke('catalog.list', {}),
          throwsA(
            isA<OperationError>().having(
              (e) => e.code,
              'code',
              'invalid_token',
            ),
          ),
        );
        expect(store.transientState, isNull);
        final observed = store.observedPeerAuth;
        if (outcome == 'rejected') {
          await expectLater(
            actor.invoke('auth.signin', {'email': 'own@example.test'}),
            throwsA(
              isA<OperationError>().having(
                (e) => e.code,
                'code',
                'invalid_credentials',
              ),
            ),
          );
        } else {
          await actor.invoke('auth.signin', {'email': 'second@example.test'});
          expect(await device(root, origin).read() == second, isTrue);
        }
        final afterOwn = await peerStore.load();
        release.complete();
        await pending;
        final after = await device(root, origin).load();
        final advanced = afterOwn.authGeneration > marked.authGeneration;
        final lateInstalled = after.session == lateSession;
        expect(signins, 3);
        expect(signups, 1);
        expect(business, 1);
        expect(cleanups, 1);
        expect(
          lateInstalled,
          isFalse,
          reason: 'Explicit authentication must invalidate peer requests observed by a business read.',
        );
        expect(observed && advanced, isTrue);
      },
      skip: unsupportedPosix,
    );
  }
  for (final outcome in ['rejected', 'same-session']) {
    test(
      'verified recovery observes peer before explicit signin $outcome',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final first = credentials();
        final peerIssued = credentials();
        final peerArrived = Completer<void>();
        final peerRelease = Completer<void>();
        addTearDown(() {
          if (!peerRelease.isCompleted) peerRelease.complete();
        });
        var signins = 0;
        var signups = 0;
        var resend = 0;
        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth.signin') {
            signins++;
            if (signins == 1) {
              request.response.write(jsonEncode(first.toJson()));
            } else if (outcome == 'same-session') {
              request.response.write(jsonEncode(first.toJson()));
            } else {
              request.response.statusCode = 401;
              request.response.write(
                jsonEncode({'error': 'invalid_credentials'}),
              );
            }
          } else if (request.uri.path == '/auth.signup') {
            signups++;
            peerArrived.complete();
            await peerRelease.future;
            request.response.write(jsonEncode(peerIssued.toJson()));
          } else {
            resend++;
            request.response.write(jsonEncode({'accepted': true}));
          }
          await request.response.close();
        });
        final store = NativeDeviceStore(
          scope(origin, screen: 'actor7'),
          directory: root,
          files: FailDirectorySyncOnce(),
        );
        final actor = DeviceTransport(store);
        final peerStore = device(root, origin, screen: 'peer7');
        final peer = DeviceTransport(peerStore);
        addTearDown(actor.close);
        addTearDown(peer.close);
        await actor.invoke('auth.signin', {'email': 'a@example.test'});
        expect(store.transientState != null, isTrue);
        expect(store.consumedAttemptEmails.values.single.settled, isTrue);
        final pending = peer.invoke('auth.signup', {
          'email': 'peer@example.test',
        });
        await peerArrived.future;
        final marked = await peerStore.load();
        expect(marked.authTransitionUnknown, isTrue);
        await actor.invoke('auth.send_verification_email', {
          'email': 'a@example.test',
        });
        final observed = store.observedPeerAuth;
        expect(store.transientState, isNull);
        expect(await store.read() == null, isTrue);
        if (outcome == 'rejected') {
          await expectLater(
            actor.invoke('auth.signin', {'email': 'own@example.test'}),
            throwsA(
              isA<OperationError>().having(
                (e) => e.code,
                'code',
                'invalid_credentials',
              ),
            ),
          );
        } else {
          await actor.invoke('auth.signin', {'email': 'a@example.test'});
          expect(await device(root, origin).read() == first, isTrue);
        }
        final rejected = await peerStore.load();
        peerRelease.complete();
        await pending;
        final after = await device(root, origin).load();
        final lateInstalled = after.session == peerIssued;
        final advanced = rejected.authGeneration > marked.authGeneration;
        final cleared = rejected.session == null;

        expect(signins, 2);
        expect(signups, 1);
        expect(resend, 1);
        expect(
          lateInstalled,
          isFalse,
          reason: 'Explicit authentication must invalidate peer requests observed during recovery.',
        );
        expect(
          observed && advanced && (outcome == 'same-session' || cleared),
          isTrue,
        );
      },
      skip: unsupportedPosix,
    );
  }

  test(
    'verified signin write preserves peer pending without losing own boundary',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final issued = credentials();
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var signins = 0;
      var signups = 0;
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signin') {
          signins++;
          request.response.write(jsonEncode(issued.toJson()));
        } else if (request.uri.path == '/auth.send_verification_email') {
          request.response.write(jsonEncode({'accepted': true}));
        } else {
          signups++;
          arrived.complete();
          await release.future;
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': randomId()}),
          );
        }
        await request.response.close();
      });
      final files = FailDirectorySyncOnce();
      final store = NativeDeviceStore(
        scope(origin, screen: 'actor6'),
        directory: root,
        files: files,
      );
      final actor = DeviceTransport(store);
      final peerStore = device(root, origin, screen: 'peer6');
      final peer = DeviceTransport(peerStore);
      addTearDown(actor.close);
      addTearDown(peer.close);
      final before = await store.load();
      await actor.invoke('auth.signin', {'email': 'a@example.test'});
      expect(store.transientState != null, isTrue);
      expect(store.consumedAttemptEmails.values.single.settled, isTrue);
      final persisted = await peerStore.load();
      expect(store.recoveryWasApplied(persisted), isTrue);
      expect(persisted.authGeneration, before.authGeneration + 1);
      final pending = peer.invoke('auth.signup', {
        'email': 'peer@example.test',
      });
      await arrived.future;
      final marked = await peerStore.load();
      expect(marked.authTransitionUnknown, isTrue);
      expect(marked.authGeneration, persisted.authGeneration);
      String? code;
      try {
        await actor.invoke('auth.send_verification_email', {
          'email': 'a@example.test',
        });
      } on ClientException catch (error) {
        code = error.code;
      }
      final after = await peerStore.load();
      final retained =
          after.authTransitionId == marked.authTransitionId &&
          after.authTransitionUnknown;

      release.complete();
      await pending;
      expect(signins, 1);
      expect(signups, 1);
      expect(retained, isTrue);
      String? laterCode;
      try {
        await actor.invoke('auth.send_verification_email', {
          'email': 'a@example.test',
        });
      } on ClientException catch (error) {
        laterCode = error.code;
      }

      expect(
        code,
        isNull,
        reason: 'Verified own writes must preserve peer marks in the same auth generation.',
      );
      expect(laterCode, isNull);
      expect(store.blocked, isFalse);
      expect(await store.read() == issued, isTrue);
    },
    skip: unsupportedPosix,
  );
  for (final outcome in [
    'before send',
    'mark write fails',
    'definite failure',
    'saved success',
    'unsaved success',
    'unknown response',
    'first login',
  ]) {
    test('auth transition: $outcome', () async {
      for (final operation in [
        'auth.signin',
        'auth.verify_email',
        'auth.signin_with_code',
        'auth.identity',
        'auth.signup',
      ]) {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final original = credentials();
        final issued = credentials();
        final persistent = device(root, origin);
        if (outcome != 'first login') await persistent.write(original);
        if (outcome == 'saved success') {
          final current = await persistent.load();
          final now = DateTime.now().millisecondsSinceEpoch;
          await persistent.commit(
            current,
            DeviceState.fromJson({
              ...current.toJson(),
              'generation': current.generation + 1,
              'attempts': {
                'matching': DeviceAttempt(
                  randomId(),
                  'user@example.test',
                  now,
                ).toJson(),
                'other': DeviceAttempt(
                  randomId(),
                  'other@example.test',
                  now,
                ).toJson(),
              },
            }),
          );
        }
        final initial = await persistent.load();
        Future<bool> marked() async {
          final file = File('${persistent.directory}/auth.json');
          if (!await file.exists()) return false;
          final bundle =
              jsonDecode(await file.readAsString()) as Map<String, Object?>;
          return (bundle['auth']
                  as Map<String, Object?>)['auth_transition_unknown'] ==
              true;
        }

        final failureFiles = outcome == 'unsaved success' ? FailWrite(2) : null;
        final store = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: outcome == 'mark write fails'
              ? (operation == 'auth.signin' ? FullFiles() : UnavailableFiles())
              : failureFiles,
        );
        final client = DeviceTransport(store);
        addTearDown(client.close);
        var retrying = false;
        var ownerAuthenticated = false;
        var sends = 0;
        var markedBeforeSend = false;
        server.listen((request) async {
          await request.drain<void>();
          if (request.uri.path == '/private.check') {
            ownerAuthenticated =
                request.headers.value('authorization') ==
                'Bearer ${original.accessToken}';
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(<String, Object?>{}));
            await request.response.close();
            return;
          }
          sends++;
          markedBeforeSend = await marked();
          if (outcome == 'before send' && markedBeforeSend) {
            expect(await store.read() == original, isTrue);
            expect(
              await store.waitForSession(const Duration(milliseconds: 20)) ==
                  original,
              isTrue,
            );
            expect(await persistent.read() == null, isTrue);
            expect(
              await persistent.waitForSession(
                    const Duration(milliseconds: 20),
                  ) ==
                  null,
              isTrue,
            );
            expect((await persistent.load()).session == original, isTrue);
            await client.invoke('private.check', {});
            expect(ownerAuthenticated, isTrue);
          }
          if (outcome == 'unknown response' && !retrying) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
            return;
          }
          request.response.headers.contentType = ContentType.json;
          if (outcome == 'definite failure') {
            request.response.statusCode = 401;
            request.response.write(
              jsonEncode({'error': 'invalid_credentials'}),
            );
          } else {
            request.response.write(jsonEncode(issued.toJson()));
          }
          await request.response.close();
        });
        final response = client.invoke(operation, {
          'email': 'user@example.test',
        });
        if (outcome == 'mark write fails' ||
            outcome == 'definite failure' ||
            outcome == 'unknown response') {
          final code = switch (outcome) {
            'mark write fails' => 'device_storage_unavailable',
            'definite failure' => 'invalid_credentials',
            _ => 'network_error',
          };
          await expectLater(
            response,
            throwsA(
              predicate<Object>(
                (error) =>
                    (error is ClientException && error.code == code) ||
                    (error is OperationError && error.code == code),
              ),
            ),
          );
        } else {
          expect(SessionCredentials.fromJson(await response) == issued, isTrue);
        }
        if (outcome == 'mark write fails') {
          expect(sends == 0 && !await marked(), isTrue);
          expect(await persistent.read() == original, isTrue);
          continue;
        }
        expect(sends, 1);
        if (outcome == 'before send') expect(markedBeforeSend, isTrue);
        if (outcome == 'first login') expect(markedBeforeSend, isFalse);
        if (outcome == 'definite failure') {
          expect(
            !await marked() && await persistent.read() == original,
            isTrue,
          );
        } else if (outcome == 'unsaved success' ||
            outcome == 'unknown response') {
          expect(await marked(), isTrue);
          if (outcome == 'unsaved success') {
            failureFiles!.readUnavailable = true;
            expect(await store.read() == issued, isTrue);
            await expectLater(
              client.invoke(operation, {}),
              throwsA(
                isA<ClientException>().having(
                  (error) => error.code,
                  'code',
                  'device_storage_unavailable',
                ),
              ),
            );
            expect(sends == 1 && await store.read() == issued, isTrue);
          } else {
            final unavailable = NativeDeviceStore(
              scope(origin),
              directory: root,
              files: UnavailableFiles(),
            );
            expect(await unavailable.read() == null, isTrue);
            expect(
              await unavailable.waitForSession(
                    const Duration(milliseconds: 20),
                  ) ==
                  null,
              isTrue,
            );
            expect(await marked(), isTrue);
          }
          expect(await child('unresolved', root, origin), 0);
          final restarted = device(root, origin);
          expect(await restarted.read() == null, isTrue);
          expect(
            (await restarted.load()).toJson()['auth_transition_unknown'],
            isTrue,
          );
          expect((await restarted.load()).session == original, isTrue);
          if (failureFiles != null) {
            failureFiles.readUnavailable = false;
            expect(await store.read() == issued, isTrue);
            expect(await persistent.read() == issued, isTrue);
            expect(sends, 1);
          }
          if (outcome == 'unknown response') {
            retrying = true;
            final retryFiles = FailWrite(2);
            final retryStore = NativeDeviceStore(
              scope(origin),
              directory: root,
              files: retryFiles,
            );
            final retryClient = DeviceTransport(retryStore);
            addTearDown(retryClient.close);
            expect(
              SessionCredentials.fromJson(
                    await retryClient.invoke(operation, {}),
                  ) ==
                  issued,
              isTrue,
            );
            retryFiles.readUnavailable = true;
            final fenced = await persistent.load();
            expect(
              fenced.session == null &&
                  fenced.authGeneration == initial.authGeneration + 1 &&
                  fenced.toJson()['auth_transition_unknown'] == true,
              isTrue,
            );
            expect(
              await retryStore.read() == issued &&
                  await persistent.read() == null &&
                  sends == 2,
              isTrue,
            );
            expect(await child('unresolved', root, origin), 0);
            retryFiles.readUnavailable = false;
            expect(await retryStore.read() == issued, isTrue);
            expect(await persistent.read() == issued, isTrue);
            expect(sends, 2);
          }
        } else {
          final state = await device(root, origin).load();
          expect(
            !await marked() &&
                state.session == issued &&
                state.authGeneration == initial.authGeneration + 1 &&
                (outcome != 'saved success' ||
                    (state.attempts.length == 1 &&
                        state.attempts.containsKey('other'))),
            isTrue,
          );
        }
      }
    }, skip: unsupportedPosix);
  }

  test(
    'auth transition: malformed success never restores the previous session',
    () async {
      for (final operation in [
        'auth.signin',
        'auth.signin_with_code',
        'auth.verify_email',
        'auth.identity',
        'auth.signup',
      ]) {
        for (final malformed in [false, true]) {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://${server.address.address}:${server.port}';
          final original = credentials();
          final persistent = device(root, origin);
          await persistent.write(original);
          var sends = 0;
          server.listen((request) async {
            await request.drain<void>();
            sends++;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(
                malformed
                    ? <String, Object?>{'access_token': false}
                    : <String, Object?>{},
              ),
            );
            await request.response.close();
          });
          final client = DeviceTransport(device(root, origin));
          addTearDown(client.close);
          await expectLater(
            client.invoke(operation, {}),
            throwsA(
              isA<ClientException>().having(
                (error) => error.code,
                'code',
                'invalid_response',
              ),
            ),
          );
          expect(sends, 1);
          expect(
            await client.store.read() == null &&
                await persistent.read() == null,
            isTrue,
          );
          final state = await persistent.load();
          expect(
            state.session == original &&
                state.toJson()['auth_transition_unknown'] == true,
            isTrue,
          );
          expect(await child('unresolved', root, origin), 0);
        }
      }
    },
    skip: unsupportedPosix,
  );

  for (final change in [
    'signed out',
    'new account',
    'read unavailable',
    'bundle only',
  ]) {
    test('E1 session follows disk auth generation: $change', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://${server.address.address}:${server.port}';
      final original = credentials();
      final issued = credentials();
      final replacement = credentials();
      final external = device(root, origin);
      await external.write(original);
      final accepted = await external.load();
      var protected = 0;
      var refreshes = 0;
      var usedIssued = false;
      var usedReplacement = false;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signin') {
          request.response.write(jsonEncode(issued.toJson()));
        } else if (request.uri.path == '/auth.refresh') {
          refreshes++;
          request.response.statusCode = 401;
          request.response.write(jsonEncode({'error': 'unauthenticated'}));
        } else {
          protected++;
          final bearer = request.headers.value('authorization');
          usedIssued = bearer == 'Bearer ${issued.accessToken}';
          usedReplacement = bearer == 'Bearer ${replacement.accessToken}';
          final expected = change == 'new account'
              ? usedReplacement
              : usedIssued;
          if (change == 'signed out' || !expected) {
            request.response.statusCode = 401;
            request.response.write(jsonEncode({'error': 'unauthenticated'}));
          } else {
            request.response.write(jsonEncode(<String, Object?>{}));
          }
        }
        await request.response.close();
      });
      final files = FailWrite(2);
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final client = DeviceTransport(store);
      addTearDown(client.close);
      expect(
        SessionCredentials.fromJson(await client.invoke('auth.signin', {})) ==
            issued,
        isTrue,
      );
      files.readUnavailable = true;
      expect(
        (await store.load()).authGeneration == accepted.authGeneration + 1,
        isTrue,
      );
      files.readUnavailable = false;
      switch (change) {
        case 'signed out':
          await external.clear(await external.load());
        case 'new account':
          await external.write(replacement);
        case 'read unavailable':
          files.readUnavailable = true;
        case 'bundle only':
          final state = await external.load();
          await external.commit(
            state,
            DeviceState(
              generation: state.generation + 1,
              authGeneration: state.authGeneration,
              session: state.session,
              refreshSent: state.refreshSent,
              refreshId: state.refreshId,
              authTransitionUnknown: state.authTransitionUnknown,
              authTransitionId: state.authTransitionId,
              attempts: {
                ...state.attempts,
                'other': DeviceAttempt(
                  randomId(),
                  '${randomId()}@example.test',
                  DateTime.now().millisecondsSinceEpoch,
                ),
              },
            ),
          );
      }
      if (change == 'signed out' || change == 'new account') {
        await expectLater(
          client.invoke('private.check', {}),
          throwsA(
            isA<OperationError>().having(
              (error) => error.code,
              'code',
              'unauthenticated',
            ),
          ),
        );
        expect(
          !usedIssued && !usedReplacement && store.transientState == null,
          isTrue,
        );
        if (change == 'new account') {
          await client.invoke('private.check', {});
          expect(usedReplacement && !usedIssued, isTrue);
        } else {
          expect(await store.read() == null, isTrue);
        }
      } else {
        await client.invoke('private.check', {});
        expect(usedIssued && await store.read() == issued, isTrue);
      }
      expect(
        protected == (change == 'new account' ? 2 : 1) && refreshes == 0,
        isTrue,
      );
    }, skip: unsupportedPosix);
  }

  for (final earlier in [
    'rejection',
    'unsaved success',
    'unknown response',
    'corrupt success',
  ]) {
    test(
      'auth transition: owned $earlier preserves another unresolved call',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://${server.address.address}:${server.port}';
        final original = credentials();
        final issued = credentials();
        final persistent = device(root, origin);
        await persistent.write(original);
        final firstRequest = Completer<HttpRequest>();
        final secondRequest = Completer<HttpRequest>();
        var sends = 0;
        server.listen((request) async {
          await request.drain<void>();
          sends++;
          (sends == 1 ? firstRequest : secondRequest).complete(request);
        });
        final shared = earlier == 'rejection';
        final firstFiles = shared ? FailWrite(3) : null;
        final secondFiles = shared ? firstFiles! : FailWrite(2);
        var unsaved = false;
        final firstStore = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: firstFiles,
        );
        final first = DeviceTransport(firstStore);
        final secondStore = shared
            ? firstStore
            : NativeDeviceStore(
                scope(origin),
                directory: root,
                files: secondFiles,
              );
        final second = DeviceTransport(secondStore);
        addTearDown(first.close);
        addTearDown(second.close);
        final email = '${randomId()}@example.test';
        final rejected = expectLater(
          first.invoke('auth.signin', {'email': email}),
          throwsA(
            isA<OperationError>().having(
              (error) => error.code,
              'code',
              'invalid_credentials',
            ),
          ),
        );
        final oldRequest = await firstRequest.future;
        expect(await persistent.read() == null, isTrue);
        final successful = second.invoke('auth.signin', {'email': email});
        final settling =
            earlier == 'unknown response' || earlier == 'corrupt success'
            ? expectLater(
                successful,
                throwsA(
                  isA<ClientException>().having(
                    (error) => error.code,
                    'code',
                    earlier == 'corrupt success'
                        ? 'invalid_response'
                        : 'network_error',
                  ),
                ),
              )
            : successful.then((value) async {
                expect(SessionCredentials.fromJson(value) == issued, isTrue);
                secondFiles.readUnavailable = true;
                unsaved = true;
                expect(await secondStore.read() == issued, isTrue);
              });
        final newRequest = await secondRequest.future;
        final marked = await persistent.load();
        expect(
          marked.session == original &&
              marked.toJson()['auth_transition_unknown'] == true,
          isTrue,
        );
        Future<void> rejectFirst() async {
          oldRequest.response.headers.contentType = ContentType.json;
          oldRequest.response.statusCode = 401;
          oldRequest.response.write(
            jsonEncode({'error': 'invalid_credentials'}),
          );
          await oldRequest.response.close();
          await rejected;
        }

        Future<void> settleSecond() async {
          if (earlier == 'unknown response') {
            final socket = await newRequest.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
          } else {
            newRequest.response.headers.contentType = ContentType.json;
            newRequest.response.write(
              jsonEncode(
                earlier == 'corrupt success'
                    ? <String, Object?>{}
                    : issued.toJson(),
              ),
            );
            await newRequest.response.close();
          }
          await settling;
        }

        if (earlier == 'rejection') {
          await rejectFirst();
          expect(
            (await persistent.load()).toJson()['auth_transition_unknown'],
            isTrue,
          );
          await settleSecond();
        } else {
          await settleSecond();
          await rejectFirst();
        }
        expect(await persistent.read() == null && sends == 2, isTrue);
        final after = await persistent.load();
        expect(
          after.session == original &&
              after.toJson()['auth_transition_unknown'] == true,
          isTrue,
        );
        expect(await child('unresolved', root, origin), 0);
        if (unsaved) {
          secondFiles.readUnavailable = false;
          expect(await secondStore.read() == issued, isTrue);
          expect(await persistent.read() == issued, isTrue);
          expect(sends, 2);
        }
      },
      skip: unsupportedPosix,
    );
  }

  test(
    'real processes restore session and signup, verify and logout',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final issued = credentials();
      final verified = credentials();
      final attempt = randomId();
      var restored = false;
      var restoredSession = false;
      var revoked = false;
      server.listen((request) async {
        final input = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, Object?>;
        Object? output;
        switch (request.uri.path) {
          case '/auth.signin':
            output = issued.toJson();
          case '/auth.signup':
            output = {'accepted': true, 'attempt': attempt};
          case '/auth.verify_email':
            restored = input['attempt'] == attempt && input['email'] == null;
            output = verified.toJson();
          case '/example.read':
            restoredSession =
                request.headers.value('authorization') ==
                'Bearer ${issued.accessToken}';
            output = {'accepted': true};
          case '/auth.logout':
            revoked =
                request.headers.value('authorization') ==
                'Bearer ${verified.accessToken}';
            output = <String, Object?>{};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(output));
        await request.response.close();
      });
      for (final action in ['seed', 'verify', 'logout', 'empty']) {
        expect(await child(action, root, origin), 0, reason: action);
      }
      expect(restored && restoredSession && revoked, isTrue);
      final store = device(root, origin);
      final disk = await File('${store.directory}/auth.json').readAsString();
      expect(
        disk.contains(issued.accessToken) || disk.contains(attempt),
        isFalse,
      );
      expect(
        (await File('${store.directory}/auth.json').stat()).mode & 0x3f,
        0,
      );
    },
    skip: unsupportedPosix,
  );

  test(
    'two processes send exactly one refresh and both observe its result',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final original = credentials();
      final rotated = credentials(
        user: original.userId,
        session: original.sessionId,
      );
      await device(root, origin).write(original);
      final originals = <HttpRequest>[];
      var sends = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.refresh') {
          sends++;
          request.response.write(jsonEncode(rotated.toJson()));
        } else if (request.headers.value('authorization') ==
            'Bearer ${original.accessToken}') {
          originals.add(request);
          if (originals.length != 2) return;
          for (final rejected in originals) {
            rejected.response.statusCode = 401;
            rejected.response.write('{"error":"invalid_token"}');
            await rejected.response.close();
          }
          return;
        } else {
          request.response.write('{"accepted":true}');
        }
        await request.response.close();
      });
      final exits = await Future.wait([
        child('race', root, origin),
        child('race', root, origin),
      ]);
      expect(exits.every((code) => code == 0), isTrue);
      expect(sends, 1);
      expect(await device(root, origin).read() == rotated, isTrue);
      expect(await child('claim', root, origin), 0);
      expect(await child('blocked', root, origin), 0);
      final blocked = DeviceTransport(
        device(root, origin),
        timeout: const Duration(milliseconds: 60),
      );
      addTearDown(blocked.close);
      await expectLater(
        blocked.invoke('example.read', {}),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      expect(sends, 1);
    },
    skip: unsupportedPosix,
  );

  test('atomic interruption leaves an old or new whole bundle', () async {
    final root = await scratch();
    const origin = 'https://atomic.example.test';
    final store = device(root, origin);
    await store.write(credentials());
    for (final step in ['atomic-temp', 'atomic-rename', 'atomic-directory']) {
      final previous = await store.load();
      expect(
        await child(step, root, origin),
        {'atomic-temp': 71, 'atomic-rename': 72, 'atomic-directory': 73}[step],
      );
      final next = await device(root, origin).load();
      expect(
        next.generation == previous.generation ||
            next.generation == previous.generation + 1,
        isTrue,
      );
      expect(next.session != null, isTrue);
    }
  }, skip: unsupportedPosix);

  test('corruption, wrong owner and future version preserve files', () async {
    final root = await scratch();
    const origin = 'https://corrupt.example.test';
    final store = device(root, origin);
    final value = credentials();
    await store.write(value);
    final file = File('${store.directory}/auth.json');
    final original = await file.readAsBytes();
    Future<void> rejects(String code, NativeDeviceStore reader) async {
      final before = await File('${reader.directory}/auth.json').readAsBytes();
      await expectLater(
        reader.load(),
        throwsA(isA<ClientException>().having((e) => e.code, 'code', code)),
      );
      final after = await File('${reader.directory}/auth.json').readAsBytes();
      expect(base64Encode(before) == base64Encode(after), isTrue);
    }

    final envelope = jsonDecode(utf8.decode(original)) as Map<String, Object?>;
    await file.writeAsString(jsonEncode({...envelope, 'version': 2}));
    await rejects('device_storage_version_unsupported', store);
    await file.writeAsString('{');
    await rejects('device_storage_corrupt', store);
    await file.writeAsBytes(original);
    final other = device(root, origin, app: 'other.app');
    await other.load();
    await File('${other.directory}/auth.json').writeAsBytes(original);
    await Process.run('/bin/chmod', [
      '600',
      '${other.directory}/auth.json',
    ], includeParentEnvironment: false);
    await rejects('device_storage_corrupt', other);

    final changed = {
      ...envelope,
      'auth': {'generation': -1},
    };
    await file.writeAsString(jsonEncode(changed));
    await rejects('device_storage_corrupt', store);
    for (final field in ['auth_transition_id', 'refresh_id']) {
      for (final orphan in [false, true]) {
        await file.writeAsString(
          jsonEncode({
            ...envelope,
            'auth': {
              ...(envelope['auth']! as Map<String, Object?>),
              'auth_transition_unknown':
                  !orphan && field == 'auth_transition_id',
              'refresh_sent': !orphan && field == 'refresh_id',
              field: orphan ? 'a' * 32 : 'invalid',
            },
          }),
        );
        await rejects('device_storage_corrupt', store);
      }
    }
    await file.writeAsBytes(original);
    expect(await store.read() == value, isTrue);
  }, skip: unsupportedPosix);

  test('processes and isolates serialize generation comparisons', () async {
    final root = await scratch();
    const origin = 'https://locks.example.test';
    final store = device(root, origin);
    await store.write(credentials());
    final exits = await Future.wait([
      child('increment', root, origin),
      child('increment', root, origin),
    ]);
    expect(exits.every((code) => code == 0), isTrue);
    final before = (await store.load()).generation;
    expect(before, 21);
    Future<void> increment() async {
      final local = device(root, origin);
      for (var i = 0; i < 10; i++) {
        var changed = false;
        while (!changed) {
          final state = await local.load();
          changed = await local.commit(
            state,
            DeviceState(
              generation: state.generation + 1,
              authGeneration: state.authGeneration,
              session: state.session,
            ),
          );
        }
      }
    }

    await Future.wait([Isolate.run(increment), Isolate.run(increment)]);
    expect((await store.load()).generation, before + 20);
  }, skip: unsupportedPosix);
  test(
    'uncreatable path fails and failed refresh claim sends nothing',
    () async {
      final root = await scratch();
      final blocker = File('$root/not-a-directory');
      await blocker.writeAsString('occupied');
      final transport = createDeviceTransport(
        app: 'device.test',
        origin: 'https://path.example.test',
        project: 'project',
        environment: 'test',
        screen: 'signup',
        persist: Persist.dir(blocker.path),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.invoke('example.read', {}),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final store = device(root, origin);
      await store.write(credentials());
      var refreshes = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path == '/auth.refresh') refreshes++;
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":"invalid_token"}');
        await request.response.close();
      });
      final faulty = NativeDeviceStore(
        store.scope,
        directory: root,
        files: FullFiles(),
      );
      final client = DeviceTransport(faulty);
      addTearDown(client.close);
      final before = await File('${store.directory}/auth.json').readAsBytes();
      await expectLater(
        client.invoke('example.read', {}),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_full',
          ),
        ),
      );
      final after = await File('${store.directory}/auth.json').readAsBytes();
      expect(base64Encode(before) == base64Encode(after), isTrue);
      expect(refreshes, 0);
      final symlinkRoot = await scratch();
      final linked = device(symlinkRoot, origin);
      await linked.load();
      await Link('${linked.directory}/auth.json')
          .create('${store.directory}/auth.json');
      await expectLater(
        linked.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );

      final path = '${store.directory}/auth.json';
      await Process.run('/bin/chmod', [
        '644',
        path,
      ], includeParentEnvironment: false);
      await expectLater(
        store.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect((await File(path).stat()).mode & 0x3f, isNot(0));
      await Process.run('/bin/chmod', [
        '755',
        store.directory,
      ], includeParentEnvironment: false);
      await expectLater(
        store.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect((await Directory(store.directory).stat()).mode & 0x3f, isNot(0));
    },
    skip: unsupportedPosix,
  );
  group('recovery contract STORE-REJOIN', () {
    for (final priorAttempt in [false, true]) {
      test(
        'unsaved consumption is not settled by peer replacement prior=$priorAttempt',
        () async {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://127.0.0.1:${server.port}';
          final issued = credentials();
          var signins = 0;
          var signups = 0;
          server.listen((request) async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path == '/auth.signin') {
              signins++;
              request.response.write(jsonEncode(issued.toJson()));
            } else {
              signups++;
              request.response.write(
                jsonEncode({'accepted': true, 'attempt': randomId()}),
              );
            }
            await request.response.close();
          });
          final peerStore = device(root, origin, screen: 'peer');
          final peer = DeviceTransport(peerStore);
          addTearDown(peer.close);
          await peerStore.commit(
            await peerStore.load(),
            DeviceState(generation: 1),
          );
          if (priorAttempt) {
            await peer.invoke('auth.signup', {'email': 'a@example.test'});
          }
          final files = FailWrite(999)..writeUnavailable = true;
          final actorStore = NativeDeviceStore(
            scope(origin, screen: 'actor'),
            directory: root,
            files: files,
          );
          final actor = DeviceTransport(actorStore);
          addTearDown(actor.close);
          final base = await actorStore.load();
          final fixture = File('${peerStore.directory}/auth.json');
          final rawBefore = await fixture.readAsString();
          await actor.invoke('auth.signin', {'email': 'a@example.test'});
          expect(actorStore.transientState?.session == issued, isTrue);
          expect(
            actorStore.consumedAttemptEmails.containsKey('a@example.test'),
            isTrue,
          );
          expect(await fixture.readAsString() == rawBefore, isTrue);
          files.writeUnavailable = false;
          final result = await peer.invoke('auth.signup', {
            'email': 'a@example.test',
          }) as Map;
          final beforeRecovery = await peerStore.load();
          expect(beforeRecovery.authGeneration, base.authGeneration);
          expect(
            beforeRecovery.attempts['peer']?.id == result['attempt'],
            isTrue,
          );
          expect(
            beforeRecovery.generation >= actorStore.uncertainWrite!.generation,
            isTrue,
          );
          expect(actorStore.recoveryWasApplied(beforeRecovery), isFalse);
          await actorStore.load();
          final after = await peerStore.load();
          expect(signins, 1);
          expect(signups, priorAttempt ? 2 : 1);
          expect(after.authGeneration, base.authGeneration + 1);
          expect(after.session == issued, isTrue);
          expect(actorStore.transientState, isNull);
          expect(
            after.attempts['peer']?.id == result['attempt'],
            isFalse,
            reason:
                'Unsaved consumption must apply to the first successful write.',
          );
        },
      );
    }
    for (final sameSession in [false, true]) {
      test(
        'persisted consumption preserves a later peer signup with same session=$sameSession',
        () async {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://127.0.0.1:${server.port}';
          final firstAttempt = randomId();
          final secondAttempt = randomId();
          final laterAttempt = randomId();
          final firstSession = credentials();
          final secondSession = sameSession ? firstSession : credentials();
          final secondArrived = Completer<void>();
          final releaseSecond = Completer<void>();
          addTearDown(() {
            if (!releaseSecond.isCompleted) releaseSecond.complete();
          });
          var signups = 0;
          var firstConfirms = 0;
          var secondConfirms = 0;
          server.listen((request) async {
            final input =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path == '/auth.signup') {
              signups++;
              final attempt = signups == 1
                  ? firstAttempt
                  : signups == 2
                  ? secondAttempt
                  : laterAttempt;
              request.response.write(
                jsonEncode({'accepted': true, 'attempt': attempt}),
              );
            } else if (input['attempt'] == secondAttempt) {
              secondConfirms++;
              secondArrived.complete();
              await releaseSecond.future;
              request.response.write(jsonEncode(secondSession.toJson()));
            } else {
              firstConfirms++;
              request.response.write(jsonEncode(firstSession.toJson()));
            }
            await request.response.close();
          });
          if (sameSession) await device(root, origin).write(firstSession);
          final seedA = DeviceTransport(device(root, origin, screen: 'a'));
          final seedB = DeviceTransport(device(root, origin, screen: 'b'));
          addTearDown(seedA.close);
          addTearDown(seedB.close);
          await seedA.invoke('auth.signup', {'email': 'a@example.test'});
          await seedB.invoke('auth.signup', {'email': 'b@example.test'});
          final files = FailDirectorySyncOnce(at: sameSession ? 3 : 1);
          final actorStore = NativeDeviceStore(
            scope(origin, screen: 'a'),
            directory: root,
            files: files,
          );
          final actor = DeviceTransport(actorStore);
          final observer = device(root, origin, screen: 'later');
          final peer = DeviceTransport(observer);
          addTearDown(actor.close);
          addTearDown(peer.close);
          final second = actor.invoke('auth.verify_email', {
            'attempt': secondAttempt,
            'code': '123456',
          });
          await secondArrived.future;
          await actor.invoke('auth.verify_email', {
            'attempt': firstAttempt,
            'code': '123456',
          });
          final firstPersisted = await observer.load();
          expect(firstPersisted.session == firstSession, isTrue);
          expect(firstPersisted.attempts.containsKey('a'), isFalse);
          expect(actorStore.uncertainWrite != null, isTrue);
          expect(actorStore.consumedAttemptEmails.keys, ['a@example.test']);
          files.readUnavailable = true;
          await peer.invoke('auth.signup', {'email': 'a@example.test'});
          final afterPeer = await observer.load();
          expect(afterPeer.attempts['later']?.id == laterAttempt, isTrue);
          expect(afterPeer.authGeneration, firstPersisted.authGeneration);
          expect(afterPeer.session == firstSession, isTrue);
          releaseSecond.complete();
          await second;
          expect(actorStore.transientState?.attempts.containsKey('b'), isFalse);
          expect(actorStore.uncertainWrite?.attempts.containsKey('b'), isTrue);
          files.readUnavailable = false;
          await actorStore.load();
          final recovered = await observer.load();
          final kept = recovered.attempts['later']?.id == laterAttempt;
          expect(recovered.session == firstSession, isTrue);
          expect(recovered.attempts.containsKey('b'), isFalse);
          expect(signups, 3);
          expect(firstConfirms, 1);
          expect(secondConfirms, 1);
          expect(
            kept,
            isTrue,
            reason: 'Persisted consumption must not consume a later peer signup again.',
          );
        },
      );
    }
    test(
      'uncertain explicit start retains durable authentication boundary',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final signupArrived = Completer<void>();
        final signupRelease = Completer<void>();
        final peerArrived = Completer<void>();
        final peerRelease = Completer<void>();
        final ownArrived = Completer<void>();
        final ownRelease = Completer<void>();
        addTearDown(() {
          for (final c in [signupRelease, peerRelease, ownRelease]) {
            if (!c.isCompleted) c.complete();
          }
        });
        final attempt = randomId();
        final ownIssued = credentials();
        final peerIssued = credentials();
        var signinSends = 0;
        server.listen((request) async {
          final body = jsonDecode(
            await utf8.decoder.bind(request).join(),
          ) as Map<String, Object?>;
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth.signup') {
            signupArrived.complete();
            await signupRelease.future;
            request.response.write(
              jsonEncode({'accepted': true, 'attempt': attempt}),
            );
          } else {
            signinSends++;
            final peer = body['email'] == 'peer@example.test';
            (peer ? peerArrived : ownArrived).complete();
            await (peer ? peerRelease : ownRelease).future;
            request.response.write(
              jsonEncode((peer ? peerIssued : ownIssued).toJson()),
            );
          }
          await request.response.close();
        });
        final peerStore = device(root, origin);
        await peerStore.write(credentials());
        final files = UncertainAuthenticationStart();
        final actorStore = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: files,
        );
        final actor = DeviceTransport(actorStore);
        final peer = DeviceTransport(peerStore);
        addTearDown(actor.close);
        addTearDown(peer.close);
        final signup = actor.invoke('auth.signup', {
          'email': 'signup@example.test',
        });
        await signupArrived.future;
        final peerReply = peer
            .invoke('auth.signin', {'email': 'peer@example.test'})
            .then<Object?>((v) => v, onError: (Object e) => e);
        await peerArrived.future;
        signupRelease.complete();
        expect((await signup as Map<String, Object?>)['accepted'], isTrue);
        expect(
          actorStore.transientState?.attempts['signup']?.id == attempt,
          isTrue,
        );
        files.writeUnavailable = true;
        await actorStore.load();
        expect(actorStore.observedPeerAuth, isTrue);
        expect(
          actorStore.transientState?.attempts['signup']?.id == attempt,
          isTrue,
        );
        expect((await peerStore.load()).attempts.isEmpty, isTrue);
        expect(await child('unresolved', root, origin), 0);
        files.writeUnavailable = false;
        files.failRecoveryThenCleanup = true;
        final beforeCleanup = await peerStore.load();
        await expectLater(
          actor.invoke('auth.signin', {'email': 'own@example.test'}),
          throwsA(
            isA<ClientException>().having(
              (e) => e.code,
              'code',
              'device_storage_unavailable',
            ),
          ),
        );
        final committedStart = await peerStore.load();
        expect(committedStart.authGeneration, beforeCleanup.authGeneration + 1);
        expect(
          actorStore.uncertainWrite?.authGeneration,
          committedStart.authGeneration,
        );
        expect(actorStore.transientState != null, isTrue);
        final recovered = await actorStore.load();
        final afterRecovery = await peerStore.load();
        peerRelease.complete();
        await peerReply;
        final afterLate = await peerStore.load();
        final peerInstalled = afterLate.session == peerIssued;
        expect(
          afterRecovery.authGeneration >= committedStart.authGeneration,
          isTrue,
          reason: 'A persisted authentication boundary must never roll back.',
        );
        expect(
          recovered.authGeneration >= committedStart.authGeneration,
          isTrue,
        );
        expect(peerInstalled, isFalse);
        expect(afterRecovery.session, isNull);
        expect(afterRecovery.authTransitionUnknown, isTrue);
        expect(
          afterRecovery.authTransitionId == committedStart.authTransitionId,
          isTrue,
        );
        expect(recovered.attempts['signup']?.id == attempt, isTrue);
        expect(actorStore.transientState, isNull);
        expect(await actorStore.read(), isNull);
        expect(signinSends, 1);
      },
    );
    for (final sameEmail in [false, true]) {
      test(
        sameEmail
            ? 'authentication consumption clears peer attempt for matching email'
            : 'expiry cleanup retains peer attempt after unrelated signin',
        () async {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://127.0.0.1:${server.port}';
          final arrived = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final issued = credentials();
          final peerAttempt = randomId();
          var signins = 0;
          var signups = 0;
          server.listen((request) async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path == '/auth.signin') {
              signins++;
              arrived.complete();
              await release.future;
              request.response.write(jsonEncode(issued.toJson()));
            } else {
              signups++;
              request.response.write(
                jsonEncode({'accepted': true, 'attempt': peerAttempt}),
              );
            }
            await request.response.close();
          });
          final peerStore = device(root, origin, screen: 'peer');
          await peerStore.commit(
            await peerStore.load(),
            DeviceState(
              generation: 1,
              authGeneration: sameEmail ? 1 : 0,
              session: sameEmail ? issued : null,
              attempts: {
                'old': DeviceAttempt(
                  randomId(),
                  'pending@example.test',
                  DateTime.now().millisecondsSinceEpoch,
                ),
              },
            ),
          );
          final fixture = File('${peerStore.directory}/auth.json');
          final bundle =
              jsonDecode(await fixture.readAsString()) as Map<String, Object?>;
          final auth = bundle['auth']! as Map<String, Object?>;
          final attempts = auth['attempts']! as Map<String, Object?>;
          (attempts['old']! as Map<String, Object?>)['started_at'] =
              DateTime.now().millisecondsSinceEpoch -
              const Duration(hours: 25).inMilliseconds;
          await fixture.writeAsString(jsonEncode(bundle));
          final files = FailWrite(999);
          final actorStore = NativeDeviceStore(
            scope(origin),
            directory: root,
            files: files,
          );
          final actor = DeviceTransport(actorStore);
          final peer = DeviceTransport(peerStore);
          addTearDown(actor.close);
          addTearDown(peer.close);
          final signin = actor.invoke('auth.signin', {
            'email': sameEmail
                ? 'pending@example.test'
                : 'signedin@example.test',
          });
          await arrived.future;
          await peer.invoke('auth.signup', {'email': 'pending@example.test'});
          final afterPeer = await peerStore.load();
          expect(afterPeer.attempts['peer']?.id == peerAttempt, isTrue);
          expect(afterPeer.attempts.containsKey('old'), isFalse);
          files.readUnavailable = true;
          release.complete();
          await signin;
          expect(actorStore.transientState?.session == issued, isTrue);
          files.readUnavailable = false;
          final recovered = await actorStore.load();
          final durable = await device(root, origin).load();
          if (sameEmail) {
            expect(recovered.authGeneration, afterPeer.authGeneration);
          }
          final peerKept = durable.attempts['peer']?.id == peerAttempt;
          expect(
            peerKept,
            !sameEmail,
            reason: 'Only authentication for the matching email consumes peer attempts.',
          );
          expect(recovered.attempts['peer']?.id == peerAttempt, !sameEmail);
          expect(signins, 1);
          expect(signups, 1);
        },
      );
    }

    test('recovery 1 attempt kept after recovery', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final external = device(root, origin);
      await external.commit(
        await external.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      var signups = 0;
      server.listen((request) async {
        await request.drain<void>();
        signups++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'accepted': true, 'attempt': randomId()}),
        );
        await request.response.close();
      });
      final files = FailWrite(1)..readUnavailable = true;
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final client = DeviceTransport(store);
      addTearDown(client.close);
      await expectLater(
        client.invoke('auth.signup', {'email': 'recovery@example.test'}),
        throwsA(
          isA<ClientException>().having(
            (error) => error.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect(signups, 0);
      files.readUnavailable = false;
      expect(
        (await client.invoke('auth.signup', {'email': 'recovery@example.test'})
            as Map)['accepted'],
        isTrue,
      );
      expect((await external.load()).attempts.isEmpty, isTrue);
      files.readUnavailable = true;
      expect((await store.load()).attempts.length, 1);
      expect((await store.load()).authGeneration, 1);
      expect((await external.load()).attempts.isEmpty, isTrue);
      expect(signups, 1);
      files.readUnavailable = false;
      expect((await store.load()).attempts.length, 1);
      expect((await external.load()).attempts.length, 1);
      expect(signups, 1);
      expect(store.transientState, isNull);
    });

    test('recovery 3 generation collision cannot resurrect', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final observer = device(root, origin);
      await observer.commit(
        await observer.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var signups = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (++signups == 2) {
          arrived.complete();
          await release.future;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'accepted': true, 'attempt': randomId()}),
        );
        await request.response.close();
      });
      final files = FailWrite(1);
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final client = DeviceTransport(store);
      addTearDown(client.close);
      await client.invoke('auth.signup', {'email': 'first@example.test'});
      files.readUnavailable = true;
      expect((await store.load()).generation, 2);
      final pending = client.invoke('auth.signup', {
        'email': 'late@example.test',
      });
      await arrived.future;
      files.readUnavailable = false;
      await client.invoke('auth.logout', {});
      expect((await observer.load()).authGeneration, 2);
      expect((await observer.load()).attempts.isEmpty, isTrue);
      release.complete();
      expect((await pending as Map)['accepted'], isTrue);
      final restored = await observer.load();
      expect([restored.attempts.length, restored.authGeneration], [0, 2]);
      expect(signups, 2);
    });

    test('recovery 2b other object logout drops memory', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'accepted': true, 'attempt': randomId()}),
        );
        await request.response.close();
      });
      final peer = device(root, origin);
      await peer.commit(
        await peer.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final files = FailWrite(1);
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final actor = DeviceTransport(store);
      final other = DeviceTransport(peer);
      addTearDown(actor.close);
      addTearDown(other.close);
      expect(
        (await actor.invoke('auth.signup', {'email': 'actor@example.test'})
            as Map)['accepted'],
        isTrue,
      );
      files.readUnavailable = true;
      expect((await store.load()).attempts.length, 1);
      await other.invoke('auth.logout', {});
      final durable = await peer.load();
      expect(durable.authGeneration, 2);
      files.readUnavailable = false;
      expect((await store.load()).attempts.isEmpty, isTrue);
      expect(store.transientState, isNull);
      expect(await store.read() == null, isTrue);
      expect((await peer.load()).toJson(), durable.toJson());
    });

    test('recovery 4 account change after recovery is persisted', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final issued = credentials();
      final arrived = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var signups = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signin') {
          request.response.write(jsonEncode(issued.toJson()));
        } else {
          if (++signups == 2) {
            arrived.complete();
            await release.future;
          }
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': randomId()}),
          );
        }
        await request.response.close();
      });
      final peer = device(root, origin);
      await peer.commit(
        await peer.load(),
        DeviceState(generation: 1, authGeneration: 1),
      );
      final files = FailWrite(1);
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final actor = DeviceTransport(store);
      final pendingClient = DeviceTransport(
        device(root, origin, screen: 'pending'),
      );
      addTearDown(actor.close);
      addTearDown(pendingClient.close);
      await actor.invoke('auth.signup', {'email': 'actor@example.test'});
      files.readUnavailable = true;
      expect((await store.load()).attempts.length, 1);
      final pending = pendingClient.invoke('auth.signup', {
        'email': 'pending@example.test',
      });
      await arrived.future;
      files.readUnavailable = false;
      await store.load();
      expect(store.transientState, isNull);
      await actor.invoke('auth.signin', {'email': 'account@example.test'});
      final durable = await device(root, origin).load();
      expect(durable.authGeneration, 2);
      expect(durable.session == issued, isTrue);
      release.complete();
      final result = await pending as Map;
      expect(result['accepted'], isTrue);
      final restored = await device(root, origin).load();
      expect(restored.session == issued, isTrue);
      expect(restored.authGeneration, durable.authGeneration);
      expect(
        restored.attempts.values.any((a) => a.id == result['attempt']),
        isFalse,
      );
      expect(signups, 2);
    });

    test(
      'recovery 5 peer refresh and unknown marks are not overwritten',
      () async {
        final observations = <String, List<bool>>{};
        for (final outcome in [
          'refresh pending',
          'refresh complete',
          'account unknown',
        ]) {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://127.0.0.1:${server.port}';
          final original = credentials();
          final rotated = credentials(
            user: original.userId,
            session: original.sessionId,
          );
          final peer = device(root, origin);
          await peer.write(original);
          final file = File('${peer.directory}/auth.json');
          final fixture =
              jsonDecode(await file.readAsString()) as Map<String, Object?>;
          (fixture['auth'] as Map<String, Object?>)['attempts'] = {
            'old-screen': DeviceAttempt(
              randomId(),
              'expired@example.test',
              DateTime.now()
                  .subtract(const Duration(hours: 25))
                  .millisecondsSinceEpoch,
            ).toJson(),
          };
          await file.writeAsString(jsonEncode(fixture));
          final arrived = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          var cleanups = 0;
          var refreshes = 0;
          server.listen((request) async {
            await request.drain<void>();
            if (request.uri.path == '/auth.signin') {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path == '/auth.send_verification_email') {
              cleanups++;
              request.response.write('{"accepted":true}');
            } else {
              refreshes++;
              if (outcome == 'refresh pending') {
                arrived.complete();
                await release.future;
              }
              request.response.write(jsonEncode(rotated.toJson()));
            }
            await request.response.close();
          });
          final actor = NativeDeviceStore(
            scope(origin),
            directory: root,
            files: FailWrite(1),
          );
          final client = DeviceTransport(actor);
          final peerClient = DeviceTransport(peer);
          addTearDown(client.close);
          addTearDown(peerClient.close);
          await client.invoke('auth.send_verification_email', {
            'email': 'cleanup@example.test',
          });
          expect(cleanups, 1);
          expect(actor.transientState != null, isTrue);
          expect(actor.transientState!.session == original, isTrue);
          expect(actor.transientState!.attempts.isEmpty, isTrue);
          Future<Object?>? inFlight;
          if (outcome == 'account unknown') {
            await expectLater(
              peerClient.invoke('auth.signin', {'email': 'new@example.test'}),
              throwsA(
                isA<ClientException>().having(
                  (e) => e.code,
                  'code',
                  'network_error',
                ),
              ),
            );
            expect((await peer.load()).authTransitionUnknown, isTrue);
          } else {
            inFlight = peerClient
                .invoke('auth.refresh', {
                  'refresh_token': original.refreshToken,
                })
                .then<Object?>(
                  (value) => value,
                  onError: (Object error) => error,
                );
            if (outcome == 'refresh pending') {
              await arrived.future;
              expect((await peer.load()).refreshSent, isTrue);
            } else {
              final result = await inFlight;
              expect(result is Map<String, Object?>, isTrue);
              expect((await peer.load()).session == rotated, isTrue);
            }
          }
          final before = await device(root, origin).load();
          await actor.load();
          final after = await device(root, origin).load();
          if (outcome == 'refresh pending') {
            release.complete();
            await inFlight;
            final canClaimAgain =
                await device(root, origin).claimRefresh(original) != null;
            observations[outcome] = [after.refreshSent, canClaimAgain];
          } else if (outcome == 'refresh complete') {
            observations[outcome] = [
              after.session == rotated,
              after.session == original,
            ];
          } else {
            final readable = await device(root, origin).read() != null;
            observations[outcome] = [after.authTransitionUnknown, readable];
          }
          expect(after.authGeneration, before.authGeneration);
          expect(refreshes, outcome == 'account unknown' ? 0 : 1);
        }
        expect(observations, {
          'refresh pending': [true, false],
          'refresh complete': [true, false],
          'account unknown': [true, false],
        });
      },
    );

    test(
      'recovery 6 unchanged auth preserves peer attempt additions and removals',
      () async {
        for (final removed in [false, true]) {
          final root = await scratch();
          const origin = 'https://rejoin.example.test';
          final peer = device(root, origin);
          final now = DateTime.now().millisecondsSinceEpoch;
          final old = DeviceAttempt(randomId(), 'old@example.test', now);
          final mine = DeviceAttempt(randomId(), 'mine@example.test', now);
          final theirs = DeviceAttempt(randomId(), 'peer@example.test', now);
          await peer.commit(
            await peer.load(),
            DeviceState(generation: 1, attempts: {'old': old}),
          );
          final actor = NativeDeviceStore(
            scope(origin),
            directory: root,
            files: FailWrite(1),
          );
          final base = await actor.load();
          await actor.commitAfterSuccess(
            base,
            DeviceState(generation: 2, attempts: {'old': old, 'mine': mine}),
          );
          await peer.commit(
            await peer.load(),
            DeviceState(
              generation: 2,
              attempts: {if (!removed) 'old': old, 'peer': theirs},
            ),
          );
          expect((await peer.load()).authGeneration, base.authGeneration);
          final recovered = await actor.load();
          expect(
            recovered.attempts.keys,
            unorderedEquals([if (!removed) 'old', 'mine', 'peer']),
          );
          expect(
            (await device(root, origin).load()).attempts.keys,
            unorderedEquals(recovered.attempts.keys),
          );
          expect(actor.transientState, isNull);
        }
      },
    );

    test(
      'recovery 7 changed auth does not resurrect consumed attempts',
      () async {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        final rotated = credentials(
          user: original.userId,
          session: original.sessionId,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        final consumed = DeviceAttempt(
          randomId(),
          'consumed@example.test',
          now,
        );
        final mine = DeviceAttempt(randomId(), 'mine@example.test', now);
        final theirs = DeviceAttempt(randomId(), 'peer@example.test', now);
        await peer.commit(
          await peer.load(),
          DeviceState(
            generation: 1,
            authGeneration: 1,
            session: original,
            attempts: {'consumed': consumed},
          ),
        );
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(1),
        );
        final base = await actor.load();
        // The successful local cleanup consumed this id before storage failed.
        await actor.commitAfterSuccess(
          base,
          DeviceState(
            generation: 2,
            authGeneration: 1,
            session: original,
            attempts: {'mine': mine},
          ),
        );
        await peer.commit(
          await peer.load(),
          DeviceState(
            generation: 2,
            authGeneration: 1,
            session: rotated,
            attempts: {'consumed': consumed, 'peer': theirs},
          ),
        );
        final recovered = await actor.load();
        expect(recovered.session == rotated, isTrue);
        expect(recovered.attempts.keys, unorderedEquals(['mine', 'peer']));
        expect(
          (await peer.load()).attempts.keys,
          unorderedEquals(['mine', 'peer']),
        );
        expect(actor.transientState, isNull);
      },
    );

    test('own refresh preserves peer cleanup and pending', () async {
      for (final pending in [false, true]) {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        final rotated = credentials(
          user: original.userId,
          session: original.sessionId,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        final old = DeviceAttempt(randomId(), 'old@example.test', now);
        final theirs = DeviceAttempt(randomId(), 'peer@example.test', now);
        await peer.commit(
          await peer.load(),
          DeviceState(
            generation: 1,
            authGeneration: 1,
            session: original,
            attempts: {'old': old},
          ),
        );
        final files = FailWrite(2);
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: files,
        );
        final claim = await actor.claimRefresh(original);
        expect(claim != null, isTrue);
        await actor.finishRefresh(claim!, rotated);
        expect(actor.transientState?.session == rotated, isTrue);
        final current = await peer.load();
        await peer.commit(
          current,
          DeviceState(
            generation: current.generation + 1,
            authGeneration: 1,
            session: original,
            refreshSent: true,
            authTransitionUnknown: pending,
            refreshId: current.refreshId,
            authTransitionId: pending ? randomId().replaceAll('-', '') : null,
            attempts: {'peer': theirs},
          ),
        );
        if (pending) {
          files.writeUnavailable = true;
          expect(await actor.read() == null, isTrue);
          expect((await peer.load()).refreshSent, isTrue);
          files.writeUnavailable = false;
        }
        final recovered = await actor.load();
        expect(recovered.session == rotated, isTrue);
        expect(recovered.refreshSent, isFalse);
        expect(recovered.authTransitionUnknown, pending);
        expect(recovered.attempts.keys, ['peer']);
        expect(await peer.read() == (pending ? null : rotated), isTrue);
        expect(await actor.read() == (pending ? null : rotated), isTrue);
        expect(actor.transientState, isNull);
        if (pending) {
          final marked = await peer.load();
          await peer.commit(
            marked,
            DeviceState.fromJson({
              ...marked.toJson(),
              'generation': marked.generation + 1,
              'auth_transition_unknown': false,
              'auth_transition_id': null,
            }),
          );
          expect(await actor.read() == rotated, isTrue);
        }
      }
    });

    test('own refresh yields to a peer auth boundary or rotation', () async {
      for (final boundary in [false, true]) {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        final rotated = credentials(
          user: original.userId,
          session: original.sessionId,
        );
        final latest = boundary
            ? credentials()
            : credentials(user: original.userId, session: original.sessionId);
        await peer.write(original);
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(2),
        );
        await actor.finishRefresh(
          (await actor.claimRefresh(original))!,
          rotated,
        );
        final current = await peer.load();
        await peer.commit(
          current,
          DeviceState(
            generation: current.generation + 1,
            authGeneration: current.authGeneration + (boundary ? 1 : 0),
            session: latest,
          ),
        );
        expect(await actor.read() == (boundary ? null : latest), isTrue);
        expect(await peer.read() == latest, isTrue);
        expect(actor.transientState, isNull);
      }
    });

    test('STORE-REJOIN uncertain commit then refresh with new session during read outage', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final attempt = randomId();
      final issued = credentials();
      var signups = 0;
      var signins = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signup') {
          signups++;
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': attempt}),
          );
        } else {
          signins++;
          request.response.write(jsonEncode(issued.toJson()));
        }
        await request.response.close();
      });
      final peer = device(root, origin);
      await peer.commit(
        await peer.load(),
        DeviceState(generation: 1, authGeneration: 3),
      );
      final files = FailDirectorySyncOnce();
      final actor = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      final client = DeviceTransport(actor);
      addTearDown(client.close);
      await client.invoke('auth.signup', {'email': 'signup@example.test'});
      expect(actor.uncertainWrite?.authGeneration, 3);
      expect((await peer.load()).attempts['signup']?.id == attempt, isTrue);
      files.readUnavailable = true;
      await client.invoke('auth.signin', {'email': 'own@example.test'});
      expect(actor.uncertainWrite?.authGeneration, 3);
      expect(actor.transientState?.authGeneration, 4);
      expect(actor.transientState?.session == issued, isTrue);
      files.readUnavailable = false;
      expect(await actor.read() == issued, isTrue);
      final recovered = await peer.load();
      expect(recovered.session == issued, isTrue);
      expect(recovered.authGeneration, 4);
      expect(recovered.attempts['signup']?.id == attempt, isTrue);
      expect(actor.transientState, isNull);
      expect(signups, 1);
      expect(signins, 1);
    });

    test('uncertain commit already applied keeps peer cleanup', () async {
      final root = await scratch();
      const origin = 'https://rejoin.example.test';
      final actor = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: FailDirectorySyncOnce(),
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = DeviceAttempt(randomId(), 'old@example.test', now);
      final theirs = DeviceAttempt(randomId(), 'peer@example.test', now);
      final issued = credentials();
      await actor.commitAfterSuccess(
        await actor.load(),
        DeviceState(
          generation: 1,
          authGeneration: 1,
          session: issued,
          attempts: {'old': old},
        ),
      );
      final peer = device(root, origin);
      final applied = await peer.load();
      expect(applied.session == issued, isTrue);
      await peer.commit(
        applied,
        DeviceState(
          generation: applied.generation + 1,
          authGeneration: 1,
          session: issued,
          attempts: {'peer': theirs},
        ),
      );
      expect(await actor.read() == issued, isTrue);
      final recovered = await actor.load();
      expect(recovered.attempts.keys, ['peer']);
      expect(recovered.session == issued, isTrue);
      expect(actor.transientState, isNull);
    });

    test(
      'a changed revision cannot prove ownership of a boolean pending mark',
      () async {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        await peer.commit(
          await peer.load(),
          DeviceState(
            generation: 1,
            authGeneration: 1,
            session: original,
            authTransitionUnknown: true,
          ),
        );
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(1),
        );
        await actor.commitAfterSuccess(
          await actor.load(),
          DeviceState(generation: 2, authGeneration: 1, session: original),
        );
        await peer.commit(
          await peer.load(),
          DeviceState(
            generation: 2,
            authGeneration: 1,
            session: original,
            authTransitionUnknown: true,
            attempts: {
              'peer': DeviceAttempt(
                randomId(),
                'peer@example.test',
                DateTime.now().millisecondsSinceEpoch,
              ),
            },
          ),
        );
        final recovered = await actor.load();
        expect(recovered.authTransitionUnknown, isTrue);
        expect(await actor.read() == null, isTrue);
        expect((await peer.load()).attempts.keys, ['peer']);
      },
    );

    test('identified auth marks release only their owner', () async {
      for (final peerReplaced in [false, true]) {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        final ownId = randomId().replaceAll('-', '');
        final peerId = peerReplaced ? randomId().replaceAll('-', '') : ownId;
        await peer.commit(
          await peer.load(),
          DeviceState.fromJson({
            ...DeviceState(
              generation: 1,
              authGeneration: 1,
              session: original,
              authTransitionUnknown: true,
            ).toJson(),
            'auth_transition_id': ownId,
          }),
        );
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(1),
        );
        await actor.commitAfterSuccess(
          await actor.load(),
          DeviceState(generation: 2, authGeneration: 1, session: original),
        );
        await peer.commit(
          await peer.load(),
          DeviceState.fromJson({
            ...DeviceState(
              generation: 2,
              authGeneration: 1,
              session: original,
              authTransitionUnknown: true,
              attempts: {
                'peer': DeviceAttempt(
                  randomId(),
                  'peer@example.test',
                  DateTime.now().millisecondsSinceEpoch,
                ),
              },
            ).toJson(),
            'auth_transition_id': peerId,
          }),
        );
        final recovered = await actor.load();
        expect(recovered.authTransitionUnknown, peerReplaced);
        expect(
          recovered.toJson()['auth_transition_id'] ==
              (peerReplaced ? peerId : null),
          isTrue,
        );
        expect(await actor.read() == (peerReplaced ? null : original), isTrue);
        expect((await peer.load()).attempts.keys, ['peer']);
      }
    });

    test('refresh identifiers preserve a replaced peer claim', () async {
      for (final marker in ['own', 'peer', 'legacy']) {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        final rotated = credentials(
          user: original.userId,
          session: original.sessionId,
        );
        final ownId = marker == 'legacy'
            ? null
            : randomId().replaceAll('-', '');
        final peerId = marker == 'peer'
            ? randomId().replaceAll('-', '')
            : ownId;
        await peer.commit(
          await peer.load(),
          DeviceState.fromJson({
            ...DeviceState(
              generation: 1,
              authGeneration: 1,
              session: original,
              refreshSent: true,
            ).toJson(),
            'refresh_id': ownId,
          }),
        );
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(1),
        );
        await actor.commitAfterSuccess(
          await actor.load(),
          DeviceState(generation: 2, authGeneration: 1, session: rotated),
        );
        await peer.commit(
          await peer.load(),
          DeviceState.fromJson({
            ...DeviceState(
              generation: 2,
              authGeneration: 1,
              session: original,
              refreshSent: true,
            ).toJson(),
            'refresh_id': peerId,
          }),
        );
        final recovered = await actor.load();
        expect(recovered.refreshSent, marker == 'peer');
        expect(
          recovered.session == (marker == 'peer' ? original : rotated),
          isTrue,
        );
        expect(
          recovered.toJson()['refresh_id'] ==
              (marker == 'peer' ? peerId : null),
          isTrue,
        );
        if (marker == 'peer') {
          await expectLater(
            actor.read(),
            throwsA(
              isA<ClientException>().having(
                (e) => e.code,
                'code',
                'session_changed',
              ),
            ),
          );
        } else {
          expect(await actor.read() == rotated, isTrue);
        }
        expect((await peer.load()).refreshSent, marker == 'peer');
      }
    });

    test('logout failure remains blocked after storage recovers', () async {
      final root = await scratch();
      const origin = 'https://rejoin.example.test';
      final peer = device(root, origin);
      await peer.write(credentials());
      final actor = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: FailWrite(1),
      );
      await expectLater(
        actor.clear(await actor.load()),
        throwsA(isA<ClientException>()),
      );
      final before = await peer.load();
      await peer.commit(
        before,
        DeviceState.fromJson({
          ...before.toJson(),
          'generation': before.generation + 1,
          'attempts': {
            'peer': DeviceAttempt(
              randomId(),
              'peer@example.test',
              DateTime.now().millisecondsSinceEpoch,
            ).toJson(),
          },
        }),
      );
      await expectLater(
        actor.read(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect((await peer.load()).attempts.keys, ['peer']);
    });

    test(
      'failed auth start keeps the previous successful memory usable',
      () async {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final original = credentials();
        await peer.write(original);
        final files = FailWrite(1);
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: files,
        );
        final base = await actor.load();
        await actor.commitAfterSuccess(
          base,
          DeviceState.fromJson({
            ...base.toJson(),
            'generation': base.generation + 1,
          }),
        );
        files.writeUnavailable = true;
        final memory = actor.transientState!;
        await expectLater(
          actor.commit(
            memory,
            DeviceState.fromJson({
              ...memory.toJson(),
              'generation': memory.generation + 1,
              'auth_transition_unknown': true,
              'auth_transition_id': randomId().replaceAll('-', ''),
            }),
          ),
          throwsA(isA<ClientException>()),
        );
        expect(await actor.read() == original, isTrue);
        expect(actor.transientState!.authTransitionUnknown, isFalse);
      },
    );

    for (final (peerGone, cleanupFails) in [
      (false, false),
      (true, false),
      (false, true),
    ]) {
      test(
        'explicit signin preserves unsaved signup and screen: peerGone=$peerGone cleanupFails=$cleanupFails',
        () async {
          final root = await scratch();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final origin = 'http://127.0.0.1:${server.port}';
          final signupArrived = Completer<void>();
          final signupRelease = Completer<void>();
          final peerArrived = Completer<void>();
          final peerRelease = Completer<void>();
          final ownArrived = Completer<void>();
          final ownRelease = Completer<void>();
          addTearDown(() {
            for (final c in [signupRelease, peerRelease, ownRelease]) {
              if (!c.isCompleted) c.complete();
            }
          });
          final attempt = randomId();
          final ownIssued = credentials();
          final peerIssued = credentials();
          var signupSends = 0;
          var signinSends = 0;
          server.listen((request) async {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path == '/auth.signup') {
              signupSends++;
              signupArrived.complete();
              await signupRelease.future;
              request.response.write(
                jsonEncode({'accepted': true, 'attempt': attempt}),
              );
            } else {
              signinSends++;
              final peer = body['email'] == 'peer@example.test';
              (peer ? peerArrived : ownArrived).complete();
              await (peer ? peerRelease : ownRelease).future;
              request.response.write(
                jsonEncode((peer ? peerIssued : ownIssued).toJson()),
              );
            }
            await request.response.close();
          });
          final peerStore = device(root, origin);
          await peerStore.write(credentials());
          final files = FailWrite(2);
          final actorStore = NativeDeviceStore(
            scope(origin),
            directory: root,
            files: files,
          );
          final actor = DeviceTransport(actorStore);
          final peer = DeviceTransport(peerStore);
          addTearDown(actor.close);
          addTearDown(peer.close);
          final signup = actor.invoke('auth.signup', {
            'email': 'signup@example.test',
          });
          await signupArrived.future;
          final peerReply = peer
              .invoke('auth.signin', {'email': 'peer@example.test'})
              .then<Object?>((v) => v, onError: (Object e) => e);
          await peerArrived.future;
          signupRelease.complete();
          expect((await signup as Map)['accepted'], isTrue);
          expect(
            actorStore.transientState?.attempts['signup']?.id == attempt,
            isTrue,
          );
          files.writeUnavailable = true;
          await actorStore.load();
          expect(actorStore.observedPeerAuth, isTrue);
          expect(
            actorStore.transientState?.attempts['signup']?.id == attempt,
            isTrue,
          );
          expect((await peerStore.load()).attempts.isEmpty, isTrue);
          if (peerGone) {
            final current = await peerStore.load();
            await peerStore.commit(
              current,
              DeviceState(
                generation: current.generation + 1,
                authGeneration: current.authGeneration,
                session: current.session,
                attempts: current.attempts,
              ),
            );
          }
          final observed = await peerStore.load();
          files.writeUnavailable = cleanupFails;
          if (cleanupFails) {
            await expectLater(
              actor.invoke('auth.signin', {'email': 'own@example.test'}),
              throwsA(
                isA<ClientException>().having(
                  (e) => e.code,
                  'code',
                  'device_storage_unavailable',
                ),
              ),
            );
            expect(
              actorStore.transientState?.attempts['signup']?.id == attempt,
              isTrue,
            );
            expect(signinSends, 1);
            peerRelease.complete();
            await peerReply;
            return;
          }
          final ownReply = actor
              .invoke('auth.signin', {'email': 'own@example.test'})
              .then<Object?>((v) => v, onError: (Object e) => e);
          await ownArrived.future;
          final atStart = await peerStore.load();
          if (!peerGone) {
            peerRelease.complete();
            await peerReply;
          }
          ownRelease.complete();
          final result = await ownReply;
          if (peerGone) {
            peerRelease.complete();
            await peerReply;
          }
          expect(result is Map, isTrue);
          expect(await actorStore.read() == ownIssued, isTrue);
          final finalState = await device(root, origin).load();
          expect(atStart.attempts['signup']?.id == attempt, isTrue);
          expect(finalState.attempts['signup']?.id == attempt, isTrue);
          expect(
            atStart.authGeneration,
            observed.authGeneration + (peerGone ? 0 : 1),
          );
          expect(signupSends, 1);
          expect(signinSends, 2);
        },
      );
    }

    test('explicit authentication clears observed peer marks', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final original = credentials();
      final rotated = credentials(
        user: original.userId,
        session: original.sessionId,
      );
      final peerIssued = credentials();
      final ownIssued = credentials();
      final arrived = [Completer<void>(), Completer<void>()];
      final release = [Completer<void>(), Completer<void>()];
      addTearDown(() {
        for (final barrier in release) {
          if (!barrier.isCompleted) barrier.complete();
        }
      });
      var signins = 0;
      server.listen((request) async {
        await request.drain<void>();
        final index = signins++;
        arrived[index].complete();
        await release[index].future;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode((index == 0 ? peerIssued : ownIssued).toJson()),
        );
        await request.response.close();
      });
      final peer = device(root, origin);
      await peer.write(original);
      final files = FailWrite(2);
      final actor = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: files,
      );
      await actor.finishRefresh((await actor.claimRefresh(original))!, rotated);
      final peerClient = DeviceTransport(peer);
      final actorClient = DeviceTransport(actor);
      addTearDown(peerClient.close);
      addTearDown(actorClient.close);
      final peerReply = peerClient
          .invoke('auth.signin', {'email': 'peer@example.test'})
          .then<Object?>((value) => value, onError: (Object error) => error);
      await arrived[0].future;
      files.writeUnavailable = true;
      await actor.load();
      expect(await actor.read() == null, isTrue);
      final observed = await peer.load();
      expect(actor.transientState != null, isTrue);
      files.writeUnavailable = false;
      final ownReply = actorClient
          .invoke('auth.signin', {'email': 'own@example.test'})
          .then<Object?>((value) => value, onError: (Object error) => error);
      await arrived[1].future;
      final started = await peer.load();
      release[0].complete();
      await peerReply;
      final afterPeer = await peer.load();
      release[1].complete();
      final result = await ownReply;
      expect(
        started.authGeneration > observed.authGeneration &&
            started.session == null &&
            !started.refreshSent &&
            started.authTransitionId != observed.authTransitionId,
        isTrue,
      );
      expect(
        afterPeer.session == null &&
            afterPeer.authGeneration == started.authGeneration,
        isTrue,
      );
      expect(result is Map<String, Object?>, isTrue);
      expect(await actor.read() == ownIssued, isTrue);
      expect(actor.transientState, isNull);
      expect(signins, 2);
    });

    test('merge bounds retain committed storage and memory', () async {
      final root = await scratch();
      const origin = 'https://rejoin.example.test';
      final peer = device(root, origin);
      final now = DateTime.now().millisecondsSinceEpoch;
      DeviceAttempt attempt(String email) =>
          DeviceAttempt(randomId(), email, now);
      await peer.commit(await peer.load(), DeviceState(generation: 1));
      final actor = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: FailWrite(1),
      );
      await actor.commitAfterSuccess(
        await actor.load(),
        DeviceState(
          generation: 2,
          attempts: {'mine': attempt('mine@example.test')},
        ),
      );
      final current = await peer.load();
      await peer.commit(
        current,
        DeviceState(
          generation: 2,
          attempts: {
            for (var i = 0; i < 3; i++)
              'peer$i': attempt('peer$i@example.test'),
          },
        ),
      );
      final committed = jsonEncode((await peer.load()).toJson());
      final recovered = await actor.load();
      expect(recovered.attempts.containsKey('mine'), isTrue);
      expect(actor.transientState != null, isTrue);
      expect(jsonEncode((await peer.load()).toJson()) == committed, isTrue);
    });

    test(
      'three individually valid attempts can exceed the merged UTF-8 bound',
      () {
        final actor = MemoryDeviceStore(
          scope('https://${'a' * 5300}.example.test'),
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        DeviceAttempt attempt() =>
            DeviceAttempt(randomId(), String.fromCharCode(0x754c) * 300, now);
        final base = actor.prepareWrite(DeviceState(generation: 1));
        final memory = actor.prepareWrite(
          DeviceState(generation: 2, attempts: {'mine': attempt()}),
        );
        final current = actor.prepareWrite(
          DeviceState(
            generation: 2,
            attempts: {'peer1': attempt(), 'peer2': attempt()},
          ),
        );
        actor.lastPersistentState = base;
        actor.transientBaseAuthGeneration = base.authGeneration;
        actor.transientState = memory;
        expect(
          () => actor.prepareWrite(actor.reconcileRecovery(current, memory)),
          throwsA(
            isA<ClientException>().having(
              (e) => e.code,
              'code',
              'device_storage_full',
            ),
          ),
        );
        expect(actor.transientState!.attempts.containsKey('mine'), isTrue);
        expect(current.attempts.keys, ['peer1', 'peer2']);
      },
    );

    test('same screen recovery keeps the later surviving request', () async {
      for (final peerOrder in ['earlier', 'same', 'later']) {
        final root = await scratch();
        const origin = 'https://rejoin.example.test';
        final peer = device(root, origin);
        final actor = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: FailWrite(1),
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        final mine = DeviceAttempt(randomId(), 'mine@example.test', now - 2);
        final theirs = DeviceAttempt(
          randomId(),
          'peer@example.test',
          now -
              switch (peerOrder) {
                'earlier' => 3,
                'same' => 2,
                _ => 1,
              },
        );
        await actor.commitAfterSuccess(
          await actor.load(),
          DeviceState(generation: 1, attempts: {'same': mine}),
        );
        await peer.commit(
          await peer.load(),
          DeviceState(generation: 1, attempts: {'same': theirs}),
        );
        final recovered = await actor.load();
        expect(
          recovered.attempts['same']?.id ==
              (peerOrder == 'earlier' ? mine.id : theirs.id),
          isTrue,
        );
      }
    });
  }, skip: unsupportedPosix);

  test('native recovery orderings persist account changes and fence another object', () async {
    for (final baseAuth in [0, 1]) {
      for (final memoryAccount in [false, true]) {
        for (final recoveredRead in [false, true]) {
          for (final boundary in [
            'signin',
            'logout',
            'signin with peer attempt',
          ]) {
            final root = await scratch();
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final origin = 'http://127.0.0.1:${server.port}';
            final arrived = Completer<void>();
            final release = Completer<void>();
            var signups = 0;
            server.listen((request) async {
              await request.drain<void>();
              request.response.headers.contentType = ContentType.json;
              if (request.uri.path == '/auth.signin') {
                request.response.write(jsonEncode(credentials().toJson()));
              } else if (request.uri.path == '/auth.logout') {
                request.response.write('{}');
              } else {
                if (++signups == 2) {
                  arrived.complete();
                  await release.future;
                }
                request.response.write(
                  jsonEncode({'accepted': true, 'attempt': randomId()}),
                );
              }
              await request.response.close();
            });
            final observer = device(root, origin);
            await observer.commit(
              await observer.load(),
              DeviceState(generation: 1, authGeneration: baseAuth),
            );
            final files = FailWrite(1);
            final actorStore = NativeDeviceStore(
              scope(origin),
              directory: root,
              files: files,
            );
            final actor = DeviceTransport(actorStore);
            final pendingClient = DeviceTransport(device(root, origin));
            addTearDown(actor.close);
            addTearDown(pendingClient.close);
            await actor.invoke('auth.signup', {'email': 'actor@example.test'});
            files.readUnavailable = true;
            if (memoryAccount) {
              await actor.invoke('auth.signin', {
                'email': 'actor@example.test',
              });
            }
            expect(
              (await actorStore.load()).attempts.length,
              memoryAccount ? 0 : 1,
            );
            final pending = pendingClient.invoke('auth.signup', {
              'email': 'pending@example.test',
            });
            await arrived.future;
            files.readUnavailable = false;
            Object? peerAttempt;
            if (boundary == 'signin with peer attempt') {
              final peer = DeviceTransport(
                device(root, origin, screen: 'peer'),
              );
              addTearDown(peer.close);
              peerAttempt = (await peer.invoke('auth.signup', {
                'email': 'peer@example.test',
              }) as Map)['attempt'];
            }
            if (recoveredRead) await actorStore.load();
            await actor.invoke(
              boundary == 'logout' ? 'auth.logout' : 'auth.signin',
              boundary == 'logout' ? {} : {'email': 'actor@example.test'},
            );
            final durable = await observer.load();
            expect(durable.authGeneration, greaterThan(baseAuth));
            release.complete();
            final result = await pending as Map;
            expect(result['accepted'], isTrue);
            final restored = await observer.load();
            expect(restored.authGeneration, durable.authGeneration);
            expect(
              restored.attempts.values.any((a) => a.id == result['attempt']),
              isFalse,
            );
            expect(signups, peerAttempt == null ? 2 : 3);
            if (peerAttempt != null) {
              expect(restored.attempts['peer']?.id == peerAttempt, isTrue);
            }
          }
        }
      }
    }
  }, skip: unsupportedPosix);

  test('server success survives a runtime write failure in this run without resending', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final value = credentials();
    var signins = 0;
    var authenticated = false;
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth.signin') {
        signins++;
        request.response.write(jsonEncode(value.toJson()));
      } else {
        authenticated =
            request.headers.value('authorization') ==
            'Bearer ${value.accessToken}';
        request.response.write('{"accepted":true}');
      }
      await request.response.close();
    });
    final store = NativeDeviceStore(
      scope(origin),
      directory: root,
      files: UnavailableFiles(),
    );
    final client = DeviceTransport(store);
    addTearDown(client.close);
    await client.invoke('auth.signin', {'email': 'user@example.test'});
    await client.invoke('example.read', {});
    expect(
      signins == 1 && authenticated && await store.read() == value,
      isTrue,
    );
    expect(await device(root, origin).read() == null, isTrue);
  }, skip: unsupportedPosix);
  test('failed refreshed-session write retains memory and the durable unknown mark', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final original = credentials();
    final rotated = credentials(
      user: original.userId,
      session: original.sessionId,
    );
    final persistent = device(root, origin);
    await persistent.write(original);
    var sends = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth.refresh') {
        sends++;
        request.response.write(jsonEncode(rotated.toJson()));
      } else if (request.headers.value('authorization') ==
          'Bearer ${original.accessToken}') {
        request.response.statusCode = 401;
        request.response.write('{"error":"invalid_token"}');
      } else {
        request.response.write('{"accepted":true}');
      }
      await request.response.close();
    });
    final files = FailWrite(2)..blockReadsAfterFailure = true;
    final store = NativeDeviceStore(
      scope(origin),
      directory: root,
      files: files,
    );
    final client = DeviceTransport(store);
    addTearDown(client.close);
    await client.invoke('example.read', {});
    files.readUnavailable = true;
    await client.invoke('example.read', {});
    expect(sends == 1 && await store.read() == rotated, isTrue);
    expect((await persistent.load()).refreshSent, isTrue);
    await expectLater(
      persistent.read(),
      throwsA(
        isA<ClientException>().having((e) => e.code, 'code', 'session_changed'),
      ),
    );
    files.readUnavailable = false;
    expect(await store.read() == rotated, isTrue);
    expect((await persistent.load()).refreshSent, isFalse);
    expect(await persistent.read() == rotated, isTrue);
    expect(sends, 1);
  }, skip: unsupportedPosix);
  test(
    'pre-existing broad intermediate directory is rejected without chmod',
    () async {
      final root = await scratch();
      final store = device(
        root,
        'https://intermediate.example.test',
        app: 'app.${'x' * 120}',
      );
      final first = store.directory.substring(root.length + 1).split('/').first;
      final intermediate = Directory('$root/$first');
      await intermediate.create();
      await Process.run('/bin/chmod', [
        '755',
        intermediate.path,
      ], includeParentEnvironment: false);
      await expectLater(
        store.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect((await intermediate.stat()).mode & 0x3f, 0x2d);
    },
    skip: unsupportedPosix,
  );
  test('fourth successful signup stays usable in memory without eviction or resend', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final issued = <String>[];
    final confirmed = credentials();
    var signupCalls = 0;
    var resumed = false;
    server.listen((request) async {
      final input = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, Object?>;
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth.signup') {
        signupCalls++;
        final attempt = randomId();
        issued.add(attempt);
        request.response.write(
          jsonEncode({'accepted': true, 'attempt': attempt}),
        );
      } else {
        resumed = input['attempt'] == issued.last;
        request.response.write(jsonEncode(confirmed.toJson()));
      }
      await request.response.close();
    });
    for (var i = 0; i < 3; i++) {
      final client = DeviceTransport(device(root, origin, screen: 'screen-$i'));
      try {
        await client.invoke('auth.signup', {'email': 'user-$i@example.test'});
      } finally {
        client.close();
      }
    }
    final store = device(root, origin, screen: 'screen-3');
    final client = DeviceTransport(store);
    addTearDown(client.close);
    await client.invoke('auth.signup', {'email': 'fourth@example.test'});
    expect((await store.load()).attempts.length, 4);
    final persisted = await device(root, origin).load();
    expect(
      persisted.attempts.length == 3 &&
          persisted.attempts.values.every(
            (entry) => issued.take(3).contains(entry.id),
          ),
      isTrue,
    );
    await client.invoke('auth.verify_email', {
      'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
    });
    expect(
      resumed && signupCalls == 4 && await store.read() == confirmed,
      isTrue,
    );
    expect((await device(root, origin).load()).attempts.length, 3);
  }, skip: unsupportedPosix);
  test(
    'directory flush failure reconciles logout and preserves a newer login',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final issued = credentials();
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(request.uri.path == '/auth.signin' ? issued.toJson() : {}),
        );
        await request.response.close();
      });
      final store = NativeDeviceStore(
        scope(origin),
        directory: root,
        files: FailDirectorySyncOnce(),
      );
      final client = DeviceTransport(store);
      addTearDown(client.close);
      await client.invoke('auth.signin', {'email': 'user@example.test'});
      await client.invoke('auth.logout', {});
      expect(
        await device(root, origin).read() == null && await store.read() == null,
        isTrue,
      );

      final secondRoot = await scratch();
      final second = NativeDeviceStore(
        scope(origin),
        directory: secondRoot,
        files: FailDirectorySyncOnce(),
      );
      final secondClient = DeviceTransport(second);
      addTearDown(secondClient.close);
      await secondClient.invoke('auth.signin', {'email': 'user@example.test'});
      final newer = credentials();
      final external = device(secondRoot, origin);
      await external.write(newer);
      await expectLater(
        secondClient.invoke('auth.logout', {}),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      expect(await external.read() == newer, isTrue);
      await expectLater(
        second.read(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
    },
    skip: unsupportedPosix,
  );

  test('owner paths remain distinct after case folding', () async {
    final root = await scratch();
    final paths = <String>{};
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    var collision = false;
    for (final first in alphabet.split('')) {
      for (final second in alphabet.split('')) {
        final path = device(
          root,
          'https://case.example.test',
          app: 'app.a$first$second',
        ).directory.toLowerCase();
        if (!paths.add(path)) collision = true;
      }
    }
    expect(collision, isFalse);
  }, skip: unsupportedPosix);

  test(
    'future signup attempts are preserved while automatic selection waits',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final store = device(root, origin, screen: 'first');
      final attempt = DeviceAttempt(
        randomId(),
        'first@example.test',
        DateTime.now().millisecondsSinceEpoch,
      );
      final before = await store.load();
      await store.commit(
        before,
        DeviceState(generation: 1, attempts: {'first': attempt}),
      );
      final file = File('${store.directory}/auth.json');
      final fixture =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final auth = fixture['auth']! as Map<String, Object?>;
      final attempts = auth['attempts']! as Map<String, Object?>;
      final entry = attempts['first']! as Map<String, Object?>;
      final future = DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      entry['started_at'] = future;
      await file.writeAsString(jsonEncode(fixture));
      var autoSelected = false;
      server.listen((request) async {
        final input = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, Object?>;
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.send_verification_email') {
          autoSelected = input['attempt'] != null;
          request.response.write('{"accepted":true}');
        } else {
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': randomId()}),
          );
        }
        await request.response.close();
      });
      final firstClient = DeviceTransport(store);
      final secondClient = DeviceTransport(
        device(root, origin, screen: 'second'),
      );
      addTearDown(firstClient.close);
      addTearDown(secondClient.close);
      await firstClient.invoke('auth.send_verification_email', {});
      await secondClient.invoke('auth.signup', {
        'email': 'second@example.test',
      });
      final restored = await device(root, origin).load();
      expect(
        !autoSelected &&
            restored.attempts['first']?.id == attempt.id &&
            restored.attempts['first']?.startedAt == future &&
            restored.attempts.length == 2,
        isTrue,
      );
    },
    skip: unsupportedPosix,
  );

  test('FIFO records are rejected without waiting for a writer', () async {
    final root = await scratch();
    const origin = 'https://fifo.example.test';
    final store = device(root, origin);
    await store.load();
    final result = await Process.run('/usr/bin/mkfifo', [
      '-m',
      '600',
      '${store.directory}/auth.json',
    ], includeParentEnvironment: false);
    expect(result.exitCode, 0);
    expect(await child('fifo', root, origin), 0);
  }, skip: unsupportedPosix);

  test('Darwin stat symbols match each supported ABI', () {
    expect(posixStatSymbol(Abi.macosArm64), 'fstat');
    expect(posixStatSymbol(Abi.macosX64), r'fstat$INODE64');
  });
  test(
    'extended ACL grants are rejected and deny entries are preserved',
    () async {
      final root = await scratch();
      const origin = 'https://acl.example.test';
      final store = device(root, origin);
      final issued = credentials();
      await store.write(issued);
      final path = '${store.directory}/auth.json';
      final before = await File(path).readAsBytes();
      var result = await Process.run('/bin/chmod', [
        '+a',
        'everyone allow read',
        path,
      ], includeParentEnvironment: false);
      expect(result.exitCode, 0);
      await expectLater(
        store.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
      expect(
        base64Encode(before) == base64Encode(await File(path).readAsBytes()),
        isTrue,
      );
      await Process.run('/bin/chmod', [
        '-N',
        path,
      ], includeParentEnvironment: false);
      result = await Process.run('/bin/chmod', [
        '+a',
        'everyone deny execute',
        path,
      ], includeParentEnvironment: false);
      expect(result.exitCode, 0);
      expect(await store.read() == issued, isTrue);
      final uid = await Process.run('/usr/bin/id', [
        '-un',
      ], includeParentEnvironment: false);
      expect(uid.exitCode, 0);
      result = await Process.run('/bin/chmod', [
        '+a',
        'user:${(uid.stdout as String).trim()} allow read',
        path,
      ], includeParentEnvironment: false);
      expect(result.exitCode, 0);
      expect(await store.read() == issued, isTrue);
      final inherited = await scratch();
      result = await Process.run('/bin/chmod', [
        '+a',
        'everyone allow read,file_inherit,directory_inherit',
        inherited,
      ], includeParentEnvironment: false);
      expect(result.exitCode, 0);
      await expectLater(
        device(inherited, origin).load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_unavailable',
          ),
        ),
      );
    },
    skip: Platform.isMacOS ? false : 'Requires Darwin ACLs.',
  );
  test(
    'oversized valid JSON is rejected before the complete file is read',
    () async {
      final root = await scratch();
      const origin = 'https://oversize.example.test';
      final store = device(root, origin);
      await store.write(credentials());
      final file = File('${store.directory}/auth.json');
      final valid = await file.readAsString();
      await file.writeAsString(valid + (' ' * (128 * 1024)));
      final length = await file.length();
      final counter = CountingReads();
      final reader = NativeDeviceStore(
        store.scope,
        directory: root,
        files: counter,
      );
      await expectLater(
        reader.load(),
        throwsA(
          isA<ClientException>().having(
            (e) => e.code,
            'code',
            'device_storage_corrupt',
          ),
        ),
      );
      expect(await file.length(), length);
      expect(counter.bytesRead < length, isTrue);
    },
    skip: unsupportedPosix,
  );

  test('failed remote logout still clears local session and attempts across restart', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"server_error"}');
      await request.response.close();
    });
    final store = device(root, origin);
    await store.write(credentials());
    final before = await store.load();
    await store.commit(
      before,
      DeviceState(
        generation: before.generation + 1,
        authGeneration: before.authGeneration,
        session: before.session,
        attempts: {
          'signup': DeviceAttempt(
            randomId(),
            'pending@example.test',
            DateTime.now().millisecondsSinceEpoch,
          ),
        },
      ),
    );
    final client = DeviceTransport(store);
    addTearDown(client.close);
    await expectLater(
      client.invoke('auth.logout', {}),
      throwsA(isA<OperationError>().having((e) => e.status, 'status', 500)),
    );
    final after = await store.load();
    expect(after.session == null && after.attempts.isEmpty, isTrue);
    expect(await child('empty', root, origin), 0);
  }, skip: unsupportedPosix);

  test(
    'invalid successor or decreasing auth generations preserve the record',
    () async {
      final root = await scratch();
      const origin = 'https://generation.example.test';
      final store = device(root, origin);
      await store.write(credentials());
      final current = await store.load();
      final file = File('${store.directory}/auth.json');
      final bytes = await file.readAsBytes();
      for (final (generation, authGeneration) in [
        (current.generation, current.authGeneration),
        (current.generation + 2, current.authGeneration),
        (current.generation + 1, current.authGeneration - 1),
      ]) {
        await expectLater(
          store.commit(
            current,
            DeviceState(
              generation: generation,
              authGeneration: authGeneration,
              session: current.session,
            ),
          ),
          throwsA(
            isA<ClientException>().having(
              (e) => e.code,
              'code',
              'session_changed',
            ),
          ),
        );
      }
      expect(
        base64Encode(bytes) == base64Encode(await file.readAsBytes()),
        isTrue,
      );
    },
    skip: unsupportedPosix,
  );
  test('relative persistence directory is fixed at construction and empty is rejected', () async {
    final root = await scratch();
    expect(await child('relative', root, 'https://relative.example.test'), 0);
  }, skip: unsupportedPosix);
  for (final initiallySignedIn in [false, true]) {
    test(
      initiallySignedIn
          ? 'confirm keeps unrelated signup when installing a different account'
          : 'confirm retries local CAS and keeps a different-email signup without resend',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final issued = credentials();
        final a = randomId();
        final b = randomId();
        final started = Completer<void>();
        final release = Completer<void>();
        var verifies = 0;
        server.listen((request) async {
          final input = jsonDecode(
            await utf8.decoder.bind(request).join(),
          ) as Map<String, Object?>;
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth.signup') {
            request.response.write(
              jsonEncode({
                'accepted': true,
                'attempt': input['email'] == 'a@example.test' ? a : b,
              }),
            );
          } else {
            verifies++;
            started.complete();
            await release.future;
            request.response.write(jsonEncode(issued.toJson()));
          }
          await request.response.close();
        });
        final first = DeviceTransport(device(root, origin, screen: 'a'));
        final second = DeviceTransport(device(root, origin, screen: 'b'));
        addTearDown(first.close);
        addTearDown(second.close);
        if (initiallySignedIn) {
          await first.store.write(credentials());
        }
        await first.invoke('auth.signup', {'email': 'a@example.test'});
        final confirming = first.invoke('auth.verify_email', {
          'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
        });
        await started.future;
        await second.invoke('auth.signup', {'email': 'b@example.test'});
        release.complete();
        final result = await confirming;
        final state = await device(root, origin).load();
        expect(
          SessionCredentials.fromJson(result) == issued &&
              state.session == issued &&
              state.attempts.length == 1 &&
              state.attempts['b']?.id == b &&
              verifies == 1,
          isTrue,
        );
      },
      skip: unsupportedPosix,
    );
  }
  for (final boundary in ['logout', 'switch']) {
    test('late signup does not restore state after $boundary', () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final previous = credentials();
      final next = credentials();
      final attempt = randomId();
      final started = Completer<void>();
      final release = Completer<void>();
      var refreshes = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signup') {
          started.complete();
          await release.future;
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': attempt}),
          );
        } else if (request.uri.path == '/auth.signin') {
          request.response.write(jsonEncode(next.toJson()));
        } else if (request.uri.path == '/auth.logout') {
          request.response.write('{}');
        } else if (request.uri.path == '/auth.refresh') {
          refreshes++;
          request.response.statusCode = 401;
          request.response.write('{"error":"invalid_token"}');
        } else if (boundary == 'switch' &&
            request.headers.value('authorization') ==
                'Bearer ${next.accessToken}') {
          request.response.write('{"accepted":true}');
        } else {
          request.response.statusCode = 401;
          request.response.write('{"error":"unauthenticated"}');
        }
        await request.response.close();
      });
      final store = device(root, origin, screen: 'a');
      await store.write(previous);
      final first = DeviceTransport(store);
      final second = DeviceTransport(device(root, origin, screen: 'b'));
      addTearDown(first.close);
      addTearDown(second.close);
      final pending = first.invoke('auth.signup', {
        'email': 'late@example.test',
      });
      await started.future;
      if (boundary == 'logout') {
        await second.invoke('auth.logout', {});
      } else {
        await second.invoke('auth.signin', {'email': 'other@example.test'});
      }
      release.complete();
      final result = await pending as Map<String, Object?>;
      expect(
        result['accepted'] == true && result['attempt'] == attempt,
        isTrue,
      );
      final state = await device(root, origin).load();
      expect(
        state.attempts.isEmpty &&
            state.session == (boundary == 'logout' ? null : next),
        isTrue,
      );
      if (boundary == 'logout') {
        await expectLater(
          first.invoke('example.read', {}),
          throwsA(
            isA<OperationError>().having(
              (e) => e.code,
              'code',
              'unauthenticated',
            ),
          ),
        );
      } else {
        await first.invoke('example.read', {});
      }
      expect(refreshes, 0);
    }, skip: unsupportedPosix);
  }

  test(
    'consumed or removed confirm attempt is not reinstalled by a late result',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final issued = credentials();
      final attempt = randomId();
      final started = Completer<void>();
      final release = Completer<void>();
      var refreshes = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signup') {
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': attempt}),
          );
        } else if (request.uri.path == '/auth.verify_email') {
          started.complete();
          await release.future;
          request.response.write(jsonEncode(issued.toJson()));
        } else {
          if (request.uri.path == '/auth.refresh') refreshes++;
          request.response.statusCode = 401;
          request.response.write('{"error":"unauthenticated"}');
        }
        await request.response.close();
      });
      final store = device(root, origin, screen: 'a');
      final client = DeviceTransport(store);
      addTearDown(client.close);
      await client.invoke('auth.signup', {'email': 'a@example.test'});
      final pending = client.invoke('auth.verify_email', {
        'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
      });
      await started.future;
      final current = await store.load();
      final other = DeviceAttempt(
        randomId(),
        'b@example.test',
        DateTime.now().millisecondsSinceEpoch,
      );
      await store.commit(
        current,
        DeviceState.fromJson({
          ...current.toJson(),
          'generation': current.generation + 1,
          'attempts': {'b': other.toJson()},
        }),
      );
      release.complete();
      expect(SessionCredentials.fromJson(await pending) == issued, isTrue);
      final state = await device(root, origin).load();
      expect(
        state.session == null &&
            state.attempts.length == 1 &&
            state.attempts['b']?.id == other.id,
        isTrue,
      );
      await expectLater(
        client.invoke('example.read', {}),
        throwsA(
          isA<OperationError>().having(
            (e) => e.code,
            'code',
            'unauthenticated',
          ),
        ),
      );
      expect(refreshes, 0);
    },
    skip: unsupportedPosix,
  );

  test('fourth local conflict keeps confirm result in memory with no network replay', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final issued = credentials();
    final attempt = randomId();
    var verifies = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth.signup') {
        request.response.write(
          jsonEncode({'accepted': true, 'attempt': attempt}),
        );
      } else if (request.uri.path == '/auth.verify_email') {
        verifies++;
        request.response.write(jsonEncode(issued.toJson()));
      } else {
        request.response.write('{"accepted":true}');
      }
      await request.response.close();
    });
    final persistent = device(root, origin, screen: 'a');
    final seed = DeviceTransport(persistent);
    await seed.invoke('auth.signup', {'email': 'a@example.test'});
    seed.close();
    final churn = ChurningStore(persistent);
    final client = DeviceTransport(churn);
    addTearDown(client.close);
    final result = await client.invoke('auth.verify_email', {
      'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
    });
    await client.invoke('example.read', {});
    expect(
      SessionCredentials.fromJson(result) == issued &&
          await churn.read() == issued &&
          verifies == 1 &&
          churn.writes == 4,
      isTrue,
    );
    expect(
      await persistent.read() == null &&
          (await persistent.load()).attempts['a']?.id == attempt,
      isTrue,
    );
  }, skip: unsupportedPosix);

  test('late second confirmation keeps the installed session and removes its consumed attempt', () async {
    final root = await scratch();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final a = randomId();
    final b = randomId();
    final firstSession = credentials();
    final secondSession = credentials();
    final started = Completer<void>();
    final release = Completer<void>();
    var aCalls = 0;
    var bCalls = 0;
    server.listen((request) async {
      final input = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, Object?>;
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth.signup') {
        request.response.write(
          jsonEncode({
            'accepted': true,
            'attempt': input['email'] == 'a@example.test' ? a : b,
          }),
        );
      } else if (input['attempt'] == b) {
        bCalls++;
        started.complete();
        await release.future;
        request.response.write(jsonEncode(secondSession.toJson()));
      } else {
        aCalls++;
        request.response.write(jsonEncode(firstSession.toJson()));
      }
      await request.response.close();
    });
    final first = DeviceTransport(device(root, origin, screen: 'a'));
    final second = DeviceTransport(device(root, origin, screen: 'b'));
    addTearDown(first.close);
    addTearDown(second.close);
    await first.invoke('auth.signup', {'email': 'a@example.test'});
    await second.invoke('auth.signup', {'email': 'b@example.test'});
    final pendingB = second.invoke('auth.verify_email', {
      'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
    });
    await started.future;
    await first.invoke('auth.verify_email', {
      'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
    });
    release.complete();
    expect(
      SessionCredentials.fromJson(await pendingB) == secondSession,
      isTrue,
    );
    final state = await device(root, origin).load();
    expect(
      state.session == firstSession &&
          state.attempts.isEmpty &&
          aCalls == 1 &&
          bCalls == 1,
      isTrue,
    );
  }, skip: unsupportedPosix);

  test(
    'first install and a new session ID advance the local auth generation',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final first = credentials();
      final next = credentials(user: first.userId);
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode((calls == 1 ? first : next).toJson()),
        );
        await request.response.close();
      });
      final store = device(root, origin);
      final client = DeviceTransport(store);
      addTearDown(client.close);
      await client.invoke('auth.signin', {'email': 'a@example.test'});
      expect((await store.load()).toJson()['auth_generation'], 1);
      await client.invoke('auth.signin', {'email': 'a@example.test'});
      expect((await store.load()).toJson()['auth_generation'], 2);
      expect(await store.read() == next, isTrue);
    },
    skip: unsupportedPosix,
  );

  test(
    'same-session refresh retries after signup and preserves auth generation',
    () async {
      final root = await scratch();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final original = credentials();
      final refreshed = credentials(
        user: original.userId,
        session: original.sessionId,
      );
      final attempt = randomId();
      final started = Completer<void>();
      final release = Completer<void>();
      var sends = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth.signin') {
          request.response.write(jsonEncode(original.toJson()));
        } else if (request.uri.path == '/auth.signup') {
          request.response.write(
            jsonEncode({'accepted': true, 'attempt': attempt}),
          );
        } else if (request.uri.path == '/auth.refresh') {
          sends++;
          started.complete();
          await release.future;
          request.response.write(jsonEncode(refreshed.toJson()));
        } else if (request.headers.value('authorization') ==
            'Bearer ${refreshed.accessToken}') {
          request.response.write('{"accepted":true}');
        } else {
          request.response.statusCode = 401;
          request.response.write('{"error":"invalid_token"}');
        }
        await request.response.close();
      });
      final store = device(root, origin, screen: 'a');
      final first = DeviceTransport(store);
      final second = DeviceTransport(device(root, origin, screen: 'b'));
      addTearDown(first.close);
      addTearDown(second.close);
      await first.invoke('auth.signin', {'email': 'a@example.test'});
      final pending = first.invoke('example.read', {});
      await started.future;
      await second.invoke('auth.signup', {'email': 'b@example.test'});
      release.complete();
      await pending;
      final state = await store.load();
      expect(
        state.session == refreshed &&
            state.attempts['b']?.id == attempt &&
            state.toJson()['auth_generation'] == 1 &&
            sends == 1,
        isTrue,
      );
    },
    skip: unsupportedPosix,
  );
  for (final operation in ['auth.verify_email', 'auth.signin_with_code']) {
    test(
      '$operation email-code confirms without an attempt and clears matching attempts',
      () async {
        final root = await scratch();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final a = randomId();
        final b = randomId();
        final c = randomId();
        final issued = credentials();
        final started = Completer<void>();
        final release = Completer<void>();
        var matchingSignups = 0;
        var confirms = 0;
        var noAttempt = false;
        server.listen((request) async {
          final input = jsonDecode(
            await utf8.decoder.bind(request).join(),
          ) as Map<String, Object?>;
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth.signup') {
            final attempt = input['email'] == 'a@example.test'
                ? (matchingSignups++ == 0 ? a : b)
                : c;
            request.response.write(
              jsonEncode({'accepted': true, 'attempt': attempt}),
            );
          } else {
            confirms++;
            noAttempt = !input.containsKey('attempt');
            started.complete();
            await release.future;
            request.response.write(jsonEncode(issued.toJson()));
          }
          await request.response.close();
        });
        final store = device(root, origin, screen: 'a');
        final first = DeviceTransport(store);
        final second = DeviceTransport(device(root, origin, screen: 'b'));
        final other = DeviceTransport(device(root, origin, screen: 'c'));
        addTearDown(first.close);
        addTearDown(second.close);
        addTearDown(other.close);
        await first.invoke('auth.signup', {'email': 'a@example.test'});
        await other.invoke('auth.signup', {'email': 'c@example.test'});
        final pending = first.invoke(operation, {
          'email': 'a@example.test',
          'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
        });
        await started.future;
        await second.invoke('auth.signup', {'email': 'a@example.test'});
        final current = await store.load();
        final attempts = current.attempts.map(
          (key, value) => MapEntry(key, value.toJson()),
        )..remove('a');
        await store.commit(
          current,
          DeviceState.fromJson({
            ...current.toJson(),
            'generation': current.generation + 1,
            'attempts': attempts,
          }),
        );
        release.complete();
        expect(SessionCredentials.fromJson(await pending) == issued, isTrue);
        final state = await device(root, origin).load();
        expect(
          noAttempt &&
              confirms == 1 &&
              state.session == issued &&
              state.authGeneration == 1 &&
              state.attempts.length == 1 &&
              state.attempts['c']?.id == c,
          isTrue,
        );
      },
      skip: unsupportedPosix,
    );
  }
}

class FullFiles extends PosixFiles {
  @override
  void syncFile(int fd) => throw const ClientException('device_storage_full');
}

class UnavailableFiles extends PosixFiles {
  @override
  void syncFile(int fd) =>
      throw const ClientException('device_storage_unavailable');
}

class FailWrite extends PosixFiles {
  FailWrite(this.at);
  final int at;
  var writes = 0;
  bool readUnavailable = false;
  bool writeUnavailable = false;
  bool blockReadsAfterFailure = false;
  @override
  Uint8List? read(int dir, String name) {
    if (readUnavailable) {
      throw const ClientException('device_storage_unavailable');
    }
    return super.read(dir, name);
  }

  @override
  void syncFile(int fd) {
    if (++writes == at || writeUnavailable) {
      if (blockReadsAfterFailure) readUnavailable = true;
      throw const ClientException('device_storage_unavailable');
    }
    super.syncFile(fd);
  }
}

class FailDirectorySyncOnce extends PosixFiles {
  FailDirectorySyncOnce({this.at = 1});
  final int at;
  var syncs = 0;
  var failed = false;
  bool readUnavailable = false;
  @override
  Uint8List? read(int dir, String name) {
    if (readUnavailable) {
      throw const ClientException('device_storage_unavailable');
    }
    return super.read(dir, name);
  }

  @override
  void syncDirectory(int fd) {
    if (!failed && ++syncs == at) {
      failed = true;
      throw const ClientException('device_storage_unavailable');
    }
    super.syncDirectory(fd);
  }
}

class CountingReads extends PosixFiles {
  var bytesRead = 0;
  @override
  int readChunk(int fd, Pointer<Uint8> buffer, int length) {
    final count = super.readChunk(fd, buffer, length);
    if (count > 0) bytesRead += count;
    return count;
  }
}

class ChurningStore extends DeviceStore {
  ChurningStore(this.delegate) : super(delegate.scope);
  final NativeDeviceStore delegate;
  var writes = 0;
  @override
  String get coordinationKey => delegate.coordinationKey;
  @override
  Future<DeviceState> load() async {
    requireAvailable();
    return transientState ?? await delegate.load();
  }

  @override
  Future<bool> commit(DeviceState expected, DeviceState next) async {
    if (++writes > 8) throw StateError('Local retries were not bounded.');
    final current = await delegate.load();
    await delegate.commit(
      current,
      DeviceState.fromJson({
        ...current.toJson(),
        'generation': current.generation + 1,
      }),
    );
    return delegate.commit(expected, next);
  }
}

class UncertainAuthenticationStart extends FailWrite {
  UncertainAuthenticationStart() : super(2);
  bool failRecoveryThenCleanup = false;
  bool failCleanupSync = false;
  @override
  void syncFile(int fd) {
    if (failRecoveryThenCleanup) {
      failRecoveryThenCleanup = false;
      failCleanupSync = true;
      throw const ClientException('device_storage_unavailable');
    }
    super.syncFile(fd);
  }

  @override
  void syncDirectory(int fd) {
    if (failCleanupSync) {
      failCleanupSync = false;
      throw const ClientException('device_storage_unavailable');
    }
    super.syncDirectory(fd);
  }
}
