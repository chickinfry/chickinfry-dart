import 'package:chickinfry/src/server/auth/policy.dart';
import 'package:test/test.dart';

void main() {
  test('refresh preserves the original absolute cap and stored expiry', () {
    final policy = SessionPolicy(2592000, 3600);
    final first = DateTime.utc(2026);
    final checked = first.add(const Duration(minutes: 55));
    final expires = first.add(const Duration(hours: 1));
    expect(policy.expirations(checked, first), (expires, expires));
    final stored = checked.add(const Duration(minutes: 1));
    expect(policy.familyExpiry(checked, first, checked, stored), stored);
    expect(policy.familyExpiry(stored, first, checked, stored), isNull);
    expect(
      policy.familyExpiry(
        expires,
        first,
        checked,
        expires.add(const Duration(days: 1)),
      ),
      isNull,
    );
  });
}
