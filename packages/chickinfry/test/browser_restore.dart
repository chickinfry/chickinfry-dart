import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/browser_session.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final transport = HttpTransport(web.window.location.origin);
  try {
    final session = await BrowserAuth(transport).session();
    await transport.invoke('test.control', {
      'restored': {'id': session.id},
    });
  } catch (_) {
    await transport.invoke('test.control', {
      'restored': {'error': 'restore_failed'},
    });
  } finally {
    transport.close();
  }
}
