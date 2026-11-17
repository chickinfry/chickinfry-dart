import 'device/bridge.dart';
import 'errors.dart';
import 'http.dart';

/// Binds generated clients to their pending signup without duplicating device state.
final class SignupBinding implements ClientTransport {
  SignupBinding(this._transport);

  final ClientTransport _transport;
  ({String attempt, String email})? _signup;
  int _logoutGeneration = 0;
  final _emailGenerations = <String, int>{};

  static Future<T> decode<T>(
    ClientTransport transport,
    String operation,
    Map<String, Object?> input,
    T Function(Object?) decode,
  ) => transport is SignupBinding
      ? transport._invoke(operation, input, decode)
      : transport.invoke(operation, input).then(decode);

  @override
  Future<Object?> invoke(String operation, Map<String, Object?> input) =>
      _invoke(operation, input, (output) => output);

  Future<T> _invoke<T>(
    String operation,
    Map<String, Object?> input,
    T Function(Object?) decode,
  ) async {
    if (_transport is DeviceTransport) {
      return decode(await _transport.invoke(operation, input));
    }
    var request = input;
    final signup = _signup;
    final attempt = signup?.attempt;
    final email = input['email'] is String
        ? (input['email']! as String).trim().toLowerCase()
        : null;
    final logoutGeneration = _logoutGeneration;
    final emailGeneration = _emailGenerations[email] ?? 0;
    if (operation == 'auth.verify_email' ||
        operation == 'auth.send_verification_email') {
      if (!input.containsKey('email') &&
          !input.containsKey('attempt') &&
          attempt != null) {
        request = {...input, 'attempt': attempt};
      }
      if (request.containsKey('email') == request.containsKey('attempt') ||
          (request['email'] ?? request['attempt']) is! String) {
        throw const ClientError('invalid_argument');
      }
    }
    final sessionEmail =
        email ??
        (operation == 'auth.verify_email' &&
                request['attempt'] == signup?.attempt
            ? signup?.email
            : null);
    final output = await _transport.invoke(operation, request);
    final result = decode(output);
    if (operation == 'auth.signup' &&
        output is Map<String, Object?> &&
        output['accepted'] == true &&
        output['attempt'] is String &&
        email != null &&
        logoutGeneration == _logoutGeneration &&
        emailGeneration == (_emailGenerations[email] ?? 0)) {
      _signup = (attempt: output['attempt'] as String, email: email);
    } else if (operation == 'auth.logout') {
      _logoutGeneration++;
      _emailGenerations.clear();
      _signup = null;
    } else if (const {
          'auth.signin',
          'auth.signin_with_code',
          'auth.identity',
          'auth.verify_email',
        }.contains(operation) &&
        sessionEmail != null) {
      _emailGenerations[sessionEmail] =
          (_emailGenerations[sessionEmail] ?? 0) + 1;
      if (_signup?.email == sessionEmail) _signup = null;
    }
    return result;
  }
}
