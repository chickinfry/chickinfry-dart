import '../errors.dart';
import '../session.dart';
import 'conformance.dart';

class Record {
  Record(this.value) : revision = value == null ? 0 : 1;
  int revision;
  ({SessionCredentials? value, int revision}) get snapshot =>
      (value: value, revision: revision);
  SessionCredentials? value;
  bool failRead = false;
  bool corrupt = false;
  bool failReplace = false;
  int replacements = 0;
  int deletions = 0;
}

class MemorySessionStore implements SessionStore {
  MemorySessionStore(this.origin, this.coordinationKey, this.record);
  @override
  final String origin;
  @override
  final String coordinationKey;
  final Record record;

  @override
  Future<SessionCredentials?> read() async {
    if (record.corrupt) throw const ClientError('data_loss');
    if (record.failRead) throw StateError('Private storage failure.');
    return record.value;
  }

  @override
  Future<void> write(SessionCredentials value) async {
    record.value = value;
    record.revision++;
  }

  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) async {
    if (record.failReplace) throw StateError('Private storage failure.');
    // Keep shared record comparison and mutation synchronous.
    if (record.value != expected) return false;
    record.value = next;
    record.revision++;
    record.replacements++;
    if (next == null) record.deletions++;
    return true;
  }
}

final class ConformanceClearAttempt extends ConformanceEvent {
  ConformanceClearAttempt(this.callId, this.expected, this.removed);
  final String? callId;
  final SessionCredentials expected;
  final bool? removed;
}

final class RecordingSessionStore implements SessionStore {
  RecordingSessionStore(this.delegate);
  final SessionStore delegate;
  final clearAttempts = <ConformanceClearAttempt>[];

  @override
  String get origin => delegate.origin;
  @override
  String get coordinationKey => delegate.coordinationKey;
  @override
  Future<SessionCredentials?> read() => delegate.read();
  @override
  Future<void> write(SessionCredentials value) => delegate.write(value);

  @override
  Future<bool> compareAndSet(
    SessionCredentials expected,
    SessionCredentials? next,
  ) {
    if (!conformanceEnabled || next != null) {
      return delegate.compareAndSet(expected, next);
    }
    final call = currentConformanceCall;
    return () async {
      bool? removed;
      try {
        removed = await delegate.compareAndSet(expected, next);
        return removed;
      } finally {
        final attempt = ConformanceClearAttempt(
          call?.callId,
          expected,
          removed,
        );
        clearAttempts.add(attempt);
        call?.record(attempt);
      }
    }();
  }
}
