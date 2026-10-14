import 'dart:convert';
import 'dart:typed_data';

final identifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._/-]{0,255}$');

final class DriverError implements Exception {
  const DriverError(this.code, {this.kind = 'driver'});
  final String code;
  final String kind;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'code': code,
    'httpStatus': null,
    'outcomeUnknown': null,
  };
}

Never violation() => throw const DriverError('protocol_violation');
Never invalidArgs() => throw const DriverError('invalid_args');
Never unimplemented() =>
    throw const DriverError('unimplemented', kind: 'unimplemented');

Map<String, Object?> object(Object? value) {
  if (value is! Map<String, Object?>) invalidArgs();
  return value;
}

void fields(
  Map<String, Object?> value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (!required.every(value.containsKey) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    violation();
  }
}

String string(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! String) invalidArgs();
  return result;
}

String identifier(Map<String, Object?> value, String key) {
  final result = string(value, key);
  if (!identifierPattern.hasMatch(result)) invalidArgs();
  return result;
}

int positive(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! int || result <= 0) invalidArgs();
  return result;
}

/// Rejects duplicate keys, including escaped equivalents in nested objects.
Object? strictJson(String source) {
  try {
    final decoded = jsonDecode(source);
    final scopes = <Set<String>?>[];
    for (var i = 0; i < source.length; i++) {
      final unit = source.codeUnitAt(i);
      if (unit == 123 || unit == 91) {
        scopes.add(unit == 123 ? <String>{} : null);
        if (scopes.length > 256) violation();
      } else if (unit == 125 || unit == 93) {
        scopes.removeLast();
      } else if (unit == 34) {
        final start = i++;
        while (source.codeUnitAt(i) != 34) {
          if (source.codeUnitAt(i) == 92) i++;
          i++;
        }
        var next = i + 1;
        while (next < source.length && ' \r\n\t'.contains(source[next])) {
          next++;
        }
        if (next < source.length && source.codeUnitAt(next) == 58) {
          final key = jsonDecode(source.substring(start, i + 1)) as String;
          if (!scopes.last!.add(key)) violation();
        }
      }
    }
    return decoded;
  } on DriverError {
    rethrow;
  } catch (_) {
    violation();
  }
}

/// Counts encoded bytes including LF before decoding or collecting another chunk.
final class Frames {
  Frames(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  List<String> add(List<int> chunk) {
    final lines = <String>[];
    var start = 0;
    while (start < chunk.length) {
      final lf = chunk.indexOf(10, start);
      final end = lf < 0 ? chunk.length : lf + 1;
      if (_bytes.length + end - start > limit ||
          (lf < 0 && _bytes.length + end - start == limit)) {
        violation();
      }
      _bytes.add(chunk.sublist(start, end));
      if (lf >= 0) {
        final line = _bytes.takeBytes();
        try {
          lines.add(utf8.decode(line.sublist(0, line.length - 1)));
        } catch (_) {
          violation();
        }
      }
      start = end;
    }
    return lines;
  }

  void finish() {
    if (_bytes.length != 0) violation();
  }
}
