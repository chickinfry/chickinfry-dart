import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'device/bridge.dart';
import 'errors.dart';
import 'http.dart';
import 'realtime_socket.dart' if (dart.library.io) 'realtime_socket_io.dart';
import 'session.dart';
import 'testing/conformance.dart';

final _uuidPattern = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
final _errorPattern = RegExp(r'^[a-z_]{1,64}$');
final _control = RegExp(r'[\x00-\x1f\x7f]');
final _random = Random.secure();
const _budget = Duration(seconds: 30);
const _maxFrameBytes = 66560;

String _uuid() {
  final bytes = List.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _isUuid(Object? value) =>
    value is String && value.length == 36 && _uuidPattern.hasMatch(value);

bool _isCursor(Object? value) => value == '' || _isUuid(value);

String realtimeEndpoint(Object? value) {
  const suffix = '.chickinfry.app';
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      !uri.host.endsWith(suffix) ||
      !_isUuid(uri.host.substring(0, uri.host.length - suffix.length)) ||
      value != 'wss://${uri.host}/realtime') {
    throw const ClientError('internal');
  }
  return value as String;
}

/// An event delivered by a realtime subscription.
final class RealtimeEvent {
  const RealtimeEvent._(this.channel, this.payload);
  String get type => 'event';
  final String channel;
  final Object? payload;
}

/// A notification that a subscription needs a fresh application snapshot.
final class RealtimeGap {
  const RealtimeGap._(this.channel);
  String get type => 'gap';
  final String channel;
}

/// Options for a realtime subscription.
final class SubscribeOptions {
  const SubscribeOptions({this.onGap});
  final Future<void> Function(RealtimeGap gap)? onGap;
}

/// One ordered stream of events, with a single consumer.
abstract interface class RealtimeSubscription {
  Stream<RealtimeEvent> get events;
  Future<void> unsubscribe();
}

/// Subscribes to channels using the generated client's transport.
final class RealtimeClient {
  const RealtimeClient._(this._transport);
  final Transport _transport;

  /// Waits for the subscription to be ready.
  ///
  /// Use await for or asyncMap to finish each event before processing the next.
  Future<RealtimeSubscription> subscribe(
    String channel, [
    SubscribeOptions options = const SubscribeOptions(),
  ]) {
    final encoded = utf8.encode(channel);
    if (encoded.isEmpty ||
        encoded.length > 128 ||
        _control.hasMatch(channel) ||
        utf8.decode(encoded) != channel) {
      return Future.error(const ClientError('invalid_argument'));
    }
    final probe = conformanceEnabled
        ? Zone.current[realtimeProbeKey] as RealtimeProbe?
        : null;
    return _Subscription(_transport, channel, options.onGap, probe).start();
  }
}

RealtimeClient createRealtimeClient(Transport transport) =>
    RealtimeClient._(transport);

final realtimeProbeKey = Object();

final class RealtimeProbe {
  const RealtimeProbe({
    required this.endpoint,
    this.point,
    this.inspect,
    this.dispatch,
    this.control,
  });

  final String Function(Object?) endpoint;
  final void Function(String)? point;
  final void Function(Map<String, int> Function())? inspect;
  final void Function(String, void Function())? dispatch;
  final void Function(void Function())? control;
}

final class _Connection {
  _Connection(this.socket, this.abort);
  final WebSocketChannel socket;
  final void Function() abort;
  final ended = Completer<void>();
  StreamSubscription<Object?>? reader;
  String? confirmation;
  String? checkpoint;
  bool prepared = false;

  void close() {
    ended.complete();
    unawaited(reader?.cancel());
    unawaited(socket.sink.close().then<void>((_) {}, onError: (Object _) {}));
    abort();
  }
}

final class _Recovery {
  _Recovery(this.cursor);
  final String cursor;
  bool complete = false;
  _Connection? connection;
}

