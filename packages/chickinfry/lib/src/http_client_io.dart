import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'testing/conformance.dart';

const isNative = true;
const isSupported = true;
final _abortKey = Object();

const _readCap = 8192;
// Dart pins da6595cd6bb5d4c0a185d759a025e879ff06e631 (3.13.0) and
// 04bcd1036cdc799ac6564988f159ee454d42c822 (3.13.5): socket.cc:531-565,
// http_parser.dart:907-968, stream_impl.dart:1025-1049,1108-1117.
// Raw short-read overlap (2C), parser (C), iterator (C), owned-copy handoff (C)
// total 5C = 40,960 bytes, independent of body length and below 64 KiB.
// Plaintext excludes these transient slots; retained counts owned body copies.
const _plainTransientBytes = 5 * _readCap;
// Same Dart pins: secure_socket_patch.dart:57-79 (2*8192 + 2*10240 rings),
// secure_socket_filter.cc:43-45,395-420,504-505 (2*10240 BIO),
// secure_socket.dart:1136-1165 (2*10240 raw staging). BoringSSL pin
// 2e508c973d634b3aa51b71db5062bc6b096e5031: ssl_buffer.cc:49-93,
// internal.h:1003-1052,2809-2816 (4*65535 resize overlap + 2*5 inline).
// Fixed allocations total 380,934 including 5C, rounded up to 384 KiB.
const _tlsRetainedBytes = 384 * 1024;

// Internal access to the production bridge for native read/pause/backing tests.
Socket createSocketForTesting(RawSocket raw) =>
    _TlsSocket(_PlainRawSocket(raw));

http.Client createClient(Duration timeout) => _NativeClient(timeout);

class _NativeClient extends IOClient {
  _NativeClient(Duration timeout)
    : super(
        HttpClient()
          ..connectionTimeout = timeout
          ..connectionFactory = _connect,
      );

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) {
    if (conformanceEnabled) {
      currentConformanceConstruction?.enterHttpSend();
    }
    final result = runZoned(
      () => super.send(request),
      zoneValues: {
        _abortKey: request is http.Abortable ? request.abortTrigger : null,
      },
    );
    return conformanceEnabled ? _observeResponse(result) : result;
  }
}

// Keep observation captures out of the off-mode request closure context.
Future<IOStreamedResponse> _observeResponse(Future<IOStreamedResponse> result) {
  final attempt = currentConformanceCall?.httpObservation;
  final profiled =
      !const bool.fromEnvironment('dart.vm.product') &&
      HttpClient.enableTimelineLogging;
  return result.then((response) {
    final encoding = response.headers['content-encoding']?.trim().toLowerCase();
    if (attempt != null) {
      attempt.confirmRetainedBytes(
        Platform.version,
        profiled:
            profiled ||
            (!const bool.fromEnvironment('dart.vm.product') &&
                HttpClient.enableTimelineLogging),
        encoding: encoding,
      );
    }
    return response;
  });
}

Future<ConnectionTask<Socket>> _connect(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) async {
  if (conformanceEnabled) {
    currentConformanceConstruction?.enterSocket();
  }
  if (proxyHost != null) {
    if (conformanceEnabled) {
      currentConformanceCall?.httpObservation?.socketBytesWritten = null;
    }
    // shortcut: SDK owns proxy CONNECT/TLS cancellation; revisit for prompt proxy socket closure.
    return Socket.startConnect(proxyHost, proxyPort!);
  }
  if (url.scheme != 'https') {
    if (conformanceEnabled) {
      currentConformanceCall?.httpObservation?.socketBytesWritten = 0;
    }
    final pending = await RawSocket.startConnect(url.host, url.port);
    return ConnectionTask.fromSocket(
      pending.socket.then<Socket>((raw) => _TlsSocket(_PlainRawSocket(raw))),
      pending.cancel,
    );
  }
  if (conformanceEnabled) {
    currentConformanceCall?.httpObservation?.socketBytesWritten = 0;
  }
  final abort = Zone.current[_abortKey] as Future<void>?;
  ConnectionTask<RawSocket>? pending;
  RawSocket? raw;
  var cancelled = false;
  var connected = false;
  void cancel() {
    if (connected) return;
    cancelled = true;
    pending?.cancel();
    final socket = raw;
    if (socket != null) unawaited(socket.close());
  }

  if (abort != null) unawaited(abort.then((_) => cancel()));
  pending = await RawSocket.startConnect(url.host, url.port);
  if (cancelled) pending.cancel();
  final socket = pending.socket.then<Socket>((tcp) async {
    raw = tcp;
    if (cancelled) {
      await tcp.close();
      throw http.RequestAbortedException(url);
    }
    try {
      // SecureSocket.startConnect cannot cancel TCP after TLS takes ownership.
      final tls = await RawSecureSocket.secure(tcp, host: url.host);
      if (cancelled) {
        await tls.close();
        throw http.RequestAbortedException(url);
      }
      connected = true;
      return _TlsSocket(tls);
    } catch (_) {
      await tcp.close();
      rethrow;
    }
  });
  return ConnectionTask.fromSocket(socket, cancel);
}

