# chickinfry

**Status: in development.** The runtime is not published to pub.dev yet, and
Dart is not marked as a supported language until verification is complete.

`chickinfry` supplies HTTP transport, sessions, and the server runtime for
Chickinfry generated clients. It uses HTTPS or an explicit loopback HTTP origin.

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
   checkout with `pubspec_overrides.yaml`. That file is yours; `chik generate`
   does not overwrite it.

See the repository README for the full transport and server guide.

## License

Apache-2.0. See `LICENSE`.