final class _Subscription implements RealtimeSubscription {
  _Subscription(this.transport, this.channel, this.onGap, this.probe) {
    _events = StreamController<RealtimeEvent>(
      sync: true,
      onListen: _schedulePump,
      onResume: _schedulePump,
      onCancel: _stop,
    );
  }

  final Transport transport;
  final String channel;
  final Future<void> Function(RealtimeGap)? onGap;
  final RealtimeProbe? probe;
  final _queue = Queue<({String cursor, Object? payload})>();
  final _ready = Completer<RealtimeSubscription>();
  final _stopped = Completer<void>();
  final _id = _uuid();
  late final StreamController<RealtimeEvent> _events;
  @override
  late final Stream<RealtimeEvent> events = _ExclusiveEvents(_events.stream);
  _Connection? _connection;
  _Recovery? _recovery;
  Timer? _deadline, _retry, _renewal;
  bool _firstReady = false, _callbackRunning = false, _pumpScheduled = false;
  bool _renewing = false;
  String _last = '';
  Object? _failure;
  int _lossBudgets = 0, _connectionsStarted = 0;

  bool get _active => !_stopped.isCompleted;
  bool get _demand =>
      _events.hasListener && !_events.isPaused && !_pumpScheduled;

  Future<RealtimeSubscription> start() {
    probe?.inspect?.call(
      () => {
        'pendingReads': _active && _demand ? 1 : 0,
        'activeRenewalWatchers': _active && _renewing ? 1 : 0,
        'reprepareBudgetMs': _lossBudgets == 0 ? 0 : _budget.inMilliseconds,
        'budgetResets': max(0, _lossBudgets - 1),
        'connectionsStarted': _connectionsStarted,
      },
    );
    probe?.control?.call(_stop);
    _armBudget();
    unawaited(_run());
    final source = transport;
    final http = source is DeviceTransport
        ? deviceRealtimeTransport(source)
        : source;
    final renewal = http is HttpTransport ? realtimeSession(http) : null;
    if (renewal != null) {
      _renewing = true;
      unawaited(_renew(renewal.read, renewal.renew));
    }
    return _ready.future;
  }

  @override
  Future<void> unsubscribe() async {
    _send('unsubscribe');
    _stop();
  }

  void _armBudget() {
    if (_deadline != null) return;
    if (_firstReady) _lossBudgets++;
    _deadline = Timer(
      _budget,
      () => _stop(const ClientError('deadline_exceeded')),
    );
  }

  void _stop([Object? error]) {
    if (!_active) return;
    _failure = error;
    _stopped.complete();
    _deadline?.cancel();
    _retry?.cancel();
    _renewal?.cancel();
    _recovery = null;
    _queue.clear();
    _closeConnection();
    if (!_ready.isCompleted) {
      _ready.completeError(error ?? const ClientError('canceled'));
    }
    _schedulePump();
  }

  void _closeConnection() {
    final old = _connection;
    _connection = null;
    _queue.clear();
    old?.close();
  }

