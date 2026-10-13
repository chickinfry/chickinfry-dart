import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:test/test.dart';

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

class Record {
  Record(this.value);
  SessionCredentials? value;
  bool failRead = false;
  bool corrupt = false;
  bool failReplace = false;
  int replacements = 0;
  int deletions = 0;
}

class MemorySessionStore implements SessionStore {
  MemorySessionStore(this.origin, this.coordinationKey, this.record);
  @override
  final String origin;
  @override
  final String coordinationKey;
  final Record record;

  @override
  Future<SessionCredentials?> read() async {
    if (record.corrupt) throw const ClientException('invalid_session_record');
    if (record.failRead) throw StateError('Private storage failure.');
    return record.value;
  }

  @override
  Future<void> write(SessionCredentials value) async {
    record.value = value;
  }

  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) async {
    if (record.failReplace) throw StateError('Private storage failure.');
    // No await may separate comparison and mutation of the shared record.
    if (record.value != expected) return false;
    record.value = next;
    record.replacements++;
    if (next == null) record.deletions++;
    return true;
  }
}
