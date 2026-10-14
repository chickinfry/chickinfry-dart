import 'dart:async';
import 'dart:convert';

import 'credentials.dart';
import 'driver.dart';
import 'protocol.dart';

final class Server {
  Server(this.credentials, this.emit) {
    driver = Driver(credentials, request);
  }
  final Credentials credentials;
  final Future<void> Function(List<int> bytes) emit;
  late final Driver driver;
  final frames = Frames(16 * 1024 * 1024);
  final seen = <String>{};
  final pending = <String, Completer<Map<String, Object?>>>{};
  final active = <Future<void>>{};
  final _failure = Completer<void>();
  Future<void>? _finishing;
  Future<void> output = Future<void>.value();
  var counter = 0;
  var failed = false;
  var ended = false;
  var handshakeReceived = false;

  Future<void> serve(Stream<List<int>> input) async {
    final eof = Completer<void>();
    final subscription = input.listen(
      add,
      onError: (Object _) => fail(),
      onDone: eof.complete,
    );
    try {
      await Future.any([eof.future, _failure.future]);
    } finally {
      await subscription.cancel();
      await finish();
    }
  }

  Future<void> write(Map<String, Object?> message) {
    if (credentials.exposes(message)) {
      fail();
      throw const DriverError('driver_failed');
    }
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > 16 * 1024 * 1024) violation();
    output = output.then((_) => emit(bytes));
    return output;
  }

  Future<Map<String, Object?>> request(
    String command,
    Map<String, Object?> args,
  ) {
    if (ended || failed) throw const DriverError('driver_failed');
    final id = 'd:${++counter}';
    final result = Completer<Map<String, Object?>>();
    pending[id] = result;
    seen.add(id);
    // Observe rejection before publishing an arrival that can be released immediately.
    final response = result.future;
    unawaited(
      write({'id': id, 'command': command, 'args': args})
          .catchError((Object _) {
            fail();
          }),
    );
    return response;
  }

  void add(List<int> chunk) {
    if (ended || failed) return;
    try {
      for (final line in frames.add(chunk)) {
        receive(object(strictJson(line)));
        if (failed) break;
      }
    } catch (_) {
      fail();
    }
  }

  void receive(Map<String, Object?> message) {
    if (credentials.exposes(message)) violation();
    final id = identifier(message, 'id');
    if (message.containsKey('command')) {
      fields(message, {'id', 'command', 'args'});
      if (!id.startsWith('c:') || !seen.add(id)) violation();
      final command = string(message, 'command');
      final args = object(message['args']);
      if (driver.runId == null) {
        if (command != 'handshake' || handshakeReceived) violation();
        handshakeReceived = true;
      }
      late Future<void> work;
      work = respond(id, command, args).whenComplete(() => active.remove(work));
      active.add(work);
    } else {
      fields(message, {'id', 'result', 'error'});
      final waiter = pending[id];
      if (!id.startsWith('d:') ||
          waiter == null ||
          (message['result'] == null) == (message['error'] == null)) {
        violation();
      }
      if (message['error'] != null) {
        final error = object(message['error']);
        fields(error, {'kind', 'code', 'httpStatus', 'outcomeUnknown'});
        if (error['kind'] != 'driver' ||
            error['httpStatus'] != null ||
            error['outcomeUnknown'] != null) {
          violation();
        }
        final code = string(error, 'code');
        if (!{
          'protocol_violation',
          'deadline_exceeded',
          'driver_failed',
          'invalid_reference',
          'invalid_args',
          'unimplemented',
          'protocol_mismatch',
        }.contains(code)) {
          violation();
        }
        waiter.completeError(DriverError(code));
      } else {
        waiter.complete(object(message['result']));
      }
      pending.remove(id);
    }
  }

  Future<void> respond(
    String id,
    String command,
    Map<String, Object?> args,
  ) async {
    Map<String, Object?>? result;
    Map<String, Object?>? error;
    var fatal = false;
    try {
      final operation = driver.handle(id, command, args);
      final timeout = driver.remaining(id);
      result = timeout == null
          ? await operation
          : await operation.timeout(timeout);
    } on TimeoutException {
      error = const DriverError('deadline_exceeded').toJson();
      fatal = true;
    } on DriverError catch (failure) {
      error = failure.toJson();
      fatal =
          failure.code == 'protocol_violation' ||
          failure.code == 'protocol_mismatch' ||
          failure.code == 'deadline_exceeded';
    } on SdkFailure catch (failure) {
      error = failure.payload;
    } catch (_) {
      error = const DriverError('driver_failed').toJson();
      fatal = true;
    }
    try {
      await write({'id': id, 'result': result, 'error': error});
    } catch (_) {
      fatal = true;
    }
    if (fatal) fail();
  }

  void fail() {
    if (failed) return;
    failed = true;
    _failure.complete();
    driver.close();
    for (final waiter in pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const DriverError('driver_failed'));
      }
    }
    pending.clear();
  }

  Future<void> finish() => _finishing ??= _finish();

  Future<void> _finish() async {
    ended = true;
    try {
      frames.finish();
    } catch (_) {
      fail();
    }
    if (active.isNotEmpty || pending.isNotEmpty) fail();
    await Future.wait(active.toList());
    try {
      await output;
    } catch (_) {
      failed = true;
    }
    driver.dispose();
  }
}
