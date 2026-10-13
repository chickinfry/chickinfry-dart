import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_flutter/chickinfry_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

SessionCredentials credentials(String token) => SessionCredentials(
  accessToken: token * 43,
  refreshToken: token.toUpperCase() * 43,
  expiresAt: '2026-01-01T00:00:00Z',
  refreshExpiresAt: '2026-01-08T00:00:00Z',
  userId: 'native-test-user',
  sessionId: 'native-test-session',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Keychain reopen, runtime refresh and logout isolate one origin',
    (tester) async {
      const channel = 'plugins.it_nomads.com/flutter_secure_storage';
      final messenger = binding.defaultBinaryMessenger;
      // Forward to the real plugin; expose only numeric OSStatus diagnostics.
      messenger.setMockMessageHandler(channel, (message) async {
        final reply = await messenger.delegate.send(channel, message);
        if (reply != null) {
          try {
            const StandardMethodCodec().decodeEnvelope(reply);
          } on PlatformException catch (error) {
            if (error.details is int) {
              debugPrint('Keychain OSStatus: ${error.details}');
            }
          }
        }
        return reply;
      });
      addTearDown(() => messenger.setMockMessageHandler(channel, null));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final otherOrigin = 'https://session-test-${server.port}.example.invalid';
      final original = credentials('a');
      final refreshed = credentials('b');
      var refreshes = 0;
      var logouts = 0;
      server.listen((request) async {
        final input = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/auth.refresh':
            expect(input, {'refresh_token': original.refreshToken});
            refreshes++;
            request.response.write(jsonEncode(refreshed.toJson()));
          case '/auth.logout':
            expect(
              request.headers.value('authorization'),
              'Bearer ${refreshed.accessToken}',
            );
            logouts++;
            request.response.write('{}');
          default:
            if (request.headers.value('authorization') ==
                'Bearer ${original.accessToken}') {
              request.response.statusCode = 401;
              request.response.write('{"error":"invalid_token"}');
            } else {
              expect(
                request.headers.value('authorization'),
                'Bearer ${refreshed.accessToken}',
              );
              request.response.write('{}');
            }
        }
        await request.response.close();
      });
      final transport = HttpTransport(origin);
      final store = SecureSessionStore(origin);
      final other = SecureSessionStore(otherOrigin);
      addTearDown(() async {
        transport.close();
        await server.close(force: true);
      });

      expect(await store.read(), isNull);
      expect(await other.read(), isNull);
      addTearDown(() async {
        await store.compareAndSet(original, null);
        await store.compareAndSet(refreshed, null);
        await other.compareAndSet(original, null);
      });
      await store.write(original);
      await other.write(original);
      final reopened = SecureSessionStore(origin);
      expect(await reopened.read(), original);
      final client = transport.withSession(reopened);
      await client.invoke('account.get_status', {});
      expect(refreshes, 1);
      expect(await SecureSessionStore(origin).read(), refreshed);
      await client.invoke('auth.logout', {});
      expect(logouts, 1);
      expect(await reopened.compareAndSet(refreshed, null), isTrue);
      expect(await SecureSessionStore(origin).read(), isNull);
      expect(await other.read(), original);
    },
  );
}
