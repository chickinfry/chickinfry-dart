import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'application.dart';

@JS('__chikDartRegister')
external void _register(JSFunction dispatch);

@JS('__chikSnapshotObserved')
external void _snapshotObserved(JSUint8Array chunk);

JSUint8Array? _observedSource;

Stream<List<int>> _observeChunks(Stream<List<int>> chunks) async* {
  await for (final chunk in chunks) {
    _snapshotObserved(_observedSource!);
    yield chunk;
  }
}

/// Registers generated dispatch with the private platform connection.
void runApplication(Application application) {
  _register(
    ((JSString metadata, JSFunction read, JSFunction cancel) {
      Future<JSObject> dispatch() async {
        final value = jsonDecode(metadata.toDart) as Map<String, dynamic>;
        final request = ServerRequest(
          method: value['method'] as String,
          uri: Uri.parse(value['uri'] as String),
          headers: (value['headers'] as Map<String, dynamic>)
              .cast<String, String>(),
        );
        Stream<List<int>> chunks() async* {
          try {
            while (true) {
              final chunk =
                  await (read.callAsFunction() as JSPromise<JSAny?>).toDart;
              if (chunk == null) break;
              final source = chunk as JSUint8Array;
              final snapshot = Uint8List.fromList(source.toDart);
              if (const bool.fromEnvironment(
                'chik.internal.snapshot_observation',
              )) {
                _observedSource = source;
              }
              yield snapshot;
            }
          } finally {
            await (cancel.callAsFunction() as JSPromise<JSAny?>).toDart;
          }
        }

        final response = await application.handle(
          request,
          const bool.fromEnvironment('chik.internal.snapshot_observation')
              ? _observeChunks(chunks())
              : chunks(),
          rawUri: value['uri'] as String,
        );
        return {'status': response.status, 'body': response.body}.jsify()
            as JSObject;
      }

      return dispatch().toJS;
    }).toJS,
  );
}
