import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry_flutter/chickinfry_flutter.dart';
import 'package:flutter/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SessionApp(SecureSessionStore('https://api.example.com')));
}

class SessionApp extends StatelessWidget {
  SessionApp(SessionStore store, {super.key}) : session = store.read();

  final Future<SessionCredentials?> session;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: FutureBuilder<SessionCredentials?>(
        future: session,
        builder: (context, snapshot) => Text(
          snapshot.hasError
              ? 'Session storage unavailable'
              : snapshot.connectionState != ConnectionState.done
              ? 'Reading session'
              : snapshot.hasData
              ? 'Session available'
              : 'No session',
        ),
      ),
    ),
  );
}
