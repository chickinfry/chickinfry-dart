import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'database.dart';

/// Immutable request metadata excluding hop-by-hop proxy credentials.
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

/// Request context for an application without selected resources.
class Context {
  const Context(this.request);
  final ServerRequest request;
}

final class ApplicationOptions {
  const ApplicationOptions();
}

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
    this._setup,
  }) : _operations = Map.unmodifiable(operations);

  final Map<
    String,
    Future<Map<String, Object?>> Function(Context, Map<String, Object?>)
  >
  _operations;
  final Context Function(ServerRequest, DatabaseConnection?)? _contextFactory;
  final Future<ApplicationOptions> Function()? _setup;
  Future<ApplicationOptions>? _setupResult;
  static const maxRequestBytes = 4 << 20;
  static final _code = RegExp(r'^[a-z_]{1,64}$');
  static const _statuses = {400, 401, 403, 404, 409, 413, 429, 503};

  /// Called by the platform connection before reporting readiness.
  /// Shares one setup result with [handle], retaining failures without retrying.
  Future<void> prepare() async {
    final setup = _setup;
    if (setup != null) {
      await (_setupResult ??= Future<ApplicationOptions>.sync(setup));
    }
  }

  Future<ServerResponse> handle(
    ServerRequest request,
    Stream<List<int>> body, {
    String? rawUri,
    DatabaseConnection? connection,
  }) async {
    try {
      try {
        await prepare();
      } catch (_) {
        return _error('operation_failed', 500);
      }
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
