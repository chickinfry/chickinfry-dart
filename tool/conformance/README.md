# Dart SDK conformance driver

This internal package consumes the generated plain/auth SDKs and the runtime's
opt-in conformance hooks. It does not implement SDK transport, refresh policy,
case expectations, or result aggregation.

The shared coordinator owns generation, dependency preparation, the compiler,
the executable hash, and every launch. Its native declaration uses:

```json
{
  "protocolVersion": 1,
  "driverVersion": "1.0.0",
  "driverCommit": "<full clean source commit>",
  "requiredAuthSDK": true,
  "build": {"tool": "dart", "entry": "bin/driver.dart", "features": []},
  "executable": "driver",
  "run": null,
  "files": []
}
```

Create this declaration next to an owned copy of this package after recording
the actual source commit. Never label a dirty source tree with a clean commit.
Prepare the package's existing `.dart_tool/package_config.json` with offline
dependencies before invoking the coordinator. The runtime path in that config
must resolve to the pinned runtime source. The coordinator injects
`chickinfry_client_plain`, `chickinfry_client_auth` and
`chickinfry_client_required_auth` and adds
`-Dchickinfry.conformance=true`; they are generated inputs, not registry packages.
No dependency download or custom build/run arguments belong in the declaration.

The coordinator supplies `fixture: "plain"` or `fixture: "auth"` on every
`client.create`. `createBridge` is the only selection boundary; it rejects unknown
fixtures before SDK construction. Copies retain the source client's fixture.
For C-11, the requiredAuth fixture selects the required-verification SDK. It uses the
same client.create/client.call protocol and leaves session and bearer paths intact.
The opted-in declaration also accepts --required-auth-sdk from the coordinator.
SDK selection depends only on the explicit fixture, never the case identifier.
Its tests check signup attempt reuse, SDK results and errors, and compile the
invalid sealed-choice consumer to prove that email and attempt cannot coexist.
The driver accepts only the native Dart SDK role and process protocol version 1;
the shared suite, execution and result schema version is 3.

With enabled hooks and a source-proven Dart SDK, `client.transport` exposes
`client.observe` snapshots with eight fields per event and a process-wide
sequence watermark. Reads are published immediately and cumulative across HTTP
exchanges. Session calls project only the result exchange's other phases at
selection time; SDK completion appears once. Stored SDK errors remain observable.
Incomplete intervals have `complete:false`; unknown byte counts remain null.
The driver reports cancellation timestamps, never its own cancellation verdict.
The shared suite checks the fixed 1000 ms cancellation/reader-close budget.

Retention comes from the runtime's pinned native HTTP/1.1 path, not a memory
sampler or logical payload estimate. Native `dart:io` uses HTTP/1.1, including the
controlled plain peer; this driver does not establish remote HTTP/2 bounds.
The runtime source pins Dart 3.13.0/3.13.5 and package:http 1.6.0.
In `http_client_io.dart`, raw reads cap at 8192 bytes and the plain fixed bound
is 5 * 8192 = 40960 bytes, below the 64 KiB transient allowance; the TLS bound
is 393216 bytes and is added to runtime retention and materialization peaks.
The source comments document raw-read overlap, parser views, owned-chunk handoff,
TLS filter rings, BIO and SSLBuffer allocations with pinned file/line references.
`testing/conformance.dart` confirms the connection, SDK, profiler, encoding and
single-exchange conditions at headers. Gzip, proxy, unproven SDK and shared
refresh/multiple-exchange retention remains null, including after completion.
Windows protected input, Linux native execution and Flutter app validation
remain separate work.

After the coordinator has connected the actual generated packages, run:

```sh
dart format --output=none --set-exit-if-changed lib bin test
dart analyze --fatal-infos
dart test
dart -Dchickinfry.conformance=true test --compiler source
python3 test/fd3_test.py /absolute/path/to/the/native/driver
```

The descriptor test launches the actual AOT executable with inherited fd 3,
checks handshake ordering against protected EOF, checks control EOF and process
exit, and rejects malformed, duplicate, oversized and unclosed bootstrap input.
It prints only host and executable identity. Unit tests use small synthetic
protocol messages and generated SDK calls; shared case expectations are not
copied here. Run the shared schema 3 coordinator and independent aggregator to
obtain case results; local tests cannot establish a shared conformance pass.
