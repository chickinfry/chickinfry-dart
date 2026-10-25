import 'open_stub.dart' if (dart.library.io) 'native.dart' as platform;

/// Persist controls device persistence for a single-user native client.
final class Persist {
  const Persist._(this.directory);

  /// disabled keeps authentication state only for this client instance.
  static const disabled = Persist._(null);

  /// dir stores authentication state in the given directory.
  /// Relative directories are fixed against the working directory at creation.
  factory Persist.dir(String directory) =>
      Persist._(platform.resolveDirectory(directory));

  final String? directory;
}
