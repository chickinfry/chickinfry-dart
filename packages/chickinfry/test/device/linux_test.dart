import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/device/files.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final linuxOnly = Platform.isLinux
      ? false
      : 'Requires the Linux file device.';
  final unavailable = throwsA(
    isA<ClientException>().having(
      (error) => error.code,
      'code',
      'device_storage_unavailable',
    ),
  );

  test('unsupported ABIs fail closed before selecting native symbols', () {
    for (final abi in Abi.values.where(
      (abi) => ![
        Abi.macosArm64,
        Abi.macosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
      ].contains(abi),
    )) {
      expect(() => posixStatSymbol(abi), unavailable);
    }
  });

  test('Linux ACL checks masked access rather than raw permissions', () {
    for (final entry in [2, 4, 8]) {
      for (final mask in [0, 2]) {
        expect(
          () => checkLinuxAcl(
            linuxAcl(directory: true, tag: entry, mask: mask),
            1000,
          ),
          returnsNormally,
        );
      }
      expect(
        () =>
            checkLinuxAcl(linuxAcl(directory: true, tag: entry, mask: 4), 1000),
        unavailable,
      );
    }
    expect(
      () => checkLinuxAcl(linuxAcl(directory: true, other: 4), 1000),
      unavailable,
    );
    expect(
      () =>
          checkLinuxAcl(linuxAcl(directory: true, mask: 4, owner: 1000), 1000),
      returnsNormally,
    );
  });

  test(
    'Linux XDG locations ignore relative values and never use cwd',
    () async {
      final root = await scratch();
      final home = '$root/home';
      for (final xdg in <String?>[null, '', 'relative-state', '$root/xdg']) {
        final expected = xdg == '$root/xdg'
            ? '$root/xdg/chickinfry/device.test'
            : '$home/.local/state/chickinfry/device.test';
        await Directory(expected).create(recursive: true);
        final mode = xdg == '$root/xdg' ? '711' : '755';
        final result = await Process.run('/bin/chmod', [
          mode,
          expected,
        ], includeParentEnvironment: false);
        expect(result.exitCode, 0);
        expect(
          await child(
            'default-location',
            expected,
            'https://xdg.example.test',
            home: home,
            xdgStateHome: xdg,
          ),
          0,
        );
        expect(await Directory(expected).exists(), isTrue);
        expect(
          (await Directory(expected).stat()).mode & 0x1ff,
          int.parse(mode, radix: 8),
        );
      }
      expect(await Directory('$root/relative-state').exists(), isFalse);
      expect(
        await child(
          'default-location',
          '$root/xdg/chickinfry/device.test',
          'https://xdg.example.test',
          home: '',
          xdgStateHome: '$root/xdg',
        ),
        0,
      );
    },
    skip: linuxOnly,
  );

  test('Linux default location failure has no fallback', () async {
    final root = await scratch();
    final blocker = File('$root/blocked')..writeAsStringSync('occupied');
    for (final xdg in [blocker.path, '']) {
      expect(
        await child(
          'default-unavailable',
          root,
          'https://xdg.example.test',
          home: blocker.path,
          xdgStateHome: xdg,
        ),
        0,
      );
    }
    expect(await Directory('$root/chickinfry').exists(), isFalse);
  }, skip: linuxOnly);

  test(
    'POSIX creates private paths and preserves safe existing root modes',
    () async {
      final root = await scratch();
      final private = '$root/device';
      final store = device(private, 'https://permissions.example.test');
      await store.write(credentials());
      final paths = await Directory(private).list(recursive: true).toList();
      for (final path in [Directory(private), ...paths]) {
        final stat = await path.stat();
        expect(
          stat.mode & 0x1ff,
          stat.type == FileSystemEntityType.directory ? 0x1c0 : 0x180,
        );
      }
      for (final mode in ['755', '711', '775', '777']) {
        final result = await Process.run('/bin/chmod', [
          mode,
          private,
        ], includeParentEnvironment: false);
        expect(result.exitCode, 0);
        if (mode == '755' || mode == '711') {
          expect(await store.read() != null, isTrue);
        } else {
          await expectLater(store.load(), unavailable);
        }
        expect(
          (await Directory(private).stat()).mode & 0x1ff,
          int.parse(mode, radix: 8),
        );
      }
    },
    skip: Platform.isMacOS || Platform.isLinux
        ? false
        : 'Requires the macOS or Linux POSIX file device.',
  );

  test(
    'unsafe ancestors report their failed permission check without a path',
    () async {
      final parent = await scratch();
      final result = await Process.run('/bin/chmod', [
        '777',
        parent,
      ], includeParentEnvironment: false);
      expect(result.exitCode, 0);
      try {
        await device(
          '$parent/device',
          'https://permissions.example.test',
        ).load();
        fail('A writable ancestor was accepted.');
      } on ClientException catch (error, stack) {
        expect(error.code, 'device_storage_unavailable');
        expect(
          stack.toString(),
          contains('device storage check=ancestor_mode'),
        );
        expect(stack.toString().contains(parent), isFalse);
      }
      await expectLater(
        child(
          'increment',
          '$parent/device',
          'https://permissions.example.test',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('check=ancestor_mode'),
          ),
        ),
      );
      expect((await Directory(parent).stat()).mode & 0x1ff, 0x1ff);
    },
    skip: Platform.isMacOS || Platform.isLinux
        ? false
        : 'Requires the macOS or Linux POSIX file device.',
  );

  test(
    'Linux preserves masked ACLs and rejects effective foreign access',
    () async {
      final parent = await scratch();
      setLinuxAcl(parent, linuxAcl(directory: true));
      await device('$parent/device', 'https://acl.example.test').load();
      for (final target in [
        'root',
        'intermediate',
        'directory',
        'record',
        'lock',
        'isolate',
      ]) {
        final root = await scratch();
        final store = device(root, 'https://acl.example.test');
        await store.write(credentials());
        final path = switch (target) {
          'root' => root,
          'intermediate' => Directory(store.directory).parent.path,
          'directory' => store.directory,
          'record' => '${store.directory}/auth.json',
          'lock' => '${store.directory}/.lock',
          _ => '${store.directory}/.isolate.lock',
        };
        final record = File('${store.directory}/auth.json');
        final before = await record.readAsBytes();
        for (final mask in [0, 4]) {
          final acl = linuxAcl(
            directory: ['root', 'intermediate', 'directory'].contains(target),
            mask: mask,
          );
          setLinuxAcl(path, acl);
          if (mask == 0) {
            expect(await store.read() != null, isTrue);
          } else {
            await expectLater(store.load(), unavailable);
          }
          expect(
            base64Encode(await record.readAsBytes()) == base64Encode(before),
            isTrue,
          );
          expect(base64Encode(readLinuxAcl(path)) == base64Encode(acl), isTrue);
        }
      }
    },
    skip: linuxOnly,
  );
}

