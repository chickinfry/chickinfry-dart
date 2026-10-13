import 'errors.dart';

final _originPattern = RegExp(
  r'^(https?)://(\[[0-9a-fA-F:.]+\]|[^:/?#@%\s\[\]\\]+)(?::[0-9]+)?/?$',
  caseSensitive: false,
);

String normalizeOrigin(String value) {
  try {
    // Uri parsing removes dot paths and decodes hosts before validation.
    final match = _originPattern.firstMatch(value);
    if (match == null || match.end != value.length) {
      throw const ClientException('invalid_origin');
    }
    final uri = Uri.parse(value);
    final host = uri.host;
    final rawHost = match.group(2)!;
    final parts = rawHost.split('.');
    final ipv4 =
        parts.length == 4 &&
        parts.first == '127' &&
        parts.every((part) {
          final number = int.tryParse(part);
          return number != null &&
              number >= 0 &&
              number <= 255 &&
              '$number' == part;
        });
    final loopback = ipv4 || rawHost == '[::1]';
    if (!uri.hasAuthority ||
        host.isEmpty ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        value.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port <= 0 ||
        uri.port > 65535) {
      throw const ClientException('invalid_origin');
    }
    return uri.origin;
  } on ClientException {
    rethrow;
  } catch (_) {
    throw const ClientException('invalid_origin');
  }
}
