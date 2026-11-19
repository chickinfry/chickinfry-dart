# chickinfry_flutter

**Status: not yet supported (preview). APIs may change before support is announced.**

`SecureSessionStore` implements the Dart runtime's `SessionStore` using OS secure
storage. The package and runtime are not published yet. Use local paths:

```yaml
dependencies:
  chickinfry:
    path: ../../chickinfry-dart/packages/chickinfry
  chickinfry_flutter:
    path: ../../chickinfry-dart/packages/chickinfry_flutter
  chickinfry_client:
    path: ../generated/dart
```

The generated client uses a runtime version dependency. Until publication, also
put the runtime path in the consuming app's `pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  chickinfry:
    path: ../../chickinfry-dart/packages/chickinfry
```

Run `flutter pub get`. Initialize Flutter before reading or writing:

```dart
import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_client/chickinfry_client.dart';
import 'package:chickinfry_flutter/chickinfry_flutter.dart';
import 'package:flutter/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const origin = 'https://api.example.com';
  final sessions = SecureSessionStore(origin);
  final transport = HttpTransport(origin);
  final client = createClient(transport.withSession(sessions));
  // Pass client and sessions to your app; close transport when it finishes.
}
```

After a successful generated native login, save its complete output with
`await sessions.write(SessionCredentials.fromJson(result.toJson()))`.
Recreate `SecureSessionStore` with the same origin on the next launch. The runtime
reads current credentials and refreshes once on the server's `invalid_token`/401.
Saving a login intentionally replaces that origin's record.

Send logout with the captured session credentials, then clear only that session.
This runtime-level example uses the same operation as the generated logout:

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

Each canonical origin has one versioned record containing the origin and all six
credential fields. Keys and plugin options use the fixed `chickinfry.sessions`
namespace within the app's storage scope. There is no custom access group or
cross-app sharing. Multiple wrappers for the same record coordinate within one
Dart isolate; direct concurrent use across isolates or processes is unsupported.
The plugin does not provide a cross-process transaction or crash-safe write
guarantee. Its Darwin backend can delete the old item after a failed
update before trying to add the replacement; failed writes can therefore lose a
record. Native storage verification is required before relying on this preview.

Only a missing record reads as `null`. Corrupt records fail with
`invalid_session_record`; OS failures fail with `session_storage_error`. Read
failures preserve the record and do not sign out silently. Android automatic reset and
algorithm migration are disabled. No `deleteAll`, automatic repair, legacy
migration, or plaintext fallback is used. Handle these codes without logging
credential data; obtain a fresh login to intentionally replace an invalid record.

## Platform verification

| Platform | Minimum OS | Status |
| --- | --- | --- |
| macOS | 12.0 | Not verified: native Keychain access requires development signing |
| iOS | 15.0 | Not yet verified |
| Android | minSdk 24 | Not yet verified |
| Windows | — | Not supported yet |
| Linux | — | Not supported yet |
| Web | — | Cookie transport only; no OS session store |

Minimum-OS device execution is **not verified** on any platform. The package
requires Dart 3.13 and Flutter 3.47 or newer; the minimum toolchain combination
has not been executed. Web `SecureSessionStore` construction and operations
fail with `unsupported_platform` before storage access. Windows, Linux and Fuchsia are
also rejected. Public imports alone do not imply platform support.

Set the consuming app's Android `minSdk` to 24, iOS deployment target to 15.0, and
macOS deployment target to 12.0. The macOS data protection Keychain is enabled.
The [plugin's macOS configuration](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0#macos--ios)
requires Keychain Sharing capability and `keychain-access-groups` in both
`DebugProfile.entitlements` and `Release.entitlements`; without app-group sharing,
the documented value is an empty array. This requires appropriate development
signing and provisioning. The example keeps these entitlements without supplying
a development team or certificate.

Locally, the initial scaffold built with ad hoc signing, but its first Keychain
write failed with OSStatus -34018 (`errSecMissingEntitlement`). Adding the required
entitlements blocked the build because a development certificate was unavailable.
No signing identity or Keychain backend was changed to bypass this failure.
For Android, disable or exclude secure-storage data
from backup as described in the
[plugin's Android configuration](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0#android).
Mobile key access, backup restoration, and locked-device behavior still need
device verification.

## Local checks

```sh
flutter analyze
flutter test
flutter test --platform chrome test/secure_session_store_test.dart
dart format --output=none --set-exit-if-changed lib test
cd example
flutter pub get
flutter build macos --debug
flutter test integration_test/session_store_test.dart -d macos
```

The macOS fixture uses the real plugin and synthetic session credentials with a
loopback HTTP peer. It checks a newly created store reading the same Keychain
record, runtime refresh, and logout preserving another origin. A new store
instance does not prove a full process restart. Generated SDK consumption and
the complete customer flow require separate verification.

## Web without native storage

On Flutter Web, construct `HttpTransport` with an explicit server origin and
pass it directly to the operation client. Do not construct `SecureSessionStore`
or attach `withSession` or `withBearer`. Fetch includes browser-managed cookies;
the SDK does not copy them into the storage plugin or web storage.

```dart
final transport = HttpTransport('https://api.example.com');
final publicSession = await transport.invoke('auth.session', {});
// Keep public session metadata in memory; close transport with your app.
```

Browser login must decode the public response and confirm it with `auth.session`.
Generated browser auth names and default paths remain pending; native generated
login decoders expect credentials and cannot decode these public responses.
Handle `OperationError` status 401 by showing sign-in and 403 as an authorization
error. Neither case automatically refreshes, retries, logs out, or clears cookies.
Registration-attempt persistence is a separate pending integration; this preview
does not implement it or claim that policy is complete.
