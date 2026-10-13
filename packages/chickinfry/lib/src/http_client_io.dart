import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const isNative = true;
final _abortKey = Object();

http.Client createClient(Duration timeout) => _NativeClient(timeout);

class _NativeClient extends IOClient {
  _NativeClient(Duration timeout)
    : super(
        HttpClient()
          ..connectionTimeout = timeout
          ..connectionFactory = _connect,
      );

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) => runZoned(
    () => super.send(request),
    zoneValues: {
      _abortKey: request is http.Abortable ? request.abortTrigger : null,
    },
  );
}

Future<ConnectionTask<Socket>> _connect(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) async {
  if (proxyHost != null) {
    // shortcut: SDK owns proxy CONNECT/TLS cancellation; revisit for prompt proxy socket closure.
    return Socket.startConnect(proxyHost, proxyPort!);
  }
  if (url.scheme != 'https') return Socket.startConnect(url.host, url.port);
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
class _TlsSocket extends Stream<Uint8List> implements Socket {
  _TlsSocket(this._raw) {
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
              final bytes = _raw.read();
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
    unawaited(_raw.close());
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
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Socket.addError is unsupported.');
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
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
  Future<void> flush() => _sink.flush();
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
      var offset = 0;
      while (offset < bytes.length) {
        if (_failed) throw const SocketException('Connection closed.');
        offset += raw.write(bytes, offset);
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
