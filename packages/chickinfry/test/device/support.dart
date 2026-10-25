import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/device/native.dart';
import 'package:chickinfry/src/device/store.dart';

String randomToken() => base64Url.encode(randomBytes(32)).replaceAll('=', '');
Uint8List randomBytes(int size) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
}

String randomId() {
  final value = randomBytes(16)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

SessionCredentials credentials({String? user, String? session}) =>
    SessionCredentials(
      accessToken: randomToken(),
      refreshToken: randomToken(),
      expiresAt: DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 15))
          .toIso8601String(),
      refreshExpiresAt: DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String(),
      userId: user ?? randomId(),
      sessionId: session ?? randomId(),
    );
DeviceScope scope(
  String origin, {
  String app = 'device.test',
  String screen = 'signup',
}) => DeviceScope(
  app: app,
  origin: origin,
  project: 'project',
  environment: 'test',
  screen: screen,
);
NativeDeviceStore device(
  String root,
  String origin, {
  String screen = 'signup',
  String app = 'device.test',
}) => NativeDeviceStore(
  scope(origin, app: app, screen: screen),
  directory: root,
);

Future<String> scratch() async {
  final root =
      Platform.environment['CHICKINFRY_DEVICE_TEST_ROOT'] ??
      '${Directory.current.path}/.dart_tool/device-tests';
  await Directory(root).create(recursive: true);
  return (await Directory(root).createTemp('run-')).path;
}

Future<int> child(
  String action,
  String root,
  String origin, {
  String screen = 'signup',
  String? home,
  String? xdgStateHome,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      'test/device/process.dart',
      action,
      root,
      origin,
      screen,
    ],
    includeParentEnvironment: false,
    environment: {
      for (final name in const [
        'HOME',
        'PATH',
        'TMPDIR',
        'LANG',
        'LC_ALL',
        'PUB_CACHE',
        'MISE_TRUSTED_CONFIG_PATHS',
        'CHICKINFRY_DEVICE_TEST_ROOT',
      ])
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
      if (home != null) 'HOME': home,
      if (xdgStateHome != null) 'XDG_STATE_HOME': xdgStateHome,
    },
  );
  final output = process.stdout.drain<void>();
  final errors = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((line) => RegExp(r'^device storage check=[a-z_]+$').hasMatch(line))
      .toList();
  await process.stdin.close();
  final result = await process.exitCode;
  await output;
  final labels = await errors;
  if (result == 39) {
    throw StateError(
      'Device child $action failed: ${labels.isEmpty ? 'check=unknown' : labels.first}',
    );
  }
  return result;
}
