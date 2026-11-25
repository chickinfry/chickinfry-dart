import 'dart:async';

import '../errors.dart';
import '../session.dart';

const conformanceEnabled = bool.fromEnvironment(
  'chickinfry.conformance',
  defaultValue: false,
);

bool provenSdk(String version) =>
    version.startsWith('3.13.0 (stable)') ||
    version.startsWith('3.13.5 (stable)');

enum ConformancePoint { sdkEntered, originalsRejected, refreshJoined }

enum ConformancePhase { sending, response, bodyComplete, completed, failed }

enum ConformanceTransportPhase {
  headers,
  read,
  limit,
  cancelRequested,
  cancelObserved,
  readerClosed,
  completed,
}

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

final class ConformanceConstruction extends ConformanceEvent {
  int httpSends = 0;
  int socketEntries = 0;
  bool succeeded = false;
  bool _active = true;
  int get networkEntries => httpSends + socketEntries;

  void enterHttpSend() {
    if (_active) httpSends++;
  }

  void enterSocket() {
    if (_active) socketEntries++;
  }
}

ConformanceConstruction? get currentConformanceConstruction =>
    Zone.current[#chickinfryConformanceConstruction]
        as ConformanceConstruction?;

R observeConstruction<R>(R Function() body) {
  final observation = ConformanceConstruction();
  try {
    final result = runZoned(
      body,
      zoneValues: {#chickinfryConformanceConstruction: observation},
    );
    observation.succeeded = true;
    return result;
  } finally {
    observation._active = false;
    currentConformanceCall?.record(observation);
  }
}

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
  int? socketBytesWritten;
  int? pendingSocketBytes;
  bool responseConfirmed = false;
  int? status;
  int readBytes = 0;
  int runtimeRetainedBytes = 0;
  int runtimePeakRetainedBytes = 0;
  // A direct socket supplies a candidate; response headers confirm applicability.
  int? fixedRetainedBytes;
  Object? _connection;
  bool _multipleConnections = false;
  int? libraryRetainedBytes;
  int? peakRetainedBytes;
  bool? cancelObserved;
  bool? readerClosed;
  bool readerStarted = false;
  bool cancelRequested = false;
  bool _readerClosePending = false;
  int _chunks = 0;

  bool? get outcomeUnknown => responseConfirmed
      ? false
      : socketBytesWritten == null
      ? null
      : socketBytesWritten! > 0;

  void observeConnection(Object connection, int fixedBytes) {
    if (_connection != null && !identical(_connection, connection)) {
      _multipleConnections = true;
    }
    _connection = connection;
    fixedRetainedBytes = _multipleConnections ? null : fixedBytes;
  }

  void confirmRetainedBytes(
    String sdkVersion, {
    required bool profiled,
    required String? encoding,
  }) {
    libraryRetainedBytes =
        provenSdk(sdkVersion) &&
            !profiled &&
            call.httpAttempts == 1 &&
            (encoding == null || encoding == 'identity')
        ? fixedRetainedBytes
        : null;
  }

  void transport(ConformanceTransportPhase phase) {
    if (runtimeRetainedBytes > runtimePeakRetainedBytes) {
      runtimePeakRetainedBytes = runtimeRetainedBytes;
    }
    final library = libraryRetainedBytes;
    final peak = library == null ? null : runtimePeakRetainedBytes + library;
    if (peak == null) {
      peakRetainedBytes = null;
    } else if (peakRetainedBytes == null || peak > peakRetainedBytes!) {
      peakRetainedBytes = peak;
    }
    call.recordTransport(phase, this);
  }

  void read(int count) {
    readBytes += count;
    transport(ConformanceTransportPhase.read);
  }

  void retain(int count) {
    _chunks++;
    runtimeRetainedBytes += count;
    if (runtimeRetainedBytes > runtimePeakRetainedBytes) {
      runtimePeakRetainedBytes = runtimeRetainedBytes;
    }
  }

  void materializeBody() {
    // BytesBuilder(copy: false) copies the body only when joining multiple chunks.
    if (_chunks > 1 && runtimeRetainedBytes * 2 > runtimePeakRetainedBytes) {
      runtimePeakRetainedBytes = runtimeRetainedBytes * 2;
    }
  }

  void requestCancel() {
    if (cancelRequested) return;
    cancelRequested = true;
    transport(ConformanceTransportPhase.cancelRequested);
  }

  void observeCancel() {
    if (!cancelRequested || cancelObserved == true) return;
    cancelObserved = true;
    transport(ConformanceTransportPhase.cancelObserved);
    if (_readerClosePending) closeReader();
  }

  void closeReader() {
    if (readerClosed == true) return;
    // Subscription cancellation alone does not prove the native reader is closed.
    if (cancelRequested && cancelObserved != true) {
      _readerClosePending = true;
      return;
    }
    readerClosed = true;
    transport(ConformanceTransportPhase.readerClosed);
  }

  void record(ConformancePhase phase, int? status) {
    this.status = status;
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

int _transportSequence = 0;

final class ConformanceTransportEvent extends ConformanceEvent {
  ConformanceTransportEvent(
    this.attempt,
    this.phase,
    this.sequence,
    this.elapsedMs,
    this.status,
    this.readBytes,
    this.runtimeRetainedBytes,
    this.libraryRetainedBytes,
    this.retainedBytes,
    this.peakRetainedBytes,
    this.runtimePeakRetainedBytes,
  );
  final ConformanceHttpAttempt? attempt;
  final ConformanceTransportPhase phase;
  final int sequence;
  final double elapsedMs;
  final int? status;
  final int? readBytes;
  final int? runtimeRetainedBytes;
  final int? libraryRetainedBytes;
  final int? retainedBytes;
  final int? peakRetainedBytes;
  final int? runtimePeakRetainedBytes;
}

void observeHttp(String operation) {
  final call = currentConformanceCall;
  if (call != null) {
    call.httpObservation = ConformanceHttpAttempt(call, operation);
  }
}

final class ConformanceRefreshEvent extends ConformanceEvent {
  ConformanceRefreshEvent(
    this.flight,
    this.code,
    this.status, [
    this.observation,
  ]);
  final Object flight;
  final String? code;
  final int? status;
  final ConformanceRefreshObservation? observation;
}

final class ConformanceRefreshObservation {
  ConformanceHttpAttempt? attempt;
  Future<void>? Function()? _requestSent;
  bool credentialsValidated = false;
  bool credentialsStored = false;
  bool rejected401 = false;
  bool? get outcomeUnknown => credentialsStored || rejected401
      ? false
      : attempt?.socketBytesWritten == null
      ? null
      : attempt!.socketBytesWritten! > 0;
}

final _refreshObservations = Expando<ConformanceRefreshObservation>();

void startRefreshObservation(Object flight, SessionCredentials expected) {
  final observation = ConformanceRefreshObservation();
  _refreshObservations[flight] = observation;
  final call = currentConformanceCall;
  if (call == null) return;
  call.refreshObservation = observation;
  observation._requestSent = () => call.arrive(
    ConformancePoint.refreshJoined,
    ConformanceFacts(
      operation: call.operation,
      credentials: expected,
      flight: flight,
      initiator: true,
    ),
  );
}

Future<void> observeRequestSent(
  Future<void> sent,
  ConformanceHttpAttempt? attempt,
) async {
  await sent;
  final observation = attempt?.call.refreshObservation;
  if (observation == null ||
      !identical(observation.attempt, attempt) ||
      (attempt!.socketBytesWritten ?? 0) == 0 ||
      attempt.pendingSocketBytes != 0) {
    return;
  }
  final arrive = observation._requestSent;
  observation._requestSent = null;
  final barrier = arrive?.call();
  if (barrier != null) await barrier;
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
  ConformanceRefreshObservation? refreshObservation;
  final elapsed = Stopwatch();
  final transportEvents = <ConformanceTransportEvent>[];
  bool _completed = false;
  bool _retainedUnknown = false;

  void recordTransport(
    ConformanceTransportPhase phase,
    ConformanceHttpAttempt? attempt,
  ) {
    final runtime = attempt?.runtimeRetainedBytes;
    if (httpAttempts != 1 || attempt?.libraryRetainedBytes == null) {
      _retainedUnknown = true;
    }
    final library = _retainedUnknown ? null : attempt?.libraryRetainedBytes;
    final event = ConformanceTransportEvent(
      attempt,
      phase,
      ++_transportSequence,
      elapsed.elapsedMicroseconds / 1000,
      attempt?.status,
      attempt?.readBytes,
      runtime,
      library,
      runtime == null || library == null ? null : runtime + library,
      _retainedUnknown ? null : attempt?.peakRetainedBytes,
      attempt?.runtimePeakRetainedBytes,
    );
    transportEvents.add(event);
    record(event);
  }

  void complete({required bool succeeded}) {
    if (_completed) return;
    _completed = true;
    final attempt = httpObservation;
    final status = attempt?.status;
    if (succeeded && status != null && status >= 200 && status < 300) {
      attempt!.responseConfirmed = true;
    }
    if (attempt == null) {
      recordTransport(ConformanceTransportPhase.completed, null);
    } else {
      attempt.transport(ConformanceTransportPhase.completed);
    }
  }

  Future<void>? arrive(ConformancePoint point, ConformanceFacts facts) {
    try {
      return observer
          .arrive(point, facts)
          ?.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
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
    ? runZoned(() {
        final result = body();
        if (result is Future) {
          unawaited(
            result.then<void>(
              (_) => call.complete(succeeded: true),
              onError: (Object _, StackTrace _) {
                call.complete(succeeded: false);
              },
            ),
          );
        }
        return result;
      }, zoneValues: {#chickinfryConformanceCall: call})
    : body();

Future<SessionCredentials> observeRefresh(
  Future<SessionCredentials> result,
  Object flight,
  SessionCredentials expected, {
  required bool initiator,
}) {
  final call = currentConformanceCall;
  if (call == null) return result;
  call._retainedUnknown = true;
  // Attach the error handler before the barrier to avoid unhandled shared Future errors.
  final outcome = result.then<(SessionCredentials?, Object?, StackTrace?)>(
    (value) => (value, null, null),
    onError: (Object error, StackTrace stack) => (null, error, stack),
  );
  return () async {
    if (!initiator) {
      final barrier = call.arrive(
        ConformancePoint.refreshJoined,
        ConformanceFacts(
          operation: call.operation,
          credentials: expected,
          flight: flight,
          initiator: false,
        ),
      );
      if (barrier != null) await barrier;
    }
    final (value, error, stack) = await outcome;
    call.record(
      ConformanceRefreshEvent(
        flight,
        error is OperationError
            ? error.code
            : error is ClientError
            ? error.code
            : null,
        error is OperationError
            ? error.status
            : error is ClientError
            ? error.status
            : null,
        _refreshObservations[flight],
      ),
    );
    if (error != null) Error.throwWithStackTrace(error, stack!);
    return value!;
  }();
}
