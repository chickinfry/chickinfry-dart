/// OperationError preserves a server error code, HTTP status, and received description.
final class OperationError implements Exception {
  const OperationError(this.code, this.status, {this.responseMessage});

  final String code;
  final int status;
  final String? responseMessage;

  @override
  String toString() =>
      'Operation failed ($code, HTTP $status). Handle it by branching on '
      'code; for an unexpected code, check the server handler logs for this '
      'operation.';
}

/// ClientError reports a local failure without exposing response details.
final class ClientError implements Exception {
  const ClientError(this.code, {this.status, this.operationError});

  final String code;
  final int? status;
  final OperationError? operationError;

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
      'unauthenticated' => 'Sign in again before making this call.',
      _ => null,
    };
    final suffix = status == null ? '' : ', HTTP $status';
    return guidance == null
        ? 'Client failed ($code$suffix).'
        : '$guidance ($code$suffix)';
  }
}
