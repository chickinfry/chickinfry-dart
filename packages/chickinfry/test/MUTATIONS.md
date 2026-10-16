# Transport mutation checks

These are local implementation-risk checks tagged with common case IDs, not
results from the common conformance suite. Generated model validation and
generation ownership checks belong to the generated SDK and generator.

The initial checks on 2026-10-13 used a 41-test baseline on Dart 3.13.4
(macOS arm64, http 1.6.0). Each initial variant was applied alone to an ignored
temporary package copy under `build/mutations`, with unchanged HTTP peers and
expectations. Every listed variant exited 1 because an expectation differed;
compilation failures and interrupted runners were not counted. The production
source was unchanged and the temporary runtime source was restored.

Run a targeted check with
`dart test test/<file> --name '<test name fragment>' --reporter expanded`.

| Variant | Required observation | File and test name fragment | Local result |
| --- | --- | --- | --- |
| Permit a second refresh and replay | C-08: business requests 2, refresh requests 1; peers always reply before assertions | `session_test.dart`: `one refresh and one replay` | Rechecked after review: expected business count 2, observed 3 after completed peer replies |
| Remove shared-flight joining | C-09: two store objects and independent transports issue one refresh | `session_test.dart`: `distinct store objects` | Detected: a concurrent result became `session_changed` |
| Enable redirects and raise max redirects | C-05: destination receives no request | `http_test.dart`: `redirect 303` | Detected: redirect was followed and returned success |
| Remove the 1 MiB response bound | C-04: reject oversized success/error bodies | `http_test.dart`: `response byte boundary` | Detected: oversized response was accepted |
| Count `String.length` instead of UTF-8 bytes | C-04: reject oversized multibyte input before sending | `http_test.dart`: `UTF-8 request boundary` | Detected: oversized multibyte input was sent |
| Refresh every 401 | C-08: preserve other 401 codes without refresh | `session_test.dart`: `other errors and direct` | Detected: error code/status changed after extra refresh |
| Refresh every operation error | C-08: no refresh for 403/429/500 | `session_test.dart`: `other errors and direct` | Detected: error code/status changed after extra refresh |
| Delete the latest record regardless of expected credentials | C-10: retain a new login after late refresh rejection | `session_test.dart`: `late refresh rejection preserves` | Detected: new login was deleted |
| Write refresh success without CAS | C-10: retain a new login after late refresh success | `session_test.dart`: `late refresh success preserves` | Detected: old success replaced the new login |
| Cancel the deadline timer before reading the body | C-05: stalled body fails with `request_timeout` and closes the connection | `http_test.dart`: `deadline aborts body` | Detected: the test's outer deadline expired instead |
| Exclude oversized refresh responses from unknown outcomes | C-08: only one refresh; original record retained on the next call | `session_test.dart`: `uncertain refresh oversized` | Detected: expected refresh count 1, observed 2 |
| Delete only `if (abort != null) unawaited(abort.then((_) => cancel()));` | C-05: request cancellation closes stalled TLS before the longer connection timeout | `http_test.dart`: `deadline closes stalled TLS` | Detected: caller returned at 222 ms; no peer closure within the following 600 ms; connection timeout 2,000 ms |
| Delete only `if (socket != null) unawaited(socket.close());` from `cancel` (the retained `raw` socket) | C-05: cancellation actually closes the stalled TCP socket | `http_test.dart`: `deadline closes stalled TLS` | Detected: caller returned at 216 ms; no peer closure within the following 600 ms; connection timeout 2,000 ms |
| Add `..findProxy = ((_) => 'DIRECT')` after `connectionTimeout` | Preserve the selected proxy without contacting the origin directly | `http_test.dart`: `Proxy selection preserves the environment route` | Detected: expected origin 0 / proxy 1, observed origin 1 / proxy 0 |
| Remove web platform rejection | Unsupported native bearer requests fail before any fetch | `web_transport_probe.dart` with `web_runner.cjs` | Detected: expected fetch count 0, observed 2; no `unsupported_platform` |
| Remove original origin string validation | C-02: reject paths and encoded hosts before URI normalization | `http_test.dart`: `origin validation and normalization` | Detected: a dot path returned a transport instead of `invalid_origin` |
| Drop the explicit 501 exception (original status set) | DX-08: explicit `not_implemented`/501 business error surfaces as 501 with its code | `server_test.dart`: `only permitted business errors` | Detected: expected status 501, observed 500 with `operation_failed` |
| Allow 501 regardless of code | DX-08: other-code 501 stays `operation_failed`/500 | `server_test.dart`: `only permitted business errors` | Detected: expected status 500, observed 501 with `conflict` |
| Keep Proxy-Authorization in handler headers | Proxy credentials never reach handlers or context factories (RFC 9110 11.7.2) | `server_test.dart`: `Proxy-Authorization never reaches` | Detected: both paths expected the key absent and observed it present |
| Run setup on every request without caching the Future | DX-12: one setup per application instance; concurrent first requests wait on one setup | `server_test.dart`: `setup gates concurrent requests once` | Detected: expected setup count 1, observed 2 (latched-failure variants observed 3) |
| Clear the setup failure cache so the next request retries setup | DX-12: a failed setup stays latched with exact 500 responses and no handler work | `server_test.dart`: `setup failure is latched` | Detected: expected setup count 1, observed 2 after the retried request |
| Return 401 `invalid_token` when an `authorization` header is present | DX-AUTH-NONE-03: auth-free apps pass credentials through to a 200 business call | `server_test.dart`: `application credentials reach handlers` | Detected: expected status 200, observed 401; handler not called |
| Drop `cookie` from request headers | DX-AUTH-NONE-03: both credential headers reach handlers unchanged | `server_test.dart`: `application credentials reach handlers` | Detected: cookie equality check flipped from true to false (value mismatch) |
| Run setup on every `prepare` call without caching the result | Readiness and requests share one setup per instance; concurrent prepares wait on one setup | `server_test.dart`: `setup gates concurrent requests once` | Detected: expected setup count 1, observed 4 before release (latched variants observed 5) |
| Clear the cached setup failure so the next `prepare` retries | A failed setup stays latched with the same failure object and one setup call | `server_test.dart`: `setup failure is latched` | Detected: expected setup count 1, observed 3 after retried prepares |
| Resolve the ready promise even when setup fails | Setup failure rejects the ready promise with the fixed reason and no handler work | `build/ready_probe` WASM probe (`runner.mjs`) | Detected: failure mode resolved `{ok: true, value: undefined}` instead of rejecting; node exited 1 |

