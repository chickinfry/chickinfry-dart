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
`chickinfry_client_plain` and `chickinfry_client_auth` and adds
`-Dchickinfry.conformance=true`; they are generated inputs, not registry packages.
No dependency download or custom build/run arguments belong in the declaration.

CLI `92b19d7` supplies both SDK paths but does not forward its execution JSON's
fixture selector to the driver (`conformance/run/build.go:198`, `run.go:272`).
The driver selects the plain bridge and reports auth-only operations as
`unimplemented`. `createBridge` is
the single selection boundary for the later explicit fixture field. Do not infer
the fixture from a case ID, operation input, or credential presence.

`client.transport` is not advertised. `client.observe` validates the request and
reports `unimplemented` while the required library retention, cancellation and
reader completion observations are unavailable. Missing observations stay null;
they are never converted to zero, false, or a complete interval. Schema 3 suite
integration, Windows protected input, Linux native execution and Flutter
app validation are separate work.

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
copied here. Run the shared schema 2 coordinator and independent aggregator to
obtain case results; local tests cannot establish a shared conformance pass.
