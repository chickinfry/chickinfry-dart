import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'database.dart';

/// Immutable public request metadata without host resources or credentials.
final class ServerRequest {
  ServerRequest({
    required this.method,
    required this.uri,
    required Map<String, String> headers,
  }) : headers = Map.unmodifiable({
         // Proxy credentials are hop-by-hop (RFC 9110 11.7.2) and must not reach handlers.
         for (final entry in headers.entries)
           if (entry.key.toLowerCase() != 'proxy-authorization')
             entry.key.toLowerCase(): entry.value,
       });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
}

/// A verified session and its public user identity.
final class Session {
  const Session({required this.id, required this.user});
  final String id;
  final SessionUser user;
}

/// Public user identity, distinct from the session identity.
final class SessionUser {
  const SessionUser({required this.id, required this.email});
  final String id;
  final String email;
}

/// Request context for an application without selected resources.
class Context {
  const Context(this.request);
  final ServerRequest request;
  Session? get session => null;
}

/// Requires a verified session before protected application work.
Session requireSession(Context context) =>
    context.session ?? (throw const OperationError('unauthenticated', 401));

/// Internal response consumed by the platform connection.
final class ServerResponse {
  const ServerResponse(this.status, this.body);
  final int status;
  final String body;
}

/// Executes generated dispatch after validating the shared HTTP boundary.
final class Application {
  Application(
    Map<
      String,
      Future<Map<String, Object?>> Function(Context, Map<String, Object?>)
    >
    operations, {
    this._contextFactory,
  }) : _operations = Map.unmodifiable(operations);

  final Map<
    String,
    Future<Map<String, Object?>> Function(Context, Map<String, Object?>)
  >
  _operations;
  final Context Function(ServerRequest, DatabaseConnection?)? _contextFactory;
  static const maxRequestBytes = 4 << 20;
  static final _code = RegExp(r'^[a-z_]{1,64}$');
  static const _statuses = {400, 401, 403, 404, 409, 413, 429, 503};

  Future<ServerResponse> handle(
    ServerRequest request,
    Stream<List<int>> body, {
    String? rawUri,
    DatabaseConnection? connection,
  }) async {
    try {
      final operation =
          _operations[request.uri.path.substring(
            request.uri.path.isEmpty ? 0 : 1,
          )];
      if (request.method != 'POST' ||
          request.uri.hasQuery ||
          (rawUri ?? request.uri.toString()).contains('%') ||
          operation == null) {
        return _error('not_found', 404);
      }
      final contentType = request.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != 'application/json') {
        return _error('unsupported_media_type', 415);
      }
      final bytes = BytesBuilder(copy: true);
      final iterator = StreamIterator(body);
      try {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (chunk.length > maxRequestBytes - bytes.length) {
            return _error('request_too_large', 413);
          }
          bytes.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      Object? input;
      try {
        input = jsonDecode(utf8.decode(bytes.takeBytes()));
      } on FormatException {
        return _error('invalid_json', 400);
      }
      if (input is! Map<String, Object?>) return _error('invalid_input', 400);
      if (request.headers.containsKey('authorization')) {
        return _error('invalid_token', 401);
      }
      final output = await operation(
        _contextFactory?.call(request, connection) ?? Context(request),
        input,
      );
      return ServerResponse(200, jsonEncode(output));
    } on OperationError catch (error) {
      // Status 501 is reserved for the explicit not_implemented contract.
      if (_code.hasMatch(error.code) &&
          (_statuses.contains(error.status) ||
              (error.status == 501 && error.code == 'not_implemented'))) {
        return _error(error.code, error.status);
      }
      return _error('operation_failed', 500);
    } catch (_) {
      return _error('operation_failed', 500);
    }
  }

  static ServerResponse _error(String code, int status) =>
      ServerResponse(status, jsonEncode({'error': code}));
}
