import '../errors.dart';

/// Declared secret values for one request, read lazily from the host binding.
final class SecretValues {
  SecretValues(this._read);

  final Future<String?> Function(String name) _read;
  final Map<String, String> _values = {};

  /// Returns the value of the declared secret [name].
  ///
  /// A missing or empty binding fails the operation with the shared
  /// service_unavailable contract instead of exposing an unset value.
  Future<String> value(String name) async {
    final cached = _values[name];
    if (cached != null) return cached;
    final value = await _read(name);
    if (value == null || value.isEmpty) {
      throw const OperationError('service_unavailable', 503);
    }
    return _values[name] = value;
  }
}
