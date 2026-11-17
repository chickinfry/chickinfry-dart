import 'dart:async';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/signup.dart';
import 'package:test/test.dart';

final class _Transport implements ClientTransport {
  _Transport(this.call);
  final Future<Object?> Function(String, Map<String, Object?>) call;

  @override
  Future<Object?> invoke(String operation, Map<String, Object?> input) =>
      call(operation, input);
}

void main() {
  for (final newerEmail in [' PERSON@example.test ', 'other@example.test']) {
    test(
      'verification clears a newer binding only for the same email: $newerEmail',
      () async {
        final verified = Completer<Object?>();
        var signups = 0;
        var requests = 0;
        Map<String, Object?>? verification;
        final binding = SignupBinding(
          _Transport((operation, input) async {
            requests++;
            if (operation == 'auth.signup') {
              return {'accepted': true, 'attempt': 'attempt-${++signups}'};
            }
            if (input['code'] == '123456') return verified.future;
            verification = input;
            return {'status': 'ok'};
          }),
        );
        await binding.invoke('auth.signup', {'email': 'person@example.test'});
        final pending = binding.invoke('auth.verify_email', {'code': '123456'});
        await binding.invoke('auth.signup', {'email': newerEmail});
        verified.complete({'status': 'ok'});
        await pending;
        final before = requests;
        if (newerEmail.trim().toLowerCase() == 'person@example.test') {
          await expectLater(
            binding.invoke('auth.verify_email', {'code': '654321'}),
            throwsA(
              isA<ClientError>().having(
                (e) => e.code,
                'code',
                'invalid_argument',
              ),
            ),
          );
          expect(requests, before);
        } else {
          await binding.invoke('auth.verify_email', {'code': '654321'});
          expect(verification, {'attempt': 'attempt-2', 'code': '654321'});
        }
      },
    );
  }
  for (final action in [
    'auth.logout',
    'auth.signin',
    'auth.verify_email',
    'verify-email',
  ]) {
    test('late signup cannot restore the binding after $action', () async {
      final late = Completer<Object?>();
      var signups = 0;
      var requests = 0;
      final binding = SignupBinding(
        _Transport((operation, input) async {
          requests++;
          if (operation == 'auth.signup') {
            signups++;
            if (signups == 1) return {'accepted': true, 'attempt': 'first'};
            return late.future;
          }
          return {'status': 'ok'};
        }),
      );
      await binding.invoke('auth.signup', {'email': 'person@example.test'});
      final pending = binding.invoke('auth.signup', {
        'email': 'person@example.test',
      });
      await binding.invoke(
        action == 'verify-email' ? 'auth.verify_email' : action,
        action == 'auth.verify_email'
            ? {'code': '123456'}
            : {
                'email': ' PERSON@example.test ',
                if (action == 'verify-email') 'code': '123456',
              },
      );
      late.complete({'accepted': true, 'attempt': 'late'});
      await pending;
      final before = requests;
      await expectLater(
        binding.invoke('auth.verify_email', {'code': '123456'}),
        throwsA(
          isA<ClientError>().having((e) => e.code, 'code', 'invalid_argument'),
        ),
      );
      expect(requests, before);
    });
  }
  test('signin keeps an outstanding signup for another email', () async {
    final late = Completer<Object?>();
    Map<String, Object?>? verification;
    final binding = SignupBinding(
      _Transport((operation, input) async {
        if (operation == 'auth.signup') return late.future;
        if (operation == 'auth.verify_email') verification = input;
        return {'status': 'ok'};
      }),
    );
    final pending = binding.invoke('auth.signup', {
      'email': 'pending@example.test',
    });
    await binding.invoke('auth.signin', {'email': 'other@example.test'});
    late.complete({'accepted': true, 'attempt': 'pending'});
    await pending;
    await binding.invoke('auth.verify_email', {'code': '123456'});
    expect(verification, {'attempt': 'pending', 'code': '123456'});
  });
}
