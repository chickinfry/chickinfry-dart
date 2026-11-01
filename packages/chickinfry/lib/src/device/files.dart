import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';
import 'store.dart' show devicePayloadLimit;

String posixStatSymbol(Abi abi) => switch (abi) {
  Abi.macosX64 => r'fstat$INODE64',
  Abi.macosArm64 || Abi.linuxX64 || Abi.linuxArm64 => 'fstat',
  _ => throw const ClientError('failed_precondition'),
};

Never _rejectStorage(String check) => Error.throwWithStackTrace(
  const ClientError('failed_precondition'),
  StackTrace.fromString('device storage check=$check\n${StackTrace.current}'),
);

void checkLinuxAcl(Uint8List bytes, int uid) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 28 ||
      (bytes.length - 4) % 8 != 0 ||
      data.getUint32(0, Endian.little) != 2) {
    _rejectStorage('acl_format');
  }
  var mask = 7;
  for (var offset = 4; offset < bytes.length; offset += 8) {
    final tag = data.getUint16(offset, Endian.little);
    final permission = data.getUint16(offset + 2, Endian.little);
    if (permission > 7 || !const [1, 2, 4, 8, 16, 32].contains(tag)) {
      _rejectStorage('acl_format');
    }
    if (tag == 16) mask = permission;
  }
  for (var offset = 4; offset < bytes.length; offset += 8) {
    final tag = data.getUint16(offset, Endian.little);
    if (tag == 16) continue;
    final permission = data.getUint16(offset + 2, Endian.little);
    final owner = data.getUint32(offset + 4, Endian.little);
    final ownerEntry = tag == 1 || (tag == 2 && owner == uid);
    final effective = const [2, 4, 8].contains(tag)
        ? permission & mask
        : permission;
    if (!ownerEntry && effective != 0) _rejectStorage('acl_access');
  }
}

// Darwin's flock and fcntl locks conflict, so they use separate sidecars.
class PosixFiles {
  PosixFiles() {
    posixStatSymbol(Abi.current());
  }

