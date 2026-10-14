// The internal driver consumes opt-in hooks without adding a public testing API.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/testing/conformance.dart';

import 'credentials.dart';
import 'protocol.dart';

// This allowlist is independent of the SDK formatter under test.
const _clientGuidance = {
  'unsupported_platform':
      'Flutter Web and browser targets are not supported yet; browser support '
      'is planned. Use a native (non-web) platform for now.',
  'invalid_token':
      'Invalid bearer token: pass the access token string from your login result '
      'unchanged.',
  'invalid_origin':
      'Invalid origin: pass an https:// origin, or http:// only on a loopback '
      'address, with no path, query, fragment, or user info.',
  'invalid_input':
      'Invalid input: pass an operation name like service.operation and a '
      'JSON-encodable map.',
  'request_too_large':
      'The request body exceeds the 4 MiB limit after JSON encoding; reduce the '
      'payload or split the call.',
  'request_timeout':
      'The request exceeded its deadline; the default is 30 seconds, so pass a '
      'larger timeout to HttpTransport if the operation needs more time.',
  'response_too_large':
      'The response exceeded the 1 MiB limit; change the operation to return '
      'less data.',
  'invalid_response':
      'The server response was not a valid Chickinfry response; check that the '
      "origin points to your project's server.",
  'session_storage_error':
      'The session store failed while reading or writing credentials; check your '
      'SessionStore implementation and its backing storage.',
  'session_changed':
      'The stored session changed during the call; re-read the session and call '
      'again with the current credentials.',
  'invalid_session_record':
      'The stored session record is invalid; clear the stored session and sign '
      'in again.',
};
final _errorCode = RegExp(r'^[a-z_]+$');

final class Barrier {
  Barrier(this.ref, this.point, this.participants);
  final String ref;
  final ConformancePoint point;
  final Set<String> participants;
  final arrived = <String>{};
}

typedef Arrive = Future<void> Function(
  Barrier barrier,
  String callId,
  Map<String, Object?> facts,
);

final class Observation implements ConformanceObserver {
  Observation(
    this.id,
    this.operation,
    this.barriers,
    this.flights,
    this.callBarrier,
  );
  final String id;
  final String operation;
  final List<Barrier> barriers;
  final Map<Object, String> flights;
  final Arrive callBarrier;
  final events = <ConformanceEvent>[];

  @override
  Future<void>? arrive(ConformancePoint point, ConformanceFacts facts) {
    if (facts.operation != operation) violation();
    final armed = barriers
        .where(
          (barrier) =>
              barrier.point == point && barrier.participants.contains(id),
        )
        .toList();
    if (armed.isEmpty) return null;
    if (armed.length != 1 || !armed.single.arrived.add(id)) violation();
    final Map<String, Object?> payload;
    switch (point) {
      case ConformancePoint.sdkEntered:
        payload = {'entered': true};
      case ConformancePoint.originalsRejected:
        if (facts.status != 401 || facts.code != 'invalid_token') violation();
        payload = {'httpStatus': facts.status};
      case ConformancePoint.refreshJoined:
        final flight = facts.flight;
        if (flight == null) unimplemented();
        payload = {
          'refreshRef': flights.putIfAbsent(
            flight,
            () => 'flight:${flights.length + 1}',
          ),
        };
    }
    return callBarrier(armed.single, id, payload);
  }

  @override
  void record(ConformanceEvent event) => events.add(event);

  int? get constructorRequests {
    final counts = events.whereType<ConformanceConstruction>().toList();
    return counts.length == 1 ? counts.single.networkEntries : null;
  }

  Map<String, Object?> sdkError(
    Object error,
    ConformanceCall call,
    Credentials credentials, {
    bool construction = false,
  }) {
    final refresh = events.whereType<ConformanceRefreshEvent>().toList();
    final failedRefresh = refresh.isNotEmpty && refresh.last.code != null;
    final observedStatus = failedRefresh
        ? refresh.last.observation?.attempt?.status
        : call.httpObservation?.status;
    final String? code;
    final int? status;
    final bool? rawDetails;
    if (error is OperationError) {
      code = error.code;
      status = error.status;
      final message = error.toString();
      final allowed =
          'Operation failed ($code, HTTP $status). Handle it by branching on '
          'code; for an unexpected code, check the server handler logs for this '
          'operation.';
      rawDetails =
          _errorCode.stringMatch(code) != code ||
          message != allowed ||
          credentials.exposes(message);
    } else if (error is ClientException) {
      code = error.code;
      status = error.status ?? observedStatus;
      final message = error.toString();
      final guidance = code == 'network_error'
          ? error.status == null
                ? 'The request failed before a response arrived; check network '
                      'connectivity and the origin.'
                : 'The connection failed while the response was being read; '
                      'check network connectivity and the origin.'
          : _clientGuidance[code];
      final suffix = error.status == null ? '' : ', HTTP ${error.status}';
      final allowed = guidance == null
          ? 'Client failed ($code$suffix).'
          : '$guidance ($code$suffix)';
      rawDetails =
          _errorCode.stringMatch(code) != code ||
          message != allowed ||
          credentials.exposes(message);
    } else {
      code = null;
      status = null;
      rawDetails = null;
    }
    final bool? unknown;
    if (failedRefresh) {
      unknown = refresh.last.observation?.outcomeUnknown;
    } else if (call.httpAttempts == 0) {
      unknown = false;
    } else {
      unknown = call.httpObservation?.outcomeUnknown;
    }
    return {
      'kind': 'sdk',
      'code':
          code != null &&
              _errorCode.stringMatch(code) == code &&
              !credentials.exposes(code)
          ? code
          : null,
      'httpStatus': status,
      'outcomeUnknown': unknown,
      'rawTransportDetails': rawDetails,
      if (construction) 'constructorNetworkRequests': constructorRequests,
    };
  }

  Map<String, Object?> snapshot(ConformanceCall call, int after) {
    // Missing library retention must never become zero or a complete interval.
    final transport = events.whereType<ConformanceTransportEvent>().toList();
    if (!conformanceEnabled ||
        call.instrumentationFailed ||
        transport.any(
          (event) =>
              event.readBytes == null ||
              event.retainedBytes == null ||
              event.peakRetainedBytes == null,
        )) {
      unimplemented();
    }
    unimplemented();
  }
}
