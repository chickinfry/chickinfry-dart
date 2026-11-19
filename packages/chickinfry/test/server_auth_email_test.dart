import 'package:chickinfry/src/server/auth/email.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes the shared authentication email edge cases', () {
    expect(
      normalizeEmail('\ufeffİ@Example.test\u00a0'),
      'i\u0307@example.test',
    );
    expect(normalizeEmail('ΟΣ\u0301@Example.test'), 'ος\u0301@example.test');
    expect(normalizeEmail('ΟΣ\u0301Α@Example.test'), 'οσ\u0301α@example.test');
    expect(
      normalizeEmail('\u0085User@Example.test\u0085'),
      '\u0085user@example.test\u0085',
    );
  });
}
