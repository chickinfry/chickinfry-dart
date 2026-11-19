import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/scrypt.dart';

import '../../errors.dart';

const _prefix = r'scrypt$32768$8$3$';
final _format = RegExp(
  r'^scrypt\$32768\$8\$3\$([a-f0-9]{32})\$([a-f0-9]{64})$',
);
final _random = Random.secure();

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

String hexBytes(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _decodeHex(String hex) => Uint8List.fromList([
  for (var index = 0; index < hex.length; index += 2)
    int.parse(hex.substring(index, index + 2), radix: 16),
]);

void validatePassword(String password) {
  final runes = password.runes;
  if (runes.length < 15 || utf8.encode(password).length > 1024) {
    throw const OperationError('invalid_input', 400);
  }
}

Uint8List _derive(String password, Uint8List salt) =>
    (Scrypt()..init(ScryptParameters(32768, 8, 3, 32, salt))).process(
      utf8.encode(password),
    );

String hashPassword(String password) {
  final salt = randomBytes(16);
  return '$_prefix${hexBytes(salt)}\$${hexBytes(_derive(password, salt))}';
}

bool verifyPassword(String password, String? stored) {
  final match = stored == null ? null : _format.firstMatch(stored);
  final valid = match != null && match.end == stored!.length;
  final salt = valid ? _decodeHex(match[1]!) : Uint8List(16);
  final expected = valid ? _decodeHex(match[2]!) : Uint8List(32);
  // Missing and malformed hashes incur the same derivation and comparison cost.
  final actual = _derive(password, salt);
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= expected[index] ^ actual[index];
  }
  return difference == 0 && valid;
}
