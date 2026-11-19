import 'package:chickinfry/chickinfry.dart';
// The coordinator injects these aliases in its owned package configuration.
import 'package:chickinfry_client_plain/chickinfry_client.dart' as plain;
import 'package:chickinfry_client_auth/chickinfry_client.dart' as auth;
import 'package:chickinfry_client_required_auth/chickinfry_client.dart'
    as required_auth;

import 'package:chickinfry_client_empty_session/chickinfry_client.dart'
    as empty_session;

import 'protocol.dart';

typedef Bridge = Future<Map<String, Object?>> Function(
  String operation,
  Map<String, Object?> input,
);

/// Selects the generated SDK only from the explicit fixture identifier.
(T, Bridge) createBridge<T extends Transport>(
  T Function() createTransport, {
  required String fixture,
}) {
  final factory = switch (fixture) {
    'plain' => (Transport transport) => plainBridge(
      plain.createClient(transport),
    ),
    'auth' => (Transport transport) => authBridge(auth.createClient(transport)),
    'requiredAuth' => (Transport transport) => requiredAuthBridge(
      required_auth.createClient(transport),
    ),
    'emptySession' => (Transport transport) => emptySessionBridge(
      empty_session.createClient(transport),
    ),
    _ => invalidArgs(),
  };
  final transport = createTransport();
  return (transport, factory(transport));
}

Bridge plainBridge(plain.Client client) => (operation, input) async {
  switch (operation) {
    case 'probe.echo':
      final output = await client.probe.echo(
        plain.ProbeEchoInput(wireValue: string(input, 'wire_value')),
      );
      return {'wire_value': output.wireValue, 'observed_at': output.observedAt};
    case 'probe.list':
      final output = await client.probe.list(const plain.ProbeListInput());
      return {
        'rows': [
          for (final row in output.rows)
            {
              'id': row.id,
              'wire_value': row.wireValue,
              'observed_at': row.observedAt,
            },
        ],
      };
    default:
      unimplemented();
  }
};

Bridge requiredAuthBridge(
  required_auth.Client client,
) => (operation, input) async {
  if (input.containsKey('email') && input.containsKey('attempt')) {
    throw const ClientError('invalid_argument');
  }
  switch (operation) {
    case 'auth.signup':
      final output = await client.auth.signup(
        required_auth.AuthSignupInput(
          email: string(input, 'email'),
          password: string(input, 'password'),
        ),
      );
      return {'accepted': output.accepted, 'attempt': output.attempt};
    case 'auth.send_verification_email':
      final output = await client.auth.sendVerificationEmail(
        required_auth.AuthSendVerificationEmailInput(
          target: input.containsKey('attempt')
              ? required_auth
                    .AuthSendVerificationEmailInputTargetChoice.attempt(
                  string(input, 'attempt'),
                )
              : input.containsKey('email')
              ? required_auth.AuthSendVerificationEmailInputTargetChoice.email(
                  string(input, 'email'),
                )
              : null,
        ),
      );
      return {'accepted': output.accepted};
    case 'auth.verify_email':
      final output = await client.auth.verifyEmail(
        required_auth.AuthVerifyEmailInput(
          code: string(input, 'code'),
          target: input.containsKey('attempt')
              ? required_auth.AuthVerifyEmailInputTargetChoice.attempt(
                  string(input, 'attempt'),
                )
              : input.containsKey('email')
              ? required_auth.AuthVerifyEmailInputTargetChoice.email(
                  string(input, 'email'),
                )
              : null,
        ),
      );
      return {
        'email_verified': output.emailVerified,
        'access_token': output.accessToken,
        'refresh_token': output.refreshToken,
        'expires_at': output.expiresAt,
        'refresh_expires_at': output.refreshExpiresAt,
        'user_id': output.userId,
        'session_id': output.sessionId,
      };
    case 'auth.signin':
      final output = await client.auth.signin(
        required_auth.AuthSigninInput(
          email: string(input, 'email'),
          password: string(input, 'password'),
        ),
      );
      return {
        'email_verified': output.emailVerified,
        'access_token': output.accessToken,
        'refresh_token': output.refreshToken,
        'expires_at': output.expiresAt,
        'refresh_expires_at': output.refreshExpiresAt,
        'user_id': output.userId,
        'session_id': output.sessionId,
      };
    case 'auth.logout':
      final output = await client.auth.logout(
        const required_auth.AuthLogoutInput(),
      );
      return {'status': output.status};
    default:
      unimplemented();
  }
};

Bridge authBridge(auth.Client client) => (operation, input) async {
  switch (operation) {
    case 'probe.echo':
      final output = await client.probe.echo(
        auth.ProbeEchoInput(wireValue: string(input, 'wire_value')),
      );
      return {'wire_value': output.wireValue, 'observed_at': output.observedAt};
    case 'probe.list':
      final output = await client.probe.list(const auth.ProbeListInput());
      return {
        'rows': [
          for (final row in output.rows)
            {
              'id': row.id,
              'wire_value': row.wireValue,
              'observed_at': row.observedAt,
            },
        ],
      };
    case 'auth.refresh':
      final output = await client.auth.refresh(
        auth.AuthRefreshInput(refreshToken: string(input, 'refresh_token')),
      );
      return {
        'access_token': output.accessToken,
        'refresh_token': output.refreshToken,
        'expires_at': output.expiresAt,
        'refresh_expires_at': output.refreshExpiresAt,
        'user_id': output.userId,
        'session_id': output.sessionId,
      };
    default:
      unimplemented();
  }
};

Bridge emptySessionBridge(
  empty_session.Client client,
) => (operation, input) async {
  switch (operation) {
    case 'auth.signin':
      final output = await client.auth.signin(
        empty_session.AuthSigninInput(
          email: string(input, 'email'),
          password: string(input, 'password'),
        ),
      );
      return {
        'email_verified': output.emailVerified,
        'access_token': output.accessToken,
        'refresh_token': output.refreshToken,
        'expires_at': output.expiresAt,
        'refresh_expires_at': output.refreshExpiresAt,
        'user_id': output.userId,
        'session_id': output.sessionId,
      };
    case 'auth.logout':
      final output = await client.auth.logout(
        const empty_session.AuthLogoutInput(),
      );
      return {'status': output.status};
    case 'probe.echo':
      final output = await client.probe.echo(
        empty_session.ProbeEchoInput(wireValue: string(input, 'wire_value')),
      );
      return {'wire_value': output.wireValue, 'observed_at': output.observedAt};
    case 'probe.list':
      final output = await client.probe.list(
        const empty_session.ProbeListInput(),
      );
      return {
        'rows': [
          for (final row in output.rows)
            {
              'id': row.id,
              'wire_value': row.wireValue,
              'observed_at': row.observedAt,
            },
        ],
      };
    default:
      unimplemented();
  }
};
