/// OperationError preserves a server error code and HTTP status.
final class OperationError implements Exception {
  const OperationError(this.code, this.status);

  final String code;
  final int status;

  @override
  String toString() =>
      'Operation failed ($code, HTTP $status). Handle it by branching on '
      'code; for an unexpected code, check the server handler logs for this '
      'operation.';
}

/// ClientException reports a local failure without exposing response details.
final class ClientException implements Exception {
  const ClientException(this.code, {this.status, this.operationError});

  final String code;
  final int? status;
  final OperationError? operationError;

  @override
  String toString() {
    final guidance = switch (code) {
      'unsupported_platform' =>
        'Flutter Web and browser targets are not supported yet; browser '
            'support is planned. Use a native (non-web) platform for now.',
      'invalid_token' =>
        'Invalid bearer token: pass the access token string from your login '
            'result unchanged.',
      'invalid_origin' =>
        'Invalid origin: pass an https:// origin, or http:// only on a '
            'loopback address, with no path, query, fragment, or user info.',
      'invalid_input' =>
        'Invalid input: pass an operation name like service.operation and '
            'a JSON-encodable map.',
      'request_too_large' =>
        'The request body exceeds the 4 MiB limit after JSON encoding; '
            'reduce the payload or split the call.',
      'request_timeout' =>
        'The request exceeded its deadline; the default is 30 seconds, so '
            'pass a larger timeout to HttpTransport if the operation needs '
            'more time.',
      'response_too_large' =>
        'The response exceeded the 1 MiB limit; change the operation to '
            'return less data.',
      'invalid_response' =>
        'The server response was not a valid Chickinfry response; check '
            "that the origin points to your project's server.",
      'network_error' =>
        status == null
            ? 'The request failed before a response arrived; check network '
                  'connectivity and the origin.'
            : 'The connection failed while the response was being read; check '
                  'network connectivity and the origin.',
      'session_storage_error' =>
        'The session store failed while reading or writing credentials; '
            'check your SessionStore implementation and its backing storage.',
      'session_changed' =>
        'The stored session changed during the call; re-read the session '
            'and call again with the current credentials.',
      'invalid_session_record' =>
        'The stored session record is invalid; clear the stored session and '
            'sign in again.',
      _ => null,
    };
    final suffix = status == null ? '' : ', HTTP $status';
    return guidance == null
        ? 'Client failed ($code$suffix).'
        : '$guidance ($code$suffix)';
  }
}
