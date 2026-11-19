import 'dart:typed_data';

typedef StorageCall = Future<Uint8List?> Function(
  String operation,
  String name,
  String key,
  Uint8List? bytes,
  String? contentType,
);

/// A declared object storage resource for the current request.
final class Storage {
  Storage(this._name, this._call);

  final String _name;
  final StorageCall _call;

  /// Returns the object's bytes, or null when the key is absent.
  Future<Uint8List?> get(String key) => _call('get', _name, key, null, null);

  /// Stores the bytes of an object with its content type.
  Future<void> put(String key, Uint8List bytes, String contentType) async {
    await _call('put', _name, key, bytes, contentType);
  }
}