The readiness checks on 2026-10-16 used the 12-test `server_test.dart`
baseline on Dart 3.13.5 (macOS arm64, Node 26.8.2). Each variant was applied
alone to a package copy under `/private/tmp/dart-239-p10b-mut/m1..m3` after
`dart pub get --offline --enforce-lockfile`, and the production source stayed
unchanged. The first two variants ran `dart test test/server_test.dart
--reporter expanded` in the foreground. The ready callback has no VM unit
test, so its variant recompiled the existing `build/ready_probe` probe
(`heavy-slot -- dart compile wasm build/ready_probe/main.dart -o
build/ready_probe/main.wasm`) and ran `heavy-slot -- node
build/ready_probe/runner.mjs`; the mutated module compiled successfully and
node exited 1 on the failure-mode assertion, so detection is an expectation
mismatch rather than a build failure. The temporary copies were deleted after
listing.

The deletion variant reads the latest record and conditionally deletes that
record, deliberately ignoring the request's expected credentials. The store
contract remains intact; only the transport's selection of the expected record
is corrupted. The write variant uses the existing unconditional `write` method.

A redirect variant targeting POST 307 survived because the native HTTP client
does not follow that redirect for POST. POST 303 detects the same variant and is
the recorded result. An initial shared-flight run failed with an unhandled
asynchronous error; it was excluded. After attaching concurrent-result observers
at call creation, the same variant failed the expected result comparison.

Additional response cancellation evidence is covered by
`C-04 oversized unbounded stream aborts at the limit without waiting for EOF`.
Connection/TLS, header and body deadline checks observe the peer socket closing
and verify that the same transport can still complete another request. The TLS
check also rejects an untrusted certificate and observes exact byte counts for
a subsequent 256 KiB request and response. Unknown refresh outcomes
are tested for timeout, connection loss, conditional-store failure, oversized and
malformed responses, and server errors, including
shared waiters and suspension until a different login credential is read.
An overlapping old/new login check also prevents a late unknown outcome from
erasing the newer credential's suspension.

The pre-review `lib/src/http.dart` SHA-256 during the initial runs was
`3ebdca8dc71d77c206ac90c18811bdb0b152aec469e6d980324c061da7c5c23b`.
The local logs and their hashes are in `build/mutations/results.json`.

The review-fix baseline passed all 45 tests. M1 and the four added variants were
applied independently in package copies under
`build/review-fixes/mutations`, with every mutated source restored afterwards.
Their logs and hashes are in `build/review-fixes/mutations/results.json`.

The proxy-review baseline passed all 47 tests on Dart 3.13.4. The TLS check now
uses a 200 ms caller deadline and a 2,000 ms connection timeout, and requires
peer closure within 800 ms of invocation. The baseline returned at 203 ms and
observed closure at 204 ms. This separates request cancellation from the SDK's
later connection-timeout fallback. The earlier combined TLS mutation claim did
not retain an exact diff and is superseded by the two independent one-line
deletions above; it is not evidence for either deletion on the earlier test.

The three proxy-review variants were run independently under
`build/proxy-review-fixes/mutations/{abort-trigger,raw-close,force-direct}`.
Each directory retains `mutation.diff`, `test.log` and
`http_client_io.mutated.txt`; the runtime inside each package copy was restored.
Exit codes, observations and source/log SHA-256 values are retained in
`build/proxy-review-fixes/mutations/results.json`. The production source was
unchanged during those runs. `peerClosed=-1ms` in the TLS logs means no closure
was observed within the 600 ms wait after the caller returned, not a negative
closure timestamp. The unmutated proxy checks observed origin 0 / proxy 1,
rejected an untrusted certificate before HTTP, completed a trusted HTTPS
CONNECT request, and returned `request_timeout` at 205 ms for stalled proxy TLS.

The web check compiles and runs with the existing Node installation:

```sh
dart compile js -o build/web_transport_probe.js test/web_transport_probe.dart
node test/web_runner.cjs build/web_transport_probe.js
```

Not run here: common conformance driver, generated SDK consumption, native secure
storage, minimum Dart SDK execution, deployment and real database operations.
