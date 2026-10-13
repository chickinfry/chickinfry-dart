import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
