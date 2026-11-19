/// FieldError identifies a validation failure at an input path.
final class FieldError {
  const FieldError(this.path, this.code);

  final String path;
  final String code;
}

/// OperationError preserves a server error code, HTTP status, and description.
final class OperationError implements Exception {
  const OperationError(
    this.code,
    this.status, [
    this.message,
    this.fields = const [],
  ]);

  final String code;
  final int status;
  final String? message;
  final List<FieldError> fields;

  String? get responseMessage => message;

  @override
  String toString() =>
      'Operation failed ($code, HTTP $status). Handle it by branching on '
      'code; for an unexpected code, check the server handler logs for this '
      'operation.';
}

/// ClientError reports a local failure without exposing response details.
final class ClientError implements Exception {
  const ClientError(this.code, {this.status, this.operationError, this.cause});

  final String code;
  final int? status;
  final OperationError? operationError;
  final Object? cause;

  @override
  String toString() {
    final guidance = switch (code) {
      'invalid_argument' => 'Check the origin, operation name, JSON input, timeout, and credentials.',
      'failed_precondition' => 'Check the current session, transport, and session storage before calling again.',
      'resource_exhausted' => 'Reduce the request or response size, or free space in session storage.',
      'deadline_exceeded' => 'The request exceeded its deadline; check connectivity or increase the timeout.',
      'canceled' => 'The request was canceled.',
      'unavailable' =>
        status == null
            ? 'The request failed before a response arrived; check network '
                  'connectivity and the origin.'
            : 'The connection failed while the response was being read; check '
                  'network connectivity and the origin.',
      'data_loss' => 'Stored session data could not be read. Sign out to clear it, then sign in again.',
      'unimplemented' => 'Use a supported platform, authentication transport, and storage version.',
      'internal' => 'The response or client state was invalid; check the server origin and update the SDK.',
      'unauthenticated' => 'A valid session is required.',
      _ => null,
    };
    final suffix = status == null ? '' : ', HTTP $status';
    return guidance == null
        ? 'Client failed ($code$suffix).'
        : '$guidance ($code$suffix)';
  }
}