  void _lost(_Connection current) {
    if (_connection != current) return;
    _closeConnection();
    _armBudget();
    _schedulePump();
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      if (!_active) {
        if (!_events.isClosed) {
          final error = _failure;
          if (_firstReady && error != null) _events.addError(error);
          unawaited(_events.close());
        }
        return;
      }
      if (!_demand) return;
      if (_recovery != null) {
        _recover();
      } else if (_connection?.prepared == true && _queue.isNotEmpty) {
        final event = _queue.removeFirst();
        _last = event.cursor;
        _acknowledge();
        _events.add(RealtimeEvent._(channel, event.payload));
        _schedulePump();
      }
    });
  }

  void _gap(String cursor) {
    if (onGap == null) {
      _stop(const ClientError('data_loss'));
      return;
    }
    _recovery = _Recovery(cursor);
    _connection?.prepared = false;
    _queue.clear();
    _armBudget();
    probe?.point?.call('gap');
    _recover();
  }

  void _recover() {
    final current = _recovery;
    if (!_active ||
        current == null ||
        current.complete ||
        _callbackRunning ||
        (_firstReady && !_demand)) {
      return;
    }
    _callbackRunning = true;
    unawaited(
      Future<void>.microtask(() async {
        try {
          if (!_active || _recovery != current) return;
          await onGap!(RealtimeGap._(channel));
          if (!_active || _recovery != current) return;
          current.complete = true;
          _last = current.cursor;
          _closeConnection();
        } catch (error) {
          if (_active && _recovery == current) {
            _stop(ClientError('unknown', cause: error));
          }
        } finally {
          _callbackRunning = false;
          _schedulePump();
        }
      }),
    );
  }

  bool _send(String type, [Map<String, Object?> fields = const {}]) {
    final connection = _connection;
    if (connection == null) return false;
    try {
      connection.socket.sink.add(
        jsonEncode({'type': type, 'channel': channel, ...fields}),
      );
      return true;
    } catch (_) {
      _lost(connection);
      return false;
    }
  }

  void _acknowledge() {
    final connection = _connection;
    final cursor = connection?.checkpoint;
    if (connection?.prepared == true &&
        cursor != null &&
        _recovery == null &&
        _queue.isEmpty &&
        _send('ack', {'cursor': cursor})) {
      connection!.checkpoint = null;
    }
  }

  void _receive(_Connection current, Object? message) {
    if (!_active || current != _connection) {
      probe?.point?.call('discarded');
      return;
    }
    try {
      if (message is! String ||
          message.length > _maxFrameBytes ||
          utf8.encode(message).length > _maxFrameBytes) {
        throw const FormatException();
      }
      final frame = jsonDecode(message);
      if (frame is! Map<String, Object?> ||
          (frame['channel'] != channel &&
              !(frame['type'] == 'error' && !frame.containsKey('channel')))) {
        throw const FormatException();
      }
      final cursor = frame['cursor'];
      switch (frame['type']) {
        case 'ready':
          final confirmation = frame['confirmation'];
          final ack = frame['acknowledge'];
          if (!_isCursor(cursor) ||
              (frame.containsKey('confirmation') && !_isUuid(confirmation)) ||
              (frame.containsKey('acknowledge') && ack is! bool)) {
            throw const FormatException();
          }
          current.checkpoint = ack == true ? cursor as String : null;
          if (confirmation == null) {
            if (current.confirmation == null) {
              current.confirmation = _uuid();
              _send('confirm', {'confirmation': current.confirmation});
            }
            return;
          }
          if (confirmation != current.confirmation) return;
          final recovery = _recovery;
          if (recovery != null) {
            if (!recovery.complete || recovery.connection != current) return;
            _recovery = null;
            probe?.point?.call('recovered');
          }
          current.prepared = true;
          _firstReady = true;
          _deadline?.cancel();
          _deadline = null;
          if (!_ready.isCompleted) _ready.complete(this);
          _acknowledge();
          _schedulePump();
        case 'gap':
          if (!_isCursor(cursor)) throw const FormatException();
          _gap(cursor as String);
        case 'event':
          final previous = frame['previous'];
          if (!_isUuid(cursor) ||
              !_isCursor(previous) ||
              !frame.containsKey('payload')) {
            throw const FormatException();
          }
          if (cursor == _last ||
              _queue.any((event) => event.cursor == cursor)) {
            return;
          }
          final expected = _queue.isEmpty
              ? _recovery?.cursor ?? _last
              : _queue.last.cursor;
          final full = _queue.length >= (probe == null ? 256 : 512);
          if (previous != expected || full) {
            if (full) probe?.point?.call('overflow');
            _gap(cursor as String);
          } else {
            _queue.add((cursor: cursor as String, payload: frame['payload']));
            _schedulePump();
          }
        case 'error':
          final code = frame['error'];
          if (code is! String ||
              !_errorPattern.hasMatch(code) ||
              code.endsWith('\n')) {
            throw const FormatException();
          }
          _stop(
            ClientError(switch (code) {
              'unauthorized_channel' => 'permission_denied',
              'already_subscribed' => 'internal',
              'too_many_channels' => 'resource_exhausted',
              'replay_failed' || 'realtime_unavailable' => 'unavailable',
              _ => 'unknown',
            }),
          );
        default:
          throw const FormatException();
      }
    } on FormatException {
      _stop(const ClientError('internal'));
    }
  }

  Future<void> _run() async {
    var backoff = 500;
    while (_active) {
      try {
        final response = await transport.invoke('realtime.ticket', const {});
        if (!_active) return;
        if (response is! Map<String, Object?> || !_isUuid(response['ticket'])) {
          throw const ClientError('internal');
        }
        final endpoint = (probe?.endpoint ?? realtimeEndpoint)(
          response['endpoint'],
        );
        final address = Uri.parse(endpoint)
            .replace(queryParameters: {'ticket': response['ticket'] as String});
        await _connect(address);
        backoff = 500;
      } catch (error) {
        if (!_active) return;
        final retry = switch (error) {
          ClientError(:final code) =>
            code == 'unavailable' || code == 'deadline_exceeded',
          OperationError(:final status) =>
            (status == 409 && !_firstReady) || status == 429 || status >= 500,
          _ => false,
        };
        if (!retry) {
          _stop(
            error is ClientError || error is OperationError
                ? error
                : const ClientError('internal'),
          );
          return;
        }
      }
      if (!_active) return;
      final delay = Completer<void>();
      _retry = Timer(Duration(milliseconds: backoff), delay.complete);
      await Future.any([delay.future, _stopped.future]);
      backoff = min(backoff * 2, 5000);
    }
  }

  Future<void> _connect(Uri address) async {
    final (socket, abort) = openRealtimeSocket(address);
    final current = _Connection(socket, abort);
    _connection = current;
    _connectionsStarted++;
    final recovery = _recovery;
    if (recovery?.complete == true) recovery!.connection = current;
    current.reader = socket.stream.listen(
      (message) {
        final dispatch = probe?.dispatch;
        if (dispatch != null && message is String) {
          dispatch(message, () => _receive(current, message));
        } else {
          _receive(current, message);
        }
      },
      onError: (Object _) => _lost(current),
      onDone: () => _lost(current),
    );
    try {
      await Future.any([
        socket.ready.timeout(const Duration(seconds: 10)),
        current.ended.future,
      ]);
      if (_connection != current) return;
      _send('subscribe', {
        'cursor': _recovery?.cursor ?? _last,
        'subscription': _id,
      });
      await current.ended.future;
    } catch (_) {
      _lost(current);
    }
  }

  Future<void> _renew(
    Future<SessionCredentials?> Function() read,
    Future<void> Function(SessionCredentials) renew,
  ) async {
    try {
      while (_active) {
        final previous = await read();
        if (!_active) return;
        if (previous == null) throw const ClientError('unauthenticated');
        final expires = DateTime.parse(previous.expiresAt);
        final wait =
            expires.difference(DateTime.now()) - const Duration(minutes: 1);
        if (wait > Duration.zero) {
          final elapsed = Completer<void>();
          _renewal = Timer(wait, elapsed.complete);
          await Future.any([elapsed.future, _stopped.future]);
        }
        if (!_active) return;
        if (await read() != previous || !_active) continue;
        await renew(previous);
        if (_active && await read() == previous) {
          throw const ClientError('internal');
        }
      }
    } catch (error) {
      _stop(
        error is ClientError || error is OperationError
            ? error
            : const ClientError('internal'),
      );
    } finally {
      _renewing = false;
    }
  }
}

final class _ExclusiveEvents extends Stream<RealtimeEvent> {
  _ExclusiveEvents(this._stream);
  final Stream<RealtimeEvent> _stream;
  bool _consumed = false;

  @override
  StreamSubscription<RealtimeEvent> listen(
    void Function(RealtimeEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_consumed) throw const ClientError('failed_precondition');
    _consumed = true;
    return _stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
