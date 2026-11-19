// The driver observes the SDK's receive loop through opt-in private hooks.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/realtime.dart'
    show RealtimeProbe, realtimeProbeKey;

import 'bridge.dart';
import 'protocol.dart';

final class DecodeFailure implements Exception {}

final class RecoveryFailure implements Exception {
  RecoveryFailure(this.cause);
  final DecodeFailure cause;
}

final class RealtimeTrial {
  final _points = <String, Completer<void>>{};
  final _held = <String, Completer<void>>{};
  final _frames = <String, void Function()>{};
  final _eventIds = <String>[];
  final _facts = <String, Object?>{
    'state': 'ready',
    'callbackStarts': 0,
    'callbackCompletions': 0,
    'callbackOverlapAtMost': 0,
    'dbReads': 0,
    'pendingReads': 0,
    'activeRenewalWatchers': 0,
    'deliveredAfterEnd': 0,
    'publicWireOperations': 0,
    'terminalErrors': 0,
    'staleFramesHeld': 0,
    'staleFramesDiscarded': 0,
  };

  RealtimeSubscription? _subscription;
  StreamIterator<RealtimeEvent>? _iterator;
  Map<String, int> Function()? _inspect;
  void Function()? _cancelPending;
  late final Future<void> _running;
  bool _holdingFrames = false;
  bool _canceled = false;
  var _callbacks = 0;
  var _gaps = 0;
  RecoveryFailure? _customerError;

  Completer<void> _point(String name) =>
      _points.putIfAbsent(name, Completer<void>.new);

  void _mark(String name) {
    final point = _point(name);
    if (!point.isCompleted) point.complete();
  }

  Future<void> _hold(String name, String mark) {
    if (_held.containsKey(name)) violation();
    final gate = _held[name] = Completer<void>();
    _mark(mark);
    return gate.future;
  }

  int _increment(String name) {
    final next = (_facts[name] as int) + 1;
    _facts[name] = next;
    return next;
  }

  void start(
    Map<String, Object?> args,
    RealtimeClient client,
    Bridge call,
    String origin,
  ) {
    final mode = string(args, 'onGap');
    final handler = string(args, 'eventHandler');
    final channel = string(args, 'channel');
    final address = Uri.parse(origin);
    if (args['transport'] != 'plain' ||
        !const {'hold', 'absent', 'fail', 'cause'}.contains(mode) ||
        !const {'normal', 'hold-a'}.contains(handler) ||
        address.scheme != 'http' ||
        address.host != '127.0.0.1' ||
        '${address.scheme}://${address.authority}' != origin)
      invalidArgs();

    final probe = RealtimeProbe(
      endpoint: (value) {
        if (value != 'ws://${address.authority}/realtime') invalidArgs();
        return value as String;
      },
      point: (name) {
        switch (name) {
          case 'gap':
            _mark(++_gaps == 1 ? 'gap-received' : 'gap-received-again');
          case 'overflow':
            _mark('overflow-received');
          case 'recovered':
            _mark('recovered');
          case 'discarded':
            _increment('staleFramesDiscarded');
        }
      },
      inspect: (read) => _inspect = read,
      control: (cancel) => _cancelPending = cancel,
      dispatch: (text, receive) {
        if (_holdingFrames) {
          final type = (jsonDecode(text) as Map<String, Object?>)['type'];
          if ((type == 'ready' || type == 'event') &&
              !_frames.containsKey(type)) {
            _frames[type as String] = receive;
            _increment('staleFramesHeld');
            if (_frames.length == 2) _mark('stale-frames-held');
            return;
          }
        }
        receive();
      },
    );

    _running = runZoned(() async {
      var phase = 'subscribe';
      try {
        final subscription = _subscription = await client.subscribe(
          channel,
          SubscribeOptions(
            onGap: mode == 'absent'
                ? null
                : (_) async {
                    final count = _increment('callbackStarts');
                    _callbacks++;
                    _facts['callbackOverlapAtMost'] = max(
                      _facts['callbackOverlapAtMost'] as int,
                      _callbacks,
                    );
                    try {
                      await call('probe.list', {});
                      _increment('dbReads');
                      if (mode == 'fail' || mode == 'cause') {
                        throw _customerError = RecoveryFailure(DecodeFailure());
                      }
                      await _hold(
                        'gap',
                        count == 1 ? 'gap-entered' : 'gap-entered-again',
                      );
                      if (!_canceled) _increment('callbackCompletions');
                    } finally {
                      _callbacks--;
                    }
                  },
          ),
        );
        if (_canceled) {
          await subscription.unsubscribe();
          return;
        }
        _mark('subscribed');
        phase = 'events';
        final iterator = _iterator = StreamIterator(subscription.events);
        try {
          while (await iterator.moveNext()) {
            final id = string(object(iterator.current.payload), 'id');
            if (!const {'A', 'B', 'C', 'overflow'}.contains(id)) invalidArgs();
            if (_facts['state'] != 'ready') _increment('deliveredAfterEnd');
            _eventIds.add(id);
            if (id == 'A' && handler == 'hold-a') {
              await _hold('event-a', 'event-a-entered');
              if (_canceled) break;
            }
            _mark('event-${id.toLowerCase()}-complete');
          }
        } finally {
          await iterator.cancel();
        }
        _facts['state'] = _canceled ? 'canceled' : 'ended';
      } catch (error) {
        if (_canceled) {
          _facts['state'] = 'canceled';
          return;
        }
        _facts['state'] = 'error';
        _facts['errorPhase'] = phase;
        _facts['errorCode'] = switch (error) {
          ClientError(:final code) || OperationError(:final code) => code,
          _ => 'unknown',
        };
        _facts['httpStatus'] = error is OperationError ? error.status : null;
        _increment('terminalErrors');
        final cause = error is ClientError ? error.cause : null;
        if (cause is RecoveryFailure) {
          _facts['errorType'] = 'RecoveryFailure';
          _facts['causeType'] = 'DecodeFailure';
        }
        if (_customerError != null) {
          _facts['causePreserved'] = identical(cause, _customerError);
        }
      } finally {
        _mark('ended');
      }
    }, zoneValues: {realtimeProbeKey: probe});
  }

