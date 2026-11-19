import 'package:chickinfry/src/server/auth/password.dart';
import 'package:test/test.dart';

void main() {
  test('accepts the shared scrypt wire vector', () {
    const password = 'public test vector';
    const vector =
        r'scrypt$32768$8$3$00000000000000000000000000000000'
        r'$5bfe0288362511a467ab22d2e7756cf7c4af8a82aecedbf80a5e68c478a48807';
    expect(verifyPassword(password, vector), isTrue);
    expect(verifyPassword('different test vector', vector), isFalse);
    expect(verifyPassword(password, null), isFalse);
    expect(verifyPassword(password, r'scrypt$2$8$3$00$00'), isFalse);
    final encoded = hashPassword(password);
    expect(encoded, isNot(vector));
    expect(verifyPassword(password, encoded), isTrue);
  });
}
