# Chickinfry Dart

**Status: in development.** The runtime is not published to pub.dev yet, and
Dart is not marked as a supported language until verification is complete.
Until publication, use path dependencies as shown below.

`chickinfry` supplies HTTP transport and session handling for Chickinfry generated
clients. It uses HTTPS or an explicit loopback HTTP origin.

[`chickinfry_flutter`](packages/chickinfry_flutter) adds OS-backed session storage for native Flutter apps; see its platform verification table.

## Install and first call

Generate your project's Dart client SDK and make your first call:

1. Add `dart` to `generation.clients` in `chik/project.yml` and run `chik generate`.
   The SDK is generated at `client/generated/dart` as the `chickinfry_client` package.
2. Add the generated SDK to your app's `pubspec.yaml`:

```yaml
dependencies:
  chickinfry_client:
    path: ../my-project/client/generated/dart
```

3. `chickinfry` is not published to pub.dev yet, so resolve it from a local
   checkout. Create `pubspec_overrides.yaml` next to your app's `pubspec.yaml`
   (this file is yours; `chik generate` does not overwrite it) and adjust the
   path to your checkout:

```yaml
dependency_overrides:
  chickinfry:
    path: ../../chickinfry-dart/packages/chickinfry
```

4. Run `dart pub get`, then make the first call:

```dart
import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_client/chickinfry_client.dart';

Future<void> main() async {
  final transport = HttpTransport('https://api.example.com');
  final client = Client(transport);
  final result = await client.accountStatus.getStatus(
    AccountStatusGetStatusInput(/* required fields */),
  );
  print(result);
  transport.close();
}
```

On native targets, use `transport.withBearer(token)` or
`transport.withSession(sessions)` for an authenticated copy. Close the original transport when the application finishes.
Copies share its connections; closing a copy does not close the original.

The application supplies a `SessionStore`. Successful login results are saved
explicitly with `sessions.write(SessionCredentials.fromJson(result.toJson()))`.
Send logout with the captured session credentials, then clear only that session:

```dart
Future<void> logout(HttpTransport transport, SessionStore sessions) async {
  final expected = await sessions.read();
  if (expected == null) return;
  await transport.withBearer(expected.accessToken).invoke('auth.logout', {});
  final latest = await sessions.read();
  if (latest != null &&
      latest.userId == expected.userId &&
      latest.sessionId == expected.sessionId) {
    await sessions.compareAndSet(latest, null);
  }
}
```

Pass the transport for the store's origin. `withBearer` pins this request to the
captured session, even if the transport already uses `withSession` and a new
login is saved before sending. It deliberately disables automatic refresh:
an expired access token returns `OperationError('invalid_token', 401)` to the
caller and leaves the stored record intact. Handle that error by asking the user
to authenticate again; do not retry this logout through `withSession`, which
could select a different login. Other request failures also preserve the record.
A rejected request does not confirm server logout.

Stores for the same physical record must return the same `coordinationKey` and
serialize writes and conditional replacements. Concurrent refresh is coordinated
within one Dart isolate; concurrent refresh across isolates or processes is
unsupported. After a refresh with an unknown outcome, automatic refresh for that
credential remains suspended in that isolate until a different credential is read.
Store read failures preserve the record and fail the call.

Native Dart supports bearer credentials and session stores. Browser Fetch
uses cookies only, as described below. Requests have a 30-second default deadline, a 4 MiB UTF-8 request limit and a 1 MiB response limit. Redirects are
rejected. Server errors preserve their code and HTTP status through
`OperationError`; local failures use
`ClientException`.

Proxy connections preserve SDK routing and caller deadlines; connection/TLS socket cancellation remains SDK-managed.

## Browser transport preview

`HttpTransport` selects cookie-only Fetch in browsers. Pass an explicit server
origin; default web paths and generated browser authentication entry points are
not finalized. Requests use JSON POST, credentials inclusion, no-store caching,
and manual redirect rejection. Native bearer and session-store attachment are
rejected in browsers, without a fallback. Do not use native generated login
result decoders for browser session responses.

The browser does not refresh, replay business operations, or log out on 401/403.
Applications handle 401 by requesting sign-in and 403 as an authorization error.
The SDK never reads or persists the authentication cookie. Browser authentication
helpers remain internal while their generated API names are being settled.

The real browser fixture is `packages/chickinfry/tool/test_browser.dart`.
It accepts an existing scratch directory for compiled restore-page assets and
uses `CHROME_EXECUTABLE` to select an installed Chrome. No browser is installed.

Strict cookies require an IP loopback test-page origin as well as an IP loopback
API origin. The installed `package:test` runner advertises `localhost` for both
its host and suite pages, without a host option. Local verification uses an
isolated package configuration pointing at a scratch copy of Shelf whose
loopback URL advertises `127.0.0.1`. This is a local test harness, not the product
or CI path; leave the package cache, lockfile, browser security, and cookie
attributes unchanged.

```sh
cd packages/chickinfry
CHROME_EXECUTABLE=/path/to/chrome dart --packages=/path/to/ip-loopback/package_config.json tool/test_browser.dart /path/to/scratch
```

This fixture does not certify a deployed server, generated browser SDK, or
production ingress.