  Future<Map<String, Object?>> command(
    String command,
    Map<String, Object?> args,
  ) async {
    switch (command) {
      case 'realtime.observe':
        final point = string(args, 'point');
        if (point != 'snapshot') await _point(point).future;
        final metrics = _inspect?.call() ?? <String, int>{};
        metrics.remove('connectionsStarted');
        return {
          'facts': {
            ..._facts,
            ...metrics,
            'eventIds': [..._eventIds],
          },
        };
      case 'realtime.release':
        final gate = _held.remove(string(args, 'point')) ?? invalidArgs();
        if (!gate.isCompleted) gate.complete();
      case 'realtime.unsubscribe':
        final subscription = _subscription ?? invalidArgs();
        await subscription.unsubscribe();
        await subscription.unsubscribe();
        await _running;
      case 'realtime.cancel':
        close();
        await _running;
      case 'realtime.second-consumer':
        final subscription = _subscription ?? invalidArgs();
        final before = _inspect?.call()['connectionsStarted'];
        var rejected = false;
        try {
          await subscription.events.first;
        } on ClientError catch (error) {
          rejected = error.code == 'failed_precondition';
        }
        _facts['exclusiveConsumption'] = rejected;
        _facts['consumptionRejection'] = 'runtime';
        final after = _inspect?.call()['connectionsStarted'];
        if (before != null && after != null)
          _facts['newConnections'] = after - before;
      case 'realtime.hold-dispatch':
        _holdingFrames = true;
      case 'realtime.release-dispatch':
        _holdingFrames = false;
        final release = _frames.values.toList();
        _frames.clear();
        for (final receive in release) {
          receive();
        }
      default:
        invalidArgs();
    }
    return {'accepted': true};
  }

  void close() {
    if (_canceled) return;
    _canceled = true;
    _facts['state'] = 'canceled';
    _cancelPending?.call();
    unawaited(_iterator?.cancel());
    // Cancel the consumer without clearing the peer's pending recovery gate.
    final event = _held['event-a'];
    if (event != null && !event.isCompleted) event.complete();
  }
}
