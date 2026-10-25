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
        final source = utf8.decode(bytes.takeBytes());
        final error = _validateJson(source);
        if (error != null) return _error(error, 400);
        input = jsonDecode(source);
      } on FormatException {
        return _error('invalid_json', 400);
      }
      if (input is! Map<String, Object?>) {
        return _error('invalid_input', 400);
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

  // Check raw values before decoding can discard duplicate object members.
  static String? _validateJson(String source) {
    const value = 0, arrayStart = 1, objectStart = 2;
    const key = 3, colon = 4, afterValue = 5;
    // Each open container needs a closing character, so half the input suffices.
    // The request byte limit bounds this stack to at most 2 MiB.
    final containers = Uint8List(source.length ~/ 2);
    // Key storage is bounded by the body; stop collecting after a structure error.
    final objectKeys = List<Set<String>?>.filled(64, null);
    var invalidInput = false;
    var depth = 0;
    var state = value;
    var index = 0;
    bool at(int unit) =>
        index < source.length && source.codeUnitAt(index) == unit;
    bool digits() {
      final start = index;
      while (index < source.length) {
        final unit = source.codeUnitAt(index);
        if (unit < 0x30 || unit > 0x39) break;
        index++;
      }
      return index > start;
    }

    bool string(bool isKey) {
      final decoded = isKey && !invalidInput ? StringBuffer() : null;
      var highSurrogate = false;
      index++;
      while (index < source.length) {
        var unit = source.codeUnitAt(index++);
        if (unit == 0x22) {
          if (highSurrogate) invalidInput = true;
          if (decoded != null && !invalidInput) {
            if (!objectKeys[depth - 1]!.add(decoded.toString())) {
              invalidInput = true;
            }
          }
          return true;
        }
        if (unit < 0x20) return false;
        if (unit == 0x5c) {
          if (index == source.length) return false;
          final escape = source.codeUnitAt(index++);
          if (escape == 0x75) {
            if (index + 4 > source.length) return false;
            unit = 0;
            for (var digit = 0; digit < 4; digit++) {
              final hex = source.codeUnitAt(index++);
              final value = switch (hex) {
                >= 0x30 && <= 0x39 => hex - 0x30,
                >= 0x41 && <= 0x46 => hex - 0x41 + 10,
                >= 0x61 && <= 0x66 => hex - 0x61 + 10,
                _ => -1,
              };
              if (value < 0) return false;
              unit = unit * 16 + value;
            }
          } else {
            unit = switch (escape) {
              0x22 || 0x5c || 0x2f => escape,
              0x62 => 0x08,
              0x66 => 0x0c,
              0x6e => 0x0a,
              0x72 => 0x0d,
              0x74 => 0x09,
              _ => -1,
            };
            if (unit < 0) return false;
          }
        }
        final lowSurrogate = unit >= 0xdc00 && unit <= 0xdfff;
        if (highSurrogate != lowSurrogate) invalidInput = true;
        highSurrogate = unit >= 0xd800 && unit <= 0xdbff;
        decoded?.writeCharCode(unit);
      }
      return false;
    }

    while (index < source.length) {
      final unit = source.codeUnitAt(index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        index++;
        continue;
      }
      if ((state == arrayStart && unit == 0x5d) ||
          (state == objectStart && unit == 0x7d)) {
        depth--;
        if (depth < 64) objectKeys[depth] = null;
        state = afterValue;
        index++;
        continue;
      }
      if (state == afterValue) {
        if (depth == 0) return 'invalid_json';
        final closing = containers[depth - 1];
        if (unit == closing) {
          depth--;
          if (depth < 64) objectKeys[depth] = null;
        } else if (unit == 0x2c) {
          state = closing == 0x7d ? key : value;
        } else {
          return 'invalid_json';
        }
        index++;
        continue;
      }
      if (state == colon) {
        if (unit != 0x3a) return 'invalid_json';
        state = value;
        index++;
        continue;
      }
      if (unit == 0x22) {
        if (!string(state == objectStart || state == key)) {
          return 'invalid_json';
        }
        state = state == objectStart || state == key ? colon : afterValue;
        continue;
      }
      if (state == objectStart || state == key) return 'invalid_json';
      if (unit == 0x7b || unit == 0x5b) {
        if (depth == containers.length) return 'invalid_json';
        if (!invalidInput && depth < 64 && unit == 0x7b) {
          objectKeys[depth] = <String>{};
        }
        containers[depth++] = unit == 0x7b ? 0x7d : 0x5d;
        if (depth > 64) invalidInput = true;
        state = unit == 0x7b ? objectStart : arrayStart;
        index++;
        continue;
      }
      if (unit == 0x2d || (unit >= 0x30 && unit <= 0x39)) {
        final start = index;
        if (at(0x2d)) index++;
        if (at(0x30)) {
          index++;
        } else if (!digits()) {
          return 'invalid_json';
        }
        if (at(0x2e)) {
          index++;
          if (!digits()) return 'invalid_json';
        }
        if (at(0x65) || at(0x45)) {
          index++;
          if (at(0x2b) || at(0x2d)) index++;
          if (!digits()) return 'invalid_json';
        }
        if (!invalidInput &&
            !double.parse(source.substring(start, index)).isFinite) {
          invalidInput = true;
        }
      } else {
        final literal = switch (unit) {
          0x6e => 'null',
          0x74 => 'true',
          0x66 => 'false',
          _ => null,
        };
        if (literal == null || !source.startsWith(literal, index)) {
          return 'invalid_json';
        }
        index += literal.length;
      }
      state = afterValue;
    }
    if (depth != 0 || state != afterValue) return 'invalid_json';
    return invalidInput ? 'invalid_input' : null;
  }

  static ServerResponse _error(String code, int status) =>
      ServerResponse(status, jsonEncode({'error': code}));
}