  static final _linux = Platform.isLinux;
  static final _linuxArm64 = Abi.current() == Abi.linuxArm64;
  static final _lib = DynamicLibrary.process();
  static final _openat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
        int Function(int, Pointer<Utf8>, int, int)
      >('openat');
  static final _mkdirat = _linux
      ? _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Uint32),
          int Function(int, Pointer<Utf8>, int)
        >('mkdirat')
      : _lib.lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Uint16),
          int Function(int, Pointer<Utf8>, int)
        >('mkdirat');
  static final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _fsync = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final _flock = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _read = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  static final _write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _renameat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>)
      >('renameat');
  static final _unlinkat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int)
      >('unlinkat');
  static final _fstat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >(posixStatSymbol(Abi.current()));
  static final _fgetxattr = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Size),
        int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
      >('fgetxattr');
  static final _aclGetFd = _lib
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32),
        Pointer<Void> Function(int, int)
      >('acl_get_fd_np');
  static final _aclFree = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free');
  static final _aclEntry = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('acl_get_entry');
  static final _aclTag = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Int32>)
      >('acl_get_tag_type');
  static final _aclQualifier = _lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('acl_get_qualifier');
  static final _uidUuid = _lib
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('mbr_uid_to_uuid');
  static final _uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  );
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        _linux ? '__errno_location' : '__error',
      );
  static final _pending = <String, Future<void>>{};
  static final _nofollow = _linux ? (_linuxArm64 ? 0x8000 : 0x20000) : 0x100;
  static final _cloexec = _linux ? 0x80000 : 0x1000000;
  static final _directory = _linux
      ? (_linuxArm64 ? 0x4000 : 0x10000)
      : 0x100000;
  static final _create = _linux ? 0x40 : 0x200;
  static final _exclusive = _linux ? 0x80 : 0x800;
  static final _nonblock = _linux ? 0x800 : 4;
  static const _readwrite = 2;

  Never _failure() => throw ClientError(
    _errno().value == 28 || _errno().value == (_linux ? 122 : 69)
        ? 'resource_exhausted'
        : 'failed_precondition',
  );

  int _open(int parent, String name, int flags, [int mode = 0]) {
    final path = name.toNativeUtf8();
    try {
      final fd = _openat(
        parent,
        path,
        flags | _nofollow | _cloexec | _nonblock,
        mode,
      );
      if (fd < 0) _failure();
      return fd;
    } finally {
      calloc.free(path);
    }
  }

  void _check(
    int fd, {
    required bool directory,
    bool private = true,
    bool userOwned = false,
  }) {
    // glibc and musl share these prefixes on Linux x86_64 and aarch64.
    final memory = calloc<Uint8>(256);
    try {
      if (_fstat(fd, memory) != 0) _failure();
      final data = ByteData.sublistView(memory.asTypedList(256));
      final mode = _linux
          ? data.getUint32(_linuxArm64 ? 16 : 24, Endian.host)
          : data.getUint16(4, Endian.host);
      final owner = data.getUint32(
        _linux ? (_linuxArm64 ? 24 : 28) : 16,
        Endian.host,
      );
      final links = _linux
          ? (_linuxArm64
                ? data.getUint32(20, Endian.host)
                : data.getUint64(16, Endian.host))
          : data.getUint16(6, Endian.host);
      final kind = mode & 0xf000;
      final role = !directory
          ? 'file'
          : userOwned
          ? 'root'
          : private
          ? 'private'
          : 'ancestor';
      if (kind != (directory ? 0x4000 : 0x8000)) {
        _rejectStorage('${role}_type');
      }
      if ((userOwned || private)
          ? owner != _uid()
          : owner != 0 && owner != _uid()) {
        _rejectStorage('${role}_owner');
      }
      if (private ? (mode & 0x3f) != 0 : (mode & 0x12) != 0) {
        _rejectStorage('${role}_mode');
      }
      if (!directory && links != 1) _rejectStorage('file_links');
      if (private || userOwned) _checkAcl(fd);
    } finally {
      calloc.free(memory);
    }
  }

  void _checkAcl(int fd) {
    if (_linux) {
      _checkLinuxAcl(fd);
      return;
    }
    final acl = _aclGetFd(fd, 0x100);
    if (acl == nullptr) {
      // Darwin uses ENOENT for an absent ACL on an open descriptor.
      if (_errno().value == 2) return;
      _failure();
    }
    final entry = calloc<Pointer<Void>>();
    final tag = calloc<Int32>();
    try {
      var selector = 0;
      while (true) {
        if (_aclEntry(acl, selector, entry) != 0) {
          if (_errno().value == 22) break;
          _failure();
        }
        selector = -1;
        if (_aclTag(entry.value, tag) != 0) _failure();
        if (tag.value == 2) continue;
        if (tag.value != 1) _failure();
        final principal = _aclQualifier(entry.value);
        if (principal == nullptr) _failure();
        final owner = calloc<Uint8>(16);
        try {
          if (_uidUuid(_uid(), owner) != 0) _failure();
          for (var i = 0; i < 16; i++) {
            if (principal[i] != owner[i]) {
              throw const ClientError('failed_precondition');
            }
          }
        } finally {
          _aclFree(principal.cast());
          calloc.free(owner);
        }
      }
    } finally {
      calloc.free(entry);
      calloc.free(tag);
      _aclFree(acl);
    }
  }

  void _checkLinuxAcl(int fd) {
    final name = 'system.posix_acl_access'.toNativeUtf8();
    // Linux limits each xattr to 64 KiB; one read avoids a size/read race.
    final memory = calloc<Uint8>(65536);
    try {
      final size = _fgetxattr(fd, name, memory, 65536);
      if (size < 0) {
        if (_errno().value == 61) return; // ENODATA: no access ACL.
        _failure();
      }
      checkLinuxAcl(memory.asTypedList(size), _uid());
    } finally {
      calloc.free(memory);
      calloc.free(name);
    }
  }

  int _directoryFd(String path, String root) {
    if (!path.startsWith('/') ||
        path.contains('\x00') ||
        path.split('/').contains('..')) {
      throw const ClientError('failed_precondition');
    }
    var fd = _open(_linux ? -100 : -2, '/', _directory);
    try {
      final parts = path
          .split('/')
          .where((part) => part.isNotEmpty && part != '.')
          .toList();
      final privateFrom = root
          .split('/')
          .where((part) => part.isNotEmpty && part != '.')
          .length;
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i].toNativeUtf8();
        try {
          final created = _mkdirat(fd, part, 0x1c0);
          if (created != 0 && _errno().value != 17) {
            _failure();
          }
          if (created == 0 && _fsync(fd) != 0) _failure();
        } finally {
          calloc.free(part);
        }
        final next = _open(fd, parts[i], _directory);
        _close(fd);
        fd = next;
        _check(
          fd,
          directory: true,
          private: i >= privateFrom,
          userOwned: i == privateFrom - 1,
        );
      }
      return fd;
    } catch (_) {
      _close(fd);
      rethrow;
    }
  }

  Future<T> locked<T>(
    String directory,
    Future<T> Function(int directoryFd) body, {
    required String root,
  }) async {
    final previous = _pending[directory];
    final complete = Completer<void>();
    _pending[directory] = complete.future;
    if (previous != null) await previous;
    var dir = -1;
    var descriptor = -1;
    RandomAccessFile? lock;
    var acquired = false;
    try {
      dir = _directoryFd(directory, root);
      descriptor = _open(dir, '.isolate.lock', _readwrite | _create, 0x180);
      _check(descriptor, directory: false);
      final elapsed = Stopwatch()..start();
      while (_flock(descriptor, 2 | 4) != 0) {
        if (_errno().value != (_linux ? 11 : 35) ||
            elapsed.elapsed > const Duration(seconds: 5)) {
          _failure();
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final recordLock = _open(dir, '.lock', _readwrite | _create, 0x180);
      try {
        _check(recordLock, directory: false);
      } finally {
        _close(recordLock);
      }
      lock = await File('$directory/.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      acquired = true;
      return await body(dir);
    } on FileSystemException catch (error) {
      throw ClientError(
        error.osError?.errorCode == 28
            ? 'resource_exhausted'
            : 'failed_precondition',
      );
    } finally {
      try {
        if (lock != null) {
          try {
            if (acquired) await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        if (descriptor >= 0) {
          _flock(descriptor, 8);
          _close(descriptor);
        }
        if (dir >= 0) _close(dir);
        complete.complete();
        if (identical(_pending[directory], complete.future)) {
          _pending.remove(directory);
        }
      }
    }
  }

  int readChunk(int fd, Pointer<Uint8> buffer, int length) =>
      _read(fd, buffer, length);

  Uint8List? read(int directoryFd, String name) {
    final path = name.toNativeUtf8();
    final int fd;
    try {
      fd = _openat(directoryFd, path, _nofollow | _cloexec | _nonblock, 0);
      if (fd < 0) {
        if (_errno().value == 2) return null;
        _failure();
      }
    } finally {
      calloc.free(path);
    }
    try {
      _check(fd, directory: false);
      final result = BytesBuilder(copy: false);
      final memory = calloc<Uint8>(4096);
      try {
        while (true) {
          final count = readChunk(fd, memory, 4096);
          if (count < 0) _failure();
          if (count == 0) break;
          if (result.length + count > devicePayloadLimit) {
            throw const ClientError('data_loss');
          }
          result.add(Uint8List.fromList(memory.asTypedList(count)));
        }
        return result.takeBytes();
      } finally {
        calloc.free(memory);
      }
    } finally {
      _close(fd);
    }
  }

  void syncFile(int fd) {
    if (_fsync(fd) != 0) _failure();
  }

  void syncDirectory(int fd) {
    if (_fsync(fd) != 0) _failure();
  }

  void rename(int dir, String from, String to) {
    final source = from.toNativeUtf8();
    final target = to.toNativeUtf8();
    try {
      if (_renameat(dir, source, dir, target) != 0) _failure();
    } finally {
      calloc.free(source);
      calloc.free(target);
    }
  }

  void writeAtomic(int dir, String name, Uint8List bytes) {
    final temporary =
        '.$name.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final fd = _open(dir, temporary, _readwrite | _create | _exclusive, 0x180);
    var renamed = false;
    try {
      _check(fd, directory: false);
      final memory = calloc<Uint8>(bytes.length);
      try {
        memory.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final count = _write(fd, memory + offset, bytes.length - offset);
          if (count <= 0) _failure();
          offset += count;
        }
        syncFile(fd);
      } finally {
        calloc.free(memory);
      }
      rename(dir, temporary, name);
      renamed = true;
      syncDirectory(dir);
    } finally {
      _close(fd);
      if (!renamed) {
        final path = temporary.toNativeUtf8();
        try {
          _unlinkat(dir, path, 0);
        } finally {
          calloc.free(path);
        }
      }
    }
  }
}