// HttpClient retains HTTP parsing; this adapter only bridges raw TLS to Socket.
// Plaintext uses the same bounded byte path with instrumentation on or off.
class _PlainRawSocket implements RawSecureSocket {
  _PlainRawSocket(this.raw);
  final RawSocket raw;
  @override
  Uint8List? read([int? len]) => raw.read(len);
  @override
  int write(List<int> buffer, [int offset = 0, int? count]) =>
      raw.write(buffer, offset, count);
  @override
  bool get readEventsEnabled => raw.readEventsEnabled;
  @override
  set readEventsEnabled(bool value) => raw.readEventsEnabled = value;
  @override
  bool get writeEventsEnabled => raw.writeEventsEnabled;
  @override
  set writeEventsEnabled(bool value) => raw.writeEventsEnabled = value;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => raw.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<RawSocket> close() => raw.close();
  @override
  void shutdown(SocketDirection direction) => raw.shutdown(direction);
  @override
  InternetAddress get address => raw.address;
  @override
  InternetAddress get remoteAddress => raw.remoteAddress;
  @override
  int get port => raw.port;
  @override
  int get remotePort => raw.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => raw.setRawOption(option);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Secure socket operations are unavailable on plaintext connections.',
  );
}

class _TlsSocket extends Stream<Uint8List> implements Socket {
  _TlsSocket(this._raw) {
    assert(_plainTransientBytes <= 64 * 1024);
    // Pinned BoringSSL ssl/ssl_buffer.cc:49-93 and
    // ssl/internal.h:1003-1052,2809-2816 require both old/new allocations.
    assert(
      _tlsRetainedBytes >=
          2 * 8192 +
              2 * 10240 +
              2 * 10240 +
              4 * 65535 +
              2 * 5 +
              2 * 10240 +
              _plainTransientBytes,
    );
    // The same Dart pins: stream_impl.dart:308-315,470-499,1025-1049;
    // http 1.6.0 lib/src/io_client.dart:155-201 (archive SHA-256
    // 87721a4a50b19c7f1d49001e51409bddc46303966ce89a65af4f4e6004896412)
    // forwards synchronously and propagates pause.
    // Async delivery would invalidate the bounded parser/iterator handoff proof.
    _input = StreamController<Uint8List>(
      sync: true,
      onListen: () => _raw.readEventsEnabled = true,
      onPause: () => _raw.readEventsEnabled = false,
      onResume: () => _raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _writer = _TlsWriter(_raw);
    _sink = IOSink(_writer);
    _raw
      ..readEventsEnabled = false
      ..writeEventsEnabled = false
      ..listen(
        (event) {
          switch (event) {
            case RawSocketEvent.read:
              if (_destroyed || _input.isPaused || !_input.hasListener) break;
              final bytes = _raw.read(_readCap);
              if (bytes != null) _input.add(bytes);
            case RawSocketEvent.write:
              _writer.writable();
            case RawSocketEvent.readClosed:
              unawaited(_input.close());
            case RawSocketEvent.closed:
              destroy();
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!_input.isClosed) _input.addError(error, stack);
          destroy();
        },
        onDone: destroy,
      );
  }

  final RawSecureSocket _raw;
  late final StreamController<Uint8List> _input;
  late final _TlsWriter _writer;
  late final IOSink _sink;
  var _destroyed = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _writer.fail();
    if (conformanceEnabled) {
      final observation = _writer.observation;
      unawaited(_raw.close().then((_) => observation?.observeCancel()));
    } else {
      unawaited(_raw.close());
    }
    unawaited(_input.close());
  }

  @override
  InternetAddress get address => _raw.address;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get port => _raw.port;
  @override
  int get remotePort => _raw.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void add(List<int> data) {
    if (conformanceEnabled) {
      _writer.observation = currentConformanceCall?.httpObservation;
    }
    _sink.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Socket.addError is unsupported.');
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    if (conformanceEnabled) {
      _writer.observation = currentConformanceCall?.httpObservation;
    }
    return _sink.addStream(stream);
  }

  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  Future<void> flush() {
    if (conformanceEnabled) {
      return observeRequestSent(_sink.flush(), _writer.observation);
    }
    return _sink.flush();
  }

  @override
  Future<void> close() async => _sink.close();
  @override
  Future<void> get done async => _sink.done;

  // Socket's private detach method is unused by direct HTTP connections.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Socket detachment is unsupported.');
}

class _TlsWriter implements StreamConsumer<List<int>> {
  _TlsWriter(this.raw);
  final RawSecureSocket raw;
  ConformanceHttpAttempt? observation;
  Completer<void>? _ready;
  var _failed = false;

  void writable() {
    raw.writeEventsEnabled = false;
    final ready = _ready;
    _ready = null;
    ready?.complete();
  }

  void fail() {
    _failed = true;
    final ready = _ready;
    _ready = null;
    ready?.completeError(const SocketException('Connection closed.'));
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      if (conformanceEnabled) {
        observation?.pendingSocketBytes = bytes.length;
      }
      var offset = 0;
      while (offset < bytes.length) {
        if (_failed) throw const SocketException('Connection closed.');
        if (conformanceEnabled) {
          observation?.observeConnection(
            this,
            raw is _PlainRawSocket ? 0 : _tlsRetainedBytes,
          );
          final written = raw.write(bytes, offset);
          offset += written;
          final attempt = observation;
          if (attempt != null) {
            attempt.socketBytesWritten =
                (attempt.socketBytesWritten ?? 0) + written;
            attempt.pendingSocketBytes = bytes.length - offset;
          }
        } else {
          offset += raw.write(bytes, offset);
        }
        if (offset < bytes.length) {
          final ready = _ready = Completer<void>();
          raw.writeEventsEnabled = true;
          await ready.future;
        }
      }
    }
  }

  @override
  Future<void> close() async => raw.shutdown(SocketDirection.send);
}
