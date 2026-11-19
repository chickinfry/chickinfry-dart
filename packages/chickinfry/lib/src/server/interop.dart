import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../errors.dart';
import 'application.dart';
import 'database.dart';
import 'secrets.dart';
import 'storage.dart';
import 'vault.dart';

@JS('__chik.db')
external JSPromise<JSUint8Array> _database(JSUint8Array frame);

@JS('__chik.env')
external JSPromise<JSUint8Array> _environment(JSUint8Array frame);

@JS('__chikDartLog')
external JSPromise<JSUint8Array> _log(JSUint8Array frame);

@JS('__chikDartStorage')
external JSPromise<JSObject> _storage(
  JSNumber request,
  JSString operation,
  JSString name,
  JSString key,
  JSUint8Array? bytes,
  JSString? contentType,
);

extension type _StorageReply(JSObject _) implements JSObject {
  external JSString? get error;
  external JSUint8Array? get value;
}

StorageCall _requestStorage(JSNumber rid) =>
    (operation, name, key, bytes, contentType) async {
      final result = _StorageReply(
        await _storage(
          rid,
          operation.toJS,
          name.toJS,
          key.toJS,
          bytes?.toJS,
          contentType?.toJS,
        ).toDart,
      );
      final error = result.error?.toDart;
      if (error == 'service_unavailable') {
        throw const OperationError('service_unavailable', 503);
      }
      if (error != null) throw const OperationError('operation_failed', 500);
      final stored = result.value;
      return stored == null ? null : Uint8List.fromList(stored.toDart);
    };

@JS('__chikDartRegister')
external void _register(
  JSFunction dispatch,
  JSFunction ready,
  JSFunction authHook,
);

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
    ((
          JSString metadata,
          JSFunction read,
          JSFunction cancel, [
          JSNumber? requestId,
        ]) {
          Future<JSObject> dispatch() async {
            final rid = _bindingID(requestId);
            late final Map<String, Object?> value;
            late final ServerRequest request;
            try {
              value = decodeHostMetadata(metadata.toDart);
              if (value.containsKey('auth') && rid == null) {
                return _guestResponse(_invalidAuthFrame);
              }
              request = ServerRequest(
                method: value['method'] as String,
                uri: Uri.parse(value['uri'] as String),
                headers: (value['headers'] as Map).cast<String, String>(),
              );
            } catch (_) {
              return _guestResponse(_invalidAuthFrame);
            }
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

            final connection = rid == null
                ? null
                : DatabaseConnection(_requestDatabase(rid));
            final secrets = rid == null
                ? null
                : SecretValues((name) async {
                    final bytes = Uint8List.fromList(
                      utf8.encode(jsonEncode({'rid': rid, 'name': name})),
                    );
                    final result = await _environment(bytes.toJS).toDart;
                    final decoded = jsonDecode(
                      utf8.decode(Uint8List.fromList(result.toDart)),
                    ) as Map;
                    final value = decoded['value'];
                    return value is String ? value : null;
                  });
            final vault = value.containsKey('vault')
                ? Vault(
                    (value['vault'] as Map<String, dynamic>?)
                        ?.cast<String, String>(),
                  )
                : null;
            late ServerResponse response;
            try {
              response = await application.handle(
                request,
                const bool.fromEnvironment('chik.internal.snapshot_observation')
                    ? _observeChunks(chunks())
                    : chunks(),
                rawUri: value['uri'] as String,
                authFrame: hostAuthFrame(value),
                connection: connection,
                secrets: secrets,
                vault: vault,
                storage: value['storage'] == true && requestId != null
                    ? _requestStorage(requestId)
                    : null,
                log: rid == null ? null : _contextLog(rid),
              );
            } finally {
              connection?.close();
            }
            return _guestResponse(response);
          }

          return dispatch().toJS;
        })
        .toJS,
    ((JSNumber requestId) => JSPromise<JSAny?>(
      ((JSFunction resolve, JSFunction reject) {
        application
            .prepare(log: _contextLog(requestId.toDartInt))
            .then(
              (_) {
                resolve.callAsFunction();
              },
              onError: (Object _, StackTrace _) {
                reject.callAsFunction(null, 'Application setup failed.'.toJS);
              },
            );
      }).toJS,
    )).toJS,
    ((
      JSNumber requestId,
      JSString metadata, [
      JSNumber? lease,
    ]) => _dispatchAuthHook(application, requestId, metadata, lease).toJS).toJS,
  );
}

const _invalidAuthFrame = ServerResponse(500, '{"error":"operation_failed"}');

JSObject _guestResponse(ServerResponse response) =>
    {'status': response.status, 'body': response.body}.jsify() as JSObject;

int? _bindingID(JSNumber? value) {
  final number = value?.toDartDouble;
  if (number == null ||
      !number.isFinite ||
      number <= 0 ||
      number > 9007199254740991 ||
      number.truncateToDouble() != number) {
    return null;
  }
  return number.toInt();
}

DatabaseCall _requestDatabase(int rid) => (frame) async {
  final bytes = Uint8List.fromList(
    utf8.encode(jsonEncode({'rid': rid, ...frame})),
  );
  final result = await _database(bytes.toJS).toDart;
  final snapshot = Uint8List.fromList(result.toDart);
  if (const bool.fromEnvironment('chik.internal.snapshot_observation')) {
    _snapshotObserved(result);
  }
  return (jsonDecode(utf8.decode(snapshot)) as Map).cast<String, Object?>();
};

Future<JSObject> _dispatchAuthHook(
  Application application,
  JSNumber requestId,
  JSString metadata,
  JSNumber? lease,
) async {
  final rid = _bindingID(requestId);
  final leaseId = _bindingID(lease);
  if (rid == null || (lease != null && leaseId == null)) {
    return _guestResponse(_invalidAuthFrame);
  }
  try {
    final frame = decodeHostMetadata(metadata.toDart);
    final borrowed = leaseId == null
        ? null
        : borrowedAuthConnection(_requestDatabase(rid), leaseId);
    return _guestResponse(
      await application.handleAuthHook(
        frame,
        connection: borrowed,
        log: _contextLog(rid),
      ),
    );
  } catch (_) {
    return _guestResponse(_invalidAuthFrame);
  }
}

ContextLog _contextLog(int rid) => (level, message, fields) async {
  try {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'rid': rid,
          'level': level,
          'message': message,
          if (fields != null) 'fields': fields,
        }),
      ),
    );
    await _log(bytes.toJS).toDart;
  } catch (_) {}
};
