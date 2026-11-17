import 'dart:convert';
import 'dart:io';

import 'package:chickinfry_conformance/credentials.dart';
import 'package:chickinfry_conformance/driver.dart';
import 'package:chickinfry_conformance/protocol.dart';
import 'package:test/test.dart';

import 'driver_test.dart' show args, handshake;

void main() {
  test(
    'required verification uses the generated SDK and latest signup',
    () async {
      final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => peer.close(force: true));
      final requests = <Map<String, Object?>>[];
      var signups = 0;
      final session = {
        'access_token': 'a' * 43,
        'refresh_token': 'r' * 43,
        'expires_at': '2099-01-01T00:00:00Z',
        'refresh_expires_at': '2099-02-01T00:00:00Z',
        'user_id': '00000000-0000-4000-8000-000000000003',
        'session_id': '00000000-0000-4000-8000-000000000004',
        'email_verified': true,
      };
      peer.listen((request) async {
        final input = object(
          jsonDecode(await utf8.decoder.bind(request).join()),
        );
        requests.add(input);
        final Object output;
        switch (request.uri.path) {
          case '/auth.signup':
            signups++;
            output = {'accepted': true, 'attempt': 'attempt-$signups'};
          case '/auth.logout':
            output = {'status': 'ok'};
          case '/auth.send_verification_email':
            expect(input, {'attempt': 'attempt-2'});
            output = {'accepted': true};
          case '/auth.verify_email':
            expect(
              input['attempt'],
              input['code'] == '654321' ? 'other-attempt' : 'attempt-$signups',
            );
            if (input['code'] == '000000') {
              request.response.statusCode = 400;
              output = {'error': 'invalid_code'};
            } else if (input['code'] == '222222') {
              output = {'email_verified': true};
            } else {
              output = session;
            }
          case '/auth.signin':
            final email = input['email'];
            if (email == 'pending@example.test' ||
                email == 'unverified@example.test') {
              request.response.statusCode = email == 'pending@example.test'
                  ? 401
                  : 403;
              output = {
                'error': email == 'pending@example.test'
                    ? 'invalid_credentials'
                    : 'email_not_verified',
              };
            } else {
              output = session;
            }
          default:
            throw StateError('Unexpected operation.');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(output));
        await request.response.close();
      });
      final credentials = Credentials();
      final driver = Driver(credentials, (_, _) async => {})
        ..handshake(handshake);
      addTearDown(driver.dispose);
      await driver.handle(
        'c:create',
        'client.create',
        args({
          'clientRef': 'client',
          'fixture': 'requiredAuth',
          'origin': 'http://127.0.0.1:${peer.port}',
          'requestTimeoutMs': 1000,
        }),
      );
      var sequence = 0;
      Future<Map<String, Object?>> call(
        String operation,
        Map<String, Object?> input, {
        bool tokens = false,
      }) => driver.handle(
        'c:call:${sequence++}',
        'client.call',
        args({
          'clientRef': 'client',
          'operation': operation,
          'input': input,
          if (tokens)
            'outputRefs': {
              'access_token': 'access:$sequence',
              'refresh_token': 'refresh:$sequence',
            },
        }),
      );
      Future<void> failure(
        String operation,
        Map<String, Object?> input,
        String code,
        int? status,
      ) async {
        await expectLater(
          call(operation, input),
          throwsA(
            isA<SdkFailure>()
                .having((e) => e.payload['code'], 'code', code)
                .having((e) => e.payload['httpStatus'], 'status', status),
          ),
        );
      }

      await failure(
        'auth.verify_email',
        {'code': '123456'},
        'invalid_argument',
        null,
      );
      expect(requests, isEmpty);
      for (var i = 1; i <= 2; i++) {
        final result = await call('auth.signup', {
          'email': 'person-$i@example.test',
          'password': 'test password',
        });
        expect(result['output'], {'accepted': true, 'attempt': 'attempt-$i'});
      }
      await failure(
        'auth.signin',
        {'email': 'pending@example.test', 'password': 'test password'},
        'invalid_credentials',
        401,
      );
      expect((await call('auth.send_verification_email', {}))['output'], {
        'accepted': true,
      });
      await call('auth.verify_email', {
        'attempt': 'other-attempt',
        'code': '654321',
      }, tokens: true);
      await failure(
        'auth.verify_email',
        {'code': '000000'},
        'invalid_code',
        400,
      );
      await failure('auth.verify_email', {'code': '222222'}, 'internal', null);
      for (final operation in ['auth.verify_email', 'auth.signin']) {
        final result = await call(
          operation,
          operation == 'auth.verify_email'
              ? {'code': '123456'}
              : {'email': 'verified@example.test', 'password': 'test password'},
          tokens: true,
        );
        expect(object(result['output'])['email_verified'], true);
        expect(object(result['output'])['session_id'], session['session_id']);
        expect(
          object(result['credentialRefs']).keys,
          unorderedEquals(['access_token', 'refresh_token']),
        );
        expect(credentials.exposes(result), false);
      }
      await failure(
        'auth.signin',
        {'email': 'unverified@example.test', 'password': 'test password'},
        'email_not_verified',
        403,
      );
      final before = requests.length;
      await failure(
        'auth.verify_email',
        {
          'code': '123456',
          'email': 'user@example.test',
          'attempt': 'attempt-2',
        },
        'invalid_argument',
        null,
      );
      await failure(
        'auth.verify_email',
        {'code': '123456'},
        'invalid_argument',
        null,
      );
      expect(requests.length, before);
      for (final action in [
        'same-email-signin',
        'other-email-signin',
        'auth.logout',
      ]) {
        await call('auth.signup', {
          'email': 'cleanup@example.test',
          'password': 'test password',
        });
        await call(
          action == 'auth.logout' ? action : 'auth.signin',
          action != 'auth.logout'
              ? {
                  'email': action == 'same-email-signin'
                      ? ' CLEANUP@example.test '
                      : 'other-account@example.test',
                  'password': 'test password',
                }
              : {},
        );
        final afterAction = requests.length;
        if (action == 'other-email-signin') {
          await call('auth.verify_email', {'code': '123456'}, tokens: true);
          expect(requests.length, afterAction + 1);
        } else {
          await failure(
            'auth.verify_email',
            {'code': '123456'},
            'invalid_argument',
            null,
          );
          expect(requests.length, afterAction);
        }
      }
    },
  );

  test(
    'the sealed target rejects email and attempt together at compile time',
    () async {
      final dir = await Directory.systemTemp.createTemp('dart-both-targets-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await File('test/reject_both_targets.dart.invalid')
          .copy('${dir.path}/both.dart');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          source.path,
        ],
        environment: {
          for (final key in ['HOME', 'PATH', 'TMPDIR', 'LANG'])
            if (Platform.environment[key] case final value?) key: value,
        },
        includeParentEnvironment: false,
      );
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains("No named parameter with the name 'email'"),
      );
    },
  );
}
