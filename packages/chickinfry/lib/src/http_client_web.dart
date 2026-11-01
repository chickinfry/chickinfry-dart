import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'errors.dart';

const isNative = false;
const isSupported = true;

http.Client createClient(Duration timeout) => _CookieClient();

final class _CookieClient extends http.BaseClient {
  final _active = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw const ClientError('failed_precondition');
    final controller = web.AbortController();
    _active.add(controller);
    var handedOff = false;
    try {
      if (request case http.Abortable(:final abortTrigger?)) {
        unawaited(
          abortTrigger.then((_) {
            if (_active.contains(controller)) controller.abort();
          }),
        );
      }
      final bytes = await request.finalize().toBytes();
      final response = await web.window
          .fetch(
            request.url.toString().toJS,
            web.RequestInit(
              method: 'POST',
              body: bytes.toJS,
              headers:
                  {
                        'content-type': 'application/json',
                        'x-chik-browser': '1',
                      }.jsify()!
                      as web.HeadersInit,
              credentials: 'include',
              cache: 'no-store',
              redirect: 'manual',
              signal: controller.signal,
            ),
          )
          .toDart;
      if (response.type == 'opaqueredirect' ||
          (response.status >= 300 && response.status < 400)) {
        throw ClientError(
          'internal',
          status: response.status == 0 ? null : response.status,
        );
      }
      final stream = response.body;
      if (stream == null) {
        throw ClientError('internal', status: response.status);
      }
      final reader = web.ReadableStreamDefaultReader(stream);
      handedOff = true;
      return http.StreamedResponse(
        _read(reader, controller),
        response.status,
        request: request,
      );
    } finally {
      if (!handedOff) {
        controller.abort();
        _active.remove(controller);
      }
    }
  }

  Stream<List<int>> _read(
    web.ReadableStreamDefaultReader reader,
    web.AbortController controller,
  ) async* {
    var complete = false;
    try {
      while (true) {
        final chunk = await reader.read().toDart;
        if (chunk.done) {
          complete = true;
          return;
        }
        yield (chunk.value! as JSUint8Array).toDart;
      }
    } finally {
      if (!complete) {
        // Cancel the reader as well as Fetch when a deadline or byte limit wins.
        try {
          await reader.cancel().toDart;
        } catch (_) {}
        controller.abort();
      }
      reader.releaseLock();
      _active.remove(controller);
    }
  }

  @override
  void close() {
    _closed = true;
    for (final controller in _active) {
      controller.abort();
    }
    _active.clear();
  }
}
