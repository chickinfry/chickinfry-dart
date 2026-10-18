import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/browser_session.dart';
import 'package:test/test.dart';

void main() {
  test('public browser session rejects malformed identity and expiry', () {
    final valid = <String, Object?>{
      'id': 'user',
      'email': 'user@example.test',
      'sessionId': 'session',
      'expiresAt': '2030-01-01T00:00:00Z',
    };
    final decoded = BrowserSession.fromJson(valid);
    expect(decoded.id, 'user');
    expect(decoded.sessionId, 'session');
    for (final field in valid.keys) {
      for (final bad in <Object?>[
        null,
        7,
        '',
        if (field == 'expiresAt') '2030-02-31T00:00:00Z',
      ]) {
        expect(
          () => BrowserSession.fromJson({...valid, field: bad}),
          throwsA(
            isA<ClientException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
    }
    for (final invalid in <Object?>[null, [], 'text']) {
      expect(
        () => BrowserSession.fromJson(invalid),
        throwsA(isA<ClientException>()),
      );
    }
  });
}
