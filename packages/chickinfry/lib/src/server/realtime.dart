import '../errors.dart';

/// Sends one realtime host frame for the current request and returns the reply.
typedef RealtimeCall = Future<Map<String, Object?>> Function(
  Map<String, Object?> frame,
);

/// The request-scoped realtime publisher.
final class Realtime {
  Realtime(this._call);

  final RealtimeCall _call;

  /// Publishes one event on [channel] and completes once the engine confirmed
  /// it. [payload] is any JSON value. Engine rejections keep their public code
  /// and status; an unconfirmed outcome is realtime_publish_outcome_unknown.
  Future<void> publish(String channel, Object? payload) async {
    final Map<String, Object?> reply;
    // A call the host never accepted was not sent, so it is a plain failure.
    try {
      reply = await _call({
        'op': 'publish',
        'input': {'channel': channel, 'payload': payload},
      });
    } catch (_) {
      throw const OperationError('operation_failed', 500);
    }
    if (reply.isEmpty) return;
    final error = reply['error'];
    if (reply.length == 1 && error == 'binding_unavailable') {
      throw const OperationError('service_unavailable', 503);
    }
    final status = reply['status'];
    if (reply.length == 2 &&
        error is String &&
        status is int &&
        status >= 400 &&
        status <= 599) {
      throw OperationError(error, status);
    }
    throw const OperationError('operation_failed', 500);
  }
}
