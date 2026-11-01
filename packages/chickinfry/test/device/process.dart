import 'dart:io';
import 'dart:isolate';
import 'dart:async';

import 'package:chickinfry/chickinfry.dart';

import 'package:chickinfry/src/device/bridge.dart';
import 'package:chickinfry/src/device/files.dart';
import 'package:chickinfry/src/device/native.dart';
import 'package:chickinfry/src/device/store.dart';

import 'support.dart';

Future<void> main(List<String> arguments) async {
  try {
    final action = arguments[0];
    final root = arguments[1];
    final origin = arguments[2];
    final screen = arguments[3];
    final store = device(root, origin, screen: screen);
    final transport = DeviceTransport(
      store,
      timeout: const Duration(seconds: 3),
    );
    try {
      switch (action) {
        case 'default-location':
        case 'default-unavailable':
          final automatic = createDeviceTransport(
            app: 'device.test',
            origin: origin,
            project: 'project',
            environment: 'test',
            screen: screen,
          );
          try {
            final native = automatic.store as NativeDeviceStore;
            if (action == 'default-unavailable') {
              try {
                await native.load();
                exit(86);
              } on ClientError catch (error) {
                if (error.code != 'failed_precondition') exit(87);
              }
            } else {
              if (!native.directory.startsWith('$root/')) exit(88);
              await native.write(credentials());
              if (await native.read() == null) exit(89);
            }
          } finally {
            automatic.close();
          }
        case 'seed':
          await transport.invoke('auth.signin', {'email': 'user@example.test'});
          await transport.invoke('auth.signup', {
            'email': 'pending@example.test',
          });
          final state = await store.load();
          if (state.session == null || state.attempts.length != 1) exit(31);
        case 'verify':
          await transport.invoke('example.read', {});
          await transport.invoke('auth.verify_email', {
            'code': DateTime.now().millisecond.toString().padLeft(6, '0'),
          });
          final state = await store.load();
          if (state.session == null || state.attempts.isNotEmpty) exit(32);
        case 'logout':
          await transport.invoke('auth.signup', {
            'email': 'pending@example.test',
          });
          await transport.invoke('auth.logout', {});
        case 'unresolved':
          if (await store.read() != null ||
              (await store.load()).toJson()['auth_transition_unknown'] !=
                  true) {
            exit(85);
          }
        case 'empty':
          if (await store.read() != null) exit(33);
          final state = await store.load();
          if (state.session != null || state.attempts.isNotEmpty) exit(33);
        case 'race':
          await transport.invoke('example.read', {});
        case 'claim':
          final state = await store.load();
          if (await store.claimRefresh(state.session!) == null) exit(34);
        case 'blocked':
          try {
            await store.read();
            exit(35);
          } catch (_) {}
        case 'atomic-temp':
        case 'atomic-rename':
        case 'atomic-directory':
          final current = await store.load();
          final crashing = NativeDeviceStore(
            store.scope,
            directory: root,
            files: CrashFiles(action),
          );
          await crashing.commit(
            current,
            DeviceState(
              generation: current.generation + 1,
              authGeneration: current.authGeneration + 1,
              session: credentials(),
            ),
          );
        case 'relative':
          Directory.current = root;
          final persistence = Persist.dir('relative-device');
          final later = Directory('$root/later')..createSync();
          Directory.current = later.path;
          final scoped = createDeviceTransport(
            app: 'device.test',
            origin: origin,
            project: 'project',
            environment: 'test',
            screen: 'signup',
            persist: persistence,
          );
          try {
            final native = scoped.store as NativeDeviceStore;
            if (!native.directory.startsWith('$root/relative-device/')) {
              exit(81);
            }
            await native.load();
            if (!await Directory('$root/relative-device').exists()) exit(82);
            try {
              Persist.dir('');
              exit(83);
            } on ClientError catch (error) {
              if (error.code != 'failed_precondition') exit(84);
            }
          } finally {
            scoped.close();
          }
        case 'fifo':
          final ready = ReceivePort();
          await Isolate.spawn((SendPort sender) {
            Timer(const Duration(seconds: 2), () => exit(74));
            sender.send(true);
          }, ready.sendPort);
          await ready.first;
          ready.close();
          try {
            await store.load();
            exit(76);
          } on ClientError catch (error) {
            exit(error.code == 'failed_precondition' ? 0 : 77);
          }
        case 'increment':
          for (var i = 0; i < 10; i++) {
            var changed = false;
            while (!changed) {
              final state = await store.load();
              changed = await store.commit(
                state,
                DeviceState(
                  generation: state.generation + 1,
                  authGeneration: state.authGeneration,
                  session: state.session,
                  attempts: state.attempts,
                ),
              );
            }
          }
        default:
          exit(36);
      }
    } finally {
      transport.close();
    }
  } catch (error, stack) {
    final label = stack.toString().split('\n').first;
    if (error is ClientError &&
        RegExp(r'^device storage check=[a-z_]+$').hasMatch(label)) {
      stderr.writeln(label);
    }
    exit(39);
  }
}

class CrashFiles extends PosixFiles {
  CrashFiles(this.step);
  final String step;
  @override
  void syncFile(int fd) {
    super.syncFile(fd);
    if (step == 'atomic-temp') exit(71);
  }

  @override
  void rename(int dir, String from, String to) {
    super.rename(dir, from, to);
    if (step == 'atomic-rename') exit(72);
  }

  @override
  void syncDirectory(int fd) {
    super.syncDirectory(fd);
    if (step == 'atomic-directory') exit(73);
  }
}
