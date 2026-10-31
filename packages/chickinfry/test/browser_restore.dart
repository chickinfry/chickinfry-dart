import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/browser_session.dart';
import 'package:chickinfry/src/device/bridge.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final phase = Uri.base.queryParameters['device'];
  if (phase != null) {
    await checkDevice(phase);
    return;
  }
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

Future<void> checkDevice(String phase) async {
  final origin = web.window.location.origin;
  final control = HttpTransport(origin);
  final client = createDeviceTransport(
    app: 'web.test',
    origin: origin,
    project: 'project',
    environment: 'test',
    screen: 'original-screen',
  );
  try {
    var ok = false;
    switch (phase) {
      case 'seed':
        await client.store.clear(await client.store.load());
        await client.invoke('auth.signup', {
          'pending': true,
          'email': 'restore@example.test',
        });
        web.window.location.replace('/restore.html?device=reload');
        return;
      case 'reload':
        await client.invoke('auth.verify_email', {'code': '123456'});
        ok =
            (await BrowserAuth(client).session()).id == 'a' &&
            (await client.store.load()).attempts.isEmpty;
      case 'closed':
        ok = (await BrowserAuth(client).session()).id == 'a';
        await client.invoke('auth.logout', {});
      case 'logout':
        try {
          await BrowserAuth(client).session();
        } on OperationError catch (error) {
          ok =
              error.status == 401 &&
              (await client.store.load()).attempts.isEmpty;
        }
    }
    await control.invoke('test.control', {
      'restored': {'phase': phase, 'ok': ok},
    });
  } catch (_) {
    await control.invoke('test.control', {
      'restored': {'phase': phase == 'seed' ? 'reload' : phase, 'ok': false},
    });
  } finally {
    client.close();
    control.close();
  }
}
