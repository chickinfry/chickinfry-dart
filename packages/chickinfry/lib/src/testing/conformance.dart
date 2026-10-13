import 'dart:async';

import '../errors.dart';
import '../session.dart';

const conformanceEnabled = bool.fromEnvironment(
  'chickinfry.conformance',
  defaultValue: false,
);

enum ConformancePoint { sdkEntered, originalsRejected, refreshJoined }

enum ConformancePhase { sending, response, bodyComplete, completed, failed }

abstract interface class ConformanceObserver {
  /// Returns null for unarmed barriers to avoid asynchronous waiting.
  Future<void>? arrive(ConformancePoint point, ConformanceFacts facts);
  void record(ConformanceEvent event);
}

final class ConformanceFacts {
  const ConformanceFacts({
    required this.operation,
    this.credentials,
    this.attempt,
    this.code,
    this.status,
    this.flight,
    this.initiator,
  });

  final String operation;
  final SessionCredentials? credentials;
  final int? attempt;
  final String? code;
  final int? status;
  final Object? flight;
  final bool? initiator;
}

abstract class ConformanceEvent {}

final class ConformanceHttpEvent extends ConformanceEvent {
  ConformanceHttpEvent(
    this.attempt,
    this.operation,
    this.phase,
    this.status,
    this.bodyComplete,
  );
  final int attempt;
  final String operation;
  final ConformancePhase phase;
  final int? status;
  final bool bodyComplete;
}

final class ConformanceHttpAttempt {
  ConformanceHttpAttempt(this.call, this.operation)
    : attempt = ++call.httpAttempts;
  final ConformanceCall call;
  final String operation;
  final int attempt;
  bool bodyComplete = false;
  bool completed = false;

  void record(ConformancePhase phase, int? status) {
    if (phase == ConformancePhase.bodyComplete) bodyComplete = true;
    call.record(
      ConformanceHttpEvent(attempt, operation, phase, status, bodyComplete),
    );
  }

  void finish(int? status) => record(
    completed ? ConformancePhase.completed : ConformancePhase.failed,
    status,
  );
}

void observeHttp(String operation) {
  final call = currentConformanceCall;
  if (call != null) {
    call.httpObservation = ConformanceHttpAttempt(call, operation);
  }
}

final class ConformanceRefreshEvent extends ConformanceEvent {
  ConformanceRefreshEvent(this.flight, this.code, this.status);
  final Object flight;
  final String? code;
  final int? status;
}

final class ConformanceCall {
  ConformanceCall({
    required this.runId,
    required this.caseId,
    required this.callId,
    required this.operation,
    required this.observer,
  });
  final String runId;
  final String caseId;
  final String callId;
  final String operation;
  final ConformanceObserver observer;
  bool instrumentationFailed = false;
  int httpAttempts = 0;
  ConformanceHttpAttempt? httpObservation;

  Future<void>? arrive(ConformancePoint point, ConformanceFacts facts) {
    try {
      return observer
          .arrive(point, facts)
          ?.then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {
              instrumentationFailed = true;
            },
          );
    } catch (_) {
      instrumentationFailed = true;
      return null;
    }
  }

  void record(ConformanceEvent event) {
    try {
      observer.record(event);
    } catch (_) {
      instrumentationFailed = true;
    }
  }
}

ConformanceCall? get currentConformanceCall => conformanceEnabled
    ? Zone.current[#chickinfryConformanceCall] as ConformanceCall?
    : null;

R withConformanceCall<R>(ConformanceCall call, R Function() body) =>
    conformanceEnabled
    ? runZoned(body, zoneValues: {#chickinfryConformanceCall: call})
    : body();

Future<SessionCredentials> observeRefresh(
  Future<SessionCredentials> result,
  Object flight,
  SessionCredentials expected, {
  required bool initiator,
}) {
  final call = currentConformanceCall;
  if (call == null) return result;
  // Attach the error handler before the barrier to avoid unhandled shared Future errors.
  final outcome = result.then<(SessionCredentials?, Object?, StackTrace?)>(
    (value) => (value, null, null),
    onError: (Object error, StackTrace stack) => (null, error, stack),
  );
  return () async {
    final barrier = call.arrive(
      ConformancePoint.refreshJoined,
      ConformanceFacts(
        operation: call.operation,
        credentials: expected,
        flight: flight,
        initiator: initiator,
      ),
    );
    if (barrier != null) await barrier;
    final (value, error, stack) = await outcome;
    call.record(
      ConformanceRefreshEvent(
        flight,
        error is OperationError
            ? error.code
            : error is ClientException
            ? error.code
            : null,
        error is OperationError
            ? error.status
            : error is ClientException
            ? error.status
            : null,
      ),
    );
    if (error != null) Error.throwWithStackTrace(error, stack!);
    return value!;
  }();
}
