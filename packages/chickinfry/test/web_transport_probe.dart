import 'package:chickinfry/chickinfry.dart';

void main() {
  final transport = HttpTransport('http://127.0.0.1');
  try {
    transport.withBearer('');
    throw StateError('Native authentication was accepted in a browser.');
  } on ClientException catch (error) {
    if (error.code != 'unsupported_auth_transport') rethrow;
  } finally {
    transport.close();
  }
}
