/// Server runtime for generated Chickinfry applications.
library;

export 'src/errors.dart' show OperationError;
export 'src/server/application.dart';
export 'src/server/interop_stub.dart'
    if (dart.library.js_interop) 'src/server/interop.dart'
    show runApplication;