Uint8List linuxAcl({
  required bool directory,
  int tag = 2,
  int mask = 0,
  int other = 0,
  int owner = 0x7ffffffe,
}) {
  final entries = [
    (1, directory ? 7 : 6, 0xffffffff),
    if (tag == 2) (2, 4, owner),
    (4, tag == 4 ? 4 : 0, 0xffffffff),
    if (tag == 8) (8, 4, owner),
    (16, mask, 0xffffffff),
    (32, other, 0xffffffff),
  ];
  final bytes = ByteData(4 + entries.length * 8)
    ..setUint32(0, 2, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final (tag, permission, id) = entries[i];
    bytes
      ..setUint16(4 + i * 8, tag, Endian.little)
      ..setUint16(6 + i * 8, permission, Endian.little)
      ..setUint32(8 + i * 8, id, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void setLinuxAcl(String path, Uint8List bytes) {
  final set = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Size,
          Int32,
        ),
        int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int, int)
      >('setxattr');
  using((arena) {
    final buffer = arena<Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    expect(
      set(
        path.toNativeUtf8(allocator: arena),
        'system.posix_acl_access'.toNativeUtf8(allocator: arena),
        buffer,
        bytes.length,
        0,
      ),
      0,
    );
  });
}

Uint8List readLinuxAcl(String path) {
  final get = DynamicLibrary.process()
      .lookupFunction<
        IntPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Size),
        int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int)
      >('getxattr');
  return using((arena) {
    final buffer = arena<Uint8>(256);
    final size = get(
      path.toNativeUtf8(allocator: arena),
      'system.posix_acl_access'.toNativeUtf8(allocator: arena),
      buffer,
      256,
    );
    expect(size, greaterThan(0));
    return Uint8List.fromList(buffer.asTypedList(size));
  });
}
