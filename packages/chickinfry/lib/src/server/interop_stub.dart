import 'application.dart';

/// Registers an application only on the WebAssembly execution target.
void runApplication(Application application) =>
    throw UnsupportedError('Chickinfry servers require the WebAssembly host.');
