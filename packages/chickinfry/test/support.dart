import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chickinfry/chickinfry.dart';
import 'package:test/test.dart';
import 'package:chickinfry/src/testing/conformance.dart';

export 'package:chickinfry/src/testing/session_store.dart';

class Observer implements ConformanceObserver {
  Observer({this.onArrive, this.onRecord});
  final Future<void>? Function(ConformancePoint, ConformanceFacts)? onArrive;
  final void Function(ConformanceEvent)? onRecord;
  @override
  Future<void>? arrive(ConformancePoint point, ConformanceFacts facts) =>
      onArrive?.call(point, facts);
  @override
  void record(ConformanceEvent event) => onRecord?.call(event);
}

ConformanceCall conformanceCall(
  String id,
  String operation,
  Observer observer,
) => ConformanceCall(
  runId: 'run',
  caseId: 'case',
  callId: id,
  operation: operation,
  observer: observer,
);

const accessToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const refreshToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const nextAccessToken = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const nextRefreshToken = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';

SessionCredentials credentials({
  bool rotated = false,
  String session = 'session-one',
  String user = 'user-one',
  String refreshExpiry = '2026-10-20T12:00:00.000000Z',
}) => SessionCredentials(
  accessToken: rotated ? nextAccessToken : accessToken,
  refreshToken: rotated ? nextRefreshToken : refreshToken,
  expiresAt: '2026-10-13T12:15:00.123456Z',
  refreshExpiresAt: refreshExpiry,
  userId: user,
  sessionId: session,
);

TypeMatcher<ClientException> clientFailure(String code, {int? status}) =>
    isA<ClientException>()
        .having((error) => error.code, 'code', code)
        .having((error) => error.status, 'status', status);

Matcher operationFailure(String code, int status) => isA<OperationError>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.status, 'status', status);

Future<Object?> readBody(HttpRequest request) async =>
    jsonDecode(await utf8.decoder.bind(request).join());

Future<void> reply(
  HttpRequest request,
  Object? value, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(value));
  await request.response.close();
}

class Peer {
  Peer._(this.server);
  final HttpServer server;
  int requests = 0;
  String get origin => 'http://127.0.0.1:${server.port}';

  static Future<Peer> start(
    Future<void> Function(HttpRequest request) handle,
  ) async {
    final peer = Peer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    peer.server.listen((request) {
      peer.requests++;
      unawaited(handle(request));
    });
    addTearDown(() => peer.server.close(force: true));
    return peer;
  }

  HttpTransport transport({Duration timeout = const Duration(seconds: 2)}) {
    final result = HttpTransport(origin, timeout: timeout);
    addTearDown(result.close);
    return result;
  }
}

class ControlledRawSocket implements RawSocket {
  ControlledRawSocket(this.chunks, {this.onWrite});
  final List<List<int>> chunks;
  final int Function(List<int>, int, int)? onWrite;
  final buffer = Uint8List(8192);
  final events = StreamController<RawSocketEvent>();
  final readArguments = <int?>[];
  var _next = 0;
  var _queued = false;
  var _closed = false;
  var _readEnabled = false;
  @override
  bool writeEventsEnabled = false;

  void _queueRead() {
    if (_queued || _closed || !_readEnabled || _next == chunks.length) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_closed && _readEnabled) events.add(RawSocketEvent.read);
    });
  }

  @override
  bool get readEventsEnabled => _readEnabled;
  @override
  set readEventsEnabled(bool enabled) {
    _readEnabled = enabled;
    _queueRead();
  }

  @override
  Uint8List? read([int? len]) {
    readArguments.add(len);
    final chunk = chunks[_next++];
    expect(chunk.length, lessThanOrEqualTo(len ?? chunk.length));
    // Reusing the backing exposes a consumer that retains borrowed body views.
    buffer.fillRange(0, buffer.length, 120);
    buffer.setRange(0, chunk.length, chunk);
    _queueRead();
    return Uint8List.view(buffer.buffer, 0, chunk.length);
  }

  @override
  int write(List<int> bytes, [int offset = 0, int? count]) =>
      onWrite?.call(bytes, offset, count ?? bytes.length - offset) ??
      count ??
      bytes.length - offset;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<RawSocket> close() async {
    _closed = true;
    unawaited(events.close());
    return this;
  }

  @override
  void shutdown(SocketDirection direction) {}
  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;
  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;
  @override
  int get port => 12345;
  @override
  int get remotePort => 80;
  @override
  bool setOption(SocketOption option, bool enabled) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected raw socket operation: ${invocation.memberName}',
  );
}

class BridgedHttpClient implements HttpClient {
  BridgedHttpClient(this.client, this.socket);
  final HttpClient client;
  final Socket socket;
  @override
  set connectionTimeout(Duration? timeout) =>
      client.connectionTimeout = timeout;
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? factory,
  ) {
    client.connectionFactory = (_, _, _) async =>
        ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      client.openUrl(method, url);
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected HTTP client operation: ${invocation.memberName}',
  );
}
