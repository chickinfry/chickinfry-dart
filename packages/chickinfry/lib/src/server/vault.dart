import '../errors.dart';

/// An immutable snapshot of the selected vault for a request.
final class Vault {
  Vault(Map<String, String>? values)
    : _values = values == null ? null : Map.unmodifiable(values);

  final Map<String, String>? _values;

  /// Returns the value stored under [name].
  String get(String name) {
    final snapshot = _values;
    if (snapshot == null) {
      throw const OperationError('service_unavailable', 503);
    }
    final value = snapshot[name];
    if (value == null) throw StateError('Secret is not bound to the vault.');
    return value;
  }
}
