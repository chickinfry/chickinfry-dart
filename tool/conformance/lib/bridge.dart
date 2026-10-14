import 'package:chickinfry/chickinfry.dart';
// The coordinator injects these aliases in its owned package configuration.
import 'package:chickinfry_client_plain/chickinfry_client.dart' as plain;
import 'package:chickinfry_client_auth/chickinfry_client.dart' as auth;

import 'protocol.dart';

typedef Bridge = Future<Map<String, Object?>> Function(
  String operation,
  Map<String, Object?> input,
);

/// Selects only an explicit fixture; schema 2 currently supplies no selector.
Bridge createBridge(HttpTransport transport, {String fixture = 'plain'}) {
  if (fixture == 'plain') return plainBridge(plain.Client(transport));
  if (fixture == 'auth') return authBridge(auth.Client(transport));
  unimplemented();
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
