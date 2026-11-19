import '../../errors.dart';

const _space =
    r'\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff';
final _trim = RegExp('^[$_space]+|[$_space]+\$');
final _address = RegExp('^[^$_space@]+@[^$_space@]+\\.[^$_space@]+\$');
final _cased = RegExp(r'\p{Cased}', unicode: true);
final _ignorable = RegExp(r'\p{Case_Ignorable}', unicode: true);

String normalizeEmail(String email) {
  final value = email.replaceAll(_trim, '');
  if (value.length > 320 || value.contains('\u0000')) {
    throw const OperationError('invalid_input', 400);
  }
  final characters = value.runes.map(String.fromCharCode).toList();
  final lower = StringBuffer();
  var precededByCased = false;
  for (var index = 0; index < characters.length; index++) {
    final current = characters[index];
    // Match the default Unicode lowercase rules used by the wire contract.
    if (current == 'İ') {
      lower.write('i\u0307');
    } else if (current == 'Σ' && precededByCased) {
      var next = index + 1;
      while (next < characters.length &&
          _ignorable.hasMatch(characters[next])) {
        next++;
      }
      lower.write(
        next < characters.length && _cased.hasMatch(characters[next])
            ? 'σ'
            : 'ς',
      );
    } else {
      lower.write(current.toLowerCase());
    }
    if (!_ignorable.hasMatch(current)) {
      precededByCased = _cased.hasMatch(current);
    }
  }
  final normalized = lower.toString();
  if (normalized.length > 320 ||
      _address.firstMatch(normalized)?.end != normalized.length) {
    throw const OperationError('invalid_input', 400);
  }
  return normalized;
}
