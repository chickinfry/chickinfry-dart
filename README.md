# Chickinfry Dart

**Status: in development.** The runtime is not published to pub.dev yet, and
Dart is not marked as a supported language until verification is complete.
Until publication, use path dependencies as shown below.

`chickinfry` supplies HTTP transport and session handling for Chickinfry generated
clients. It uses HTTPS or an explicit loopback HTTP origin.

For local development, add the runtime to your application's `pubspec.yaml`:

```yaml
dependencies:
  chickinfry:
    path: ../chickinfry-dart/packages/chickinfry
```

Run `dart pub get`, then pass a transport to your generated client:

```dart
import 'package:chickinfry/chickinfry.dart';

final transport = HttpTransport('https://api.example.com');
```

Use `transport.withBearer(token)` or `transport.withSession(sessions)` for an
authenticated copy. Close the original transport when the application finishes.
Copies share its connections; closing a copy does not close the original.

The application supplies a `SessionStore`. Successful login results are saved
explicitly with `sessions.write(SessionCredentials.fromJson(result.toJson()))`.
After a successful generated logout call, clear only the session that was used:

```dart
Future<void> logout(ClientTransport client, SessionStore sessions) async {
  final expected = await sessions.read();
  await client.invoke('auth.logout', {});
  final latest = await sessions.read();
  if (latest != null &&
      latest.userId == expected?.userId &&
      latest.sessionId == expected?.sessionId) {
    await sessions.compareAndSet(latest, null);
  }
}
```

Stores for the same physical record must return the same `coordinationKey` and
serialize writes and conditional replacements. Concurrent refresh is coordinated
within one Dart isolate; concurrent refresh across isolates or processes is
unsupported. After a refresh with an unknown outcome, automatic refresh for that
credential remains suspended in that isolate until a different credential is read.
Store read failures preserve the record and fail the call.

Native Dart is the current execution boundary. Flutter Web and browser targets
are not supported yet. Public types remain importable and compile for the web,
but `HttpTransport.invoke` fails with `unsupported_platform` before any network
request. Use a native platform for now. Requests have a 30-second default
deadline, a 4 MiB UTF-8 request limit and a 1 MiB response limit. Redirects are
rejected. Server errors preserve their code and HTTP status through
`OperationError`; local failures use
`ClientException`.

Proxy connections preserve SDK routing and caller deadlines; connection/TLS socket cancellation remains SDK-managed.
