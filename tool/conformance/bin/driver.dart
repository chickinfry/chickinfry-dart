import 'dart:io';

import 'package:chickinfry_conformance/credentials.dart';
import 'package:chickinfry_conformance/server.dart';

void validateLaunch(List<String> args) {
  if ((args.length != 4 && args.length != 6) ||
      args[0] != '--plain-sdk' ||
      args[2] != '--auth-sdk' ||
      (args.length == 6 && args[4] != '--required-auth-sdk')) {
    throw StateError('Invalid launch.');
  }
}

Future<void> main(List<String> args) async {
  Server? server;
  try {
    validateLaunch(args);
    final credentials = bootstrap();
    server = Server(credentials, (bytes) async {
      stdout.add(bytes);
      await stdout.flush();
    });
    await server.serve(stdin);
    if (server.failed) exitCode = 2;
  } catch (_) {
    server?.fail();
    if (server != null) await server.finish();
    stderr.writeln('Conformance driver failed.');
    exitCode = 2;
  }
}
