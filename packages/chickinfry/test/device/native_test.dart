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

        final store = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: outcome == 'mark write fails'
              ? (operation == 'auth.signin' ? FullFiles() : UnavailableFiles())
              : outcome == 'unsaved success'
              ? FailWrite(2)
              : null,
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
          if (outcome == 'unknown response') {
            retrying = true;
            final retryStore = NativeDeviceStore(
              scope(origin),
              directory: root,
              files: FailWrite(2),
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
      expect(
        (await store.load()).authGeneration == accepted.authGeneration + 1,
        isTrue,
      );
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
              authTransitionUnknown: state.authTransitionUnknown,
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
        final firstStore = NativeDeviceStore(
          scope(origin),
          directory: root,
          files: shared ? FailWrite(3) : null,
        );
        final first = DeviceTransport(firstStore);
        final secondStore = shared
            ? firstStore
            : NativeDeviceStore(
                scope(origin),
                directory: root,
                files: FailWrite(2),
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
    final store = NativeDeviceStore(
      scope(origin),
      directory: root,
      files: FailWrite(2),
    );
    final client = DeviceTransport(store);
    addTearDown(client.close);
    await client.invoke('example.read', {});
    await client.invoke('example.read', {});
    expect(sends == 1 && await store.read() == rotated, isTrue);
    expect((await persistent.load()).refreshSent, isTrue);
    await expectLater(
      persistent.read(),
      throwsA(
        isA<ClientException>().having((e) => e.code, 'code', 'session_changed'),
      ),
    );
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
    'non-successor generation writes are rejected without touching the record',
    () async {
      final root = await scratch();
      const origin = 'https://generation.example.test';
      final store = device(root, origin);
      await store.write(credentials());
      final current = await store.load();
      final file = File('${store.directory}/auth.json');
      final bytes = await file.readAsBytes();
      for (final generation in [current.generation, current.generation + 2]) {
        await expectLater(
          store.commit(
            current,
            DeviceState(
              generation: generation,
              authGeneration: current.authGeneration,
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
  @override
  Uint8List? read(int dir, String name) {
    if (readUnavailable) {
      throw const ClientException('device_storage_unavailable');
    }
    return super.read(dir, name);
  }

  @override
  void syncFile(int fd) {
    if (++writes == at) {
      throw const ClientException('device_storage_unavailable');
    }
    super.syncFile(fd);
  }
}

class FailDirectorySyncOnce extends PosixFiles {
  var failed = false;
  @override
  void syncDirectory(int fd) {
    if (!failed) {
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
