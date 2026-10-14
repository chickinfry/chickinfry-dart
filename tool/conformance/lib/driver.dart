// The internal driver consumes opt-in hooks without adding a public testing API.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:chickinfry/chickinfry.dart';
import 'package:chickinfry/src/testing/conformance.dart';
import 'package:chickinfry/src/testing/session_store.dart';

import 'bridge.dart';
import 'credentials.dart';
import 'observations.dart';
import 'protocol.dart';

const driverVersion = '1.0.0';

final class Store {
  Store(this.record, this.store);
  final Record record;
  final RecordingSessionStore store;
}

final class Client {
  Client(this.transport, this.bridge, this.fixture, this.hasSession);
  final HttpTransport transport;
  final Bridge bridge;
  final String fixture;
  final bool hasSession;
}

final class SdkFailure implements Exception {
  SdkFailure(this.payload);
  final Map<String, Object?> payload;
}

final class Driver {
  Driver(this.credentials, this.request);
  final Credentials credentials;
  final Future<Map<String, Object?>> Function(
    String command,
    Map<String, Object?> args,
  )
  request;
  final stores = <String, Store>{};
  final clients = <String, Client>{};
  final ownedTransports = <HttpTransport>[];
  final barriers = <Barrier>[];
  final flights = Map<Object, String>.identity();
  final calls = <String, (ConformanceCall, Observation)>{};
  final deadlines = <String, int>{};
  final elapsed = Stopwatch()..start();
  String? runId;
  String? caseId;
  int? caseDeadline;
  Duration? remaining(String id) {
    final deadline = deadlines[id];
    return deadline == null
        ? null
        : Duration(milliseconds: deadline - elapsed.elapsedMilliseconds);
  }

  final capabilities = [
    'client.create',
    'client.copy',
    'client.call',
    'session.store',
    if (conformanceEnabled) ...['barrier', 'session.trace'],
    if (conformanceEnabled && provenSdk(Platform.version)) 'client.transport',
  ];

  T lookup<T>(Map<String, T> values, String ref) {
    final value = values[ref];
    if (value == null) throw const DriverError('invalid_reference');
    return value;
  }

  Future<Map<String, Object?>> handle(
    String id,
    String command,
    Map<String, Object?> args,
  ) async {
    if (command == 'handshake') return handshake(args);
    if (runId == null) violation();
    const common = {'caseId', 'timeoutMs'};
    switch (command) {
      case 'session.store.create':
        fields(
          args,
          {...common, 'storeRef', 'origin'},
          {'recordRef', 'accessRef', 'refreshRef'},
        );
        break;
      case 'session.store.write':
        fields(args, {
          ...common,
          'storeRef',
          'recordRef',
          'accessRef',
          'refreshRef',
        });
        break;
      case 'session.store.read':
        fields(args, {...common, 'storeRef', 'includeTrace'});
        break;
      case 'client.create':
        fields(
          args,
          {...common, 'clientRef', 'fixture', 'origin', 'requestTimeoutMs'},
          {'storeRef', 'bearerRef'},
        );
        break;
      case 'client.copy':
        fields(args, {...common, 'sourceClientRef', 'clientRef', 'bearerRef'});
        break;
      case 'client.call':
        fields(
          args,
          {...common, 'clientRef', 'operation', 'input'},
          {'inputRefs', 'outputRefs'},
        );
        break;
      case 'barrier.arm':
        fields(args, {...common, 'barrierRef', 'point', 'participants'});
        break;
      case 'client.observe':
        fields(args, {...common, 'callId', 'afterSequence'});
        break;
    }
    final currentCase = identifier(args, 'caseId');
    if (caseId != null && caseId != currentCase) violation();
    caseId = currentCase;
    final requestedDeadline =
        elapsed.elapsedMilliseconds + positive(args, 'timeoutMs');
    caseDeadline ??= requestedDeadline;
    deadlines[id] = requestedDeadline < caseDeadline!
        ? requestedDeadline
        : caseDeadline!;
    if (remaining(id)!.inMilliseconds <= 0) {
      throw const DriverError('deadline_exceeded');
    }
    switch (command) {
      case 'session.store.create':
        final ref = identifier(args, 'storeRef');
        if (stores.containsKey(ref)) violation();
        final origin = string(args, 'origin');
        final present = [
          'recordRef',
          'accessRef',
          'refreshRef',
        ].where(args.containsKey).length;
        if (present != 0 && present != 3) invalidArgs();
        final initial = present == 0
            ? null
            : credentials.record(
                origin,
                identifier(args, 'recordRef'),
                identifier(args, 'accessRef'),
                identifier(args, 'refreshRef'),
              );
        final record = Record(initial);
        stores[ref] = Store(
          record,
          RecordingSessionStore(
            MemorySessionStore(origin, '$runId:$caseId:$ref', record),
          ),
        );
        return {'storeRef': ref, 'revision': record.revision};
      case 'session.store.write':
        final store = lookup(stores, identifier(args, 'storeRef'));
        final accessRef = identifier(args, 'accessRef');
        final refreshRef = identifier(args, 'refreshRef');
        final value = credentials.record(
          store.store.origin,
          identifier(args, 'recordRef'),
          accessRef,
          refreshRef,
        );
        final write = store.store.write(value);
        final revision = store.record.revision;
        await write;
        return {
          'revision': revision,
          'accessRef': accessRef,
          'refreshRef': refreshRef,
        };
      case 'session.store.read':
        if (args['includeTrace'] is! bool) invalidArgs();
        if (args['includeTrace'] == true && !conformanceEnabled) {
          unimplemented();
        }
        final store = lookup(stores, identifier(args, 'storeRef'));
        final snapshot = store.record.snapshot;
        final value = snapshot.value;
        final trace = <Map<String, Object?>>[];
        if (args['includeTrace'] == true) {
          for (final attempt in store.store.clearAttempts) {
            final access = credentials.reference(attempt.expected.accessToken);
            final refresh = credentials.reference(
              attempt.expected.refreshToken,
            );
            if (attempt.callId == null ||
                attempt.removed == null ||
                access == null ||
                refresh == null) {
              unimplemented();
            }
            trace.add({
              'callId': attempt.callId,
              'expectedAccessRef': access,
              'expectedRefreshRef': refresh,
              'removed': attempt.removed,
            });
          }
        }
        return {
          'present': value != null,
          'revision': snapshot.revision,
          'accessRef': value == null
              ? null
              : credentials.reference(value.accessToken),
          'refreshRef': value == null
              ? null
              : credentials.reference(value.refreshToken),
          if (args['includeTrace'] == true) 'clearAttempts': trace,
        };
      case 'client.create':
        if (args.containsKey('storeRef') && args.containsKey('bearerRef')) {
          invalidArgs();
        }
        final ref = identifier(args, 'clientRef');
        if (clients.containsKey(ref)) violation();
        final fixture = string(args, 'fixture');
        final origin = string(args, 'origin');
        final timeout = positive(args, 'requestTimeoutMs');
        final store = args.containsKey('storeRef')
            ? lookup(stores, identifier(args, 'storeRef')).store
            : null;
        final bearer = args.containsKey('bearerRef')
            ? credentials.value(identifier(args, 'bearerRef'))
            : null;
        final (call, observation) = observationFor(id, 'constructor');
        try {
          final client = withConformanceCall(call, () {
            final (transport, bridge) = createBridge(() {
              final base = HttpTransport(
                origin,
                timeout: Duration(milliseconds: timeout),
              );
              ownedTransports.add(base);
              return store != null
                  ? base.withSession(store)
                  : bearer != null
                  ? base.withBearer(bearer)
                  : base;
            }, fixture: fixture);
            return Client(transport, bridge, fixture, store != null);
          });
          if (call.instrumentationFailed) {
            throw const DriverError('driver_failed');
          }
          clients[ref] = client;
          return {
            'clientRef': ref,
            'constructorNetworkRequests': observation.constructorRequests,
          };
        } on DriverError {
          rethrow;
        } catch (error) {
          if (call.instrumentationFailed) {
            throw const DriverError('driver_failed');
          }
          throw SdkFailure(
            observation.sdkError(error, call, credentials, construction: true),
          );
        }
      case 'client.copy':
        final source = lookup(clients, identifier(args, 'sourceClientRef'));
        final ref = identifier(args, 'clientRef');
        if (clients.containsKey(ref)) violation();
        final token = credentials.value(identifier(args, 'bearerRef'));
        final (call, observation) = observationFor(id, 'copy');
        try {
          final (transport, bridge) = createBridge(
            () => source.transport.withBearer(token),
            fixture: source.fixture,
          );
          clients[ref] = Client(transport, bridge, source.fixture, false);
          return {'clientRef': ref};
        } catch (error) {
          throw SdkFailure(observation.sdkError(error, call, credentials));
        }
      case 'client.call':
        final client = lookup(clients, identifier(args, 'clientRef'));
        final operation = string(args, 'operation');
        final input = Map<String, Object?>.of(object(args['input']));
        final inputs = args.containsKey('inputRefs')
            ? object(args['inputRefs'])
            : <String, Object?>{};
        final outputs = args.containsKey('outputRefs')
            ? object(args['outputRefs'])
            : <String, Object?>{};
        final newRefs = <String>{};
        for (final entry in inputs.entries) {
          if (input.containsKey(entry.key) || entry.value is! String) {
            invalidArgs();
          }
          input[entry.key] = credentials.value(identifier(inputs, entry.key));
        }
        for (final entry in outputs.entries) {
          final ref = identifier(outputs, entry.key);
          if (credentials.contains(ref) || !newRefs.add(ref)) violation();
        }
        final (call, observation) = observationFor(
          id,
          operation,
          deferTransport: client.hasSession && operation != 'auth.refresh',
        );
        calls[id] = (call, observation);
        try {
          final output = await withConformanceCall(
            call,
            () => client.bridge(operation, input),
          );
          if (call.instrumentationFailed) {
            throw const DriverError('driver_failed');
          }
          final registered = <String, String>{};
          final values = <String, String>{};
          for (final entry in outputs.entries) {
            values[entry.key] = string(output, entry.key);
          }
          for (final entry in outputs.entries) {
            final value = values[entry.key]!;
            final ref = entry.value as String;
            credentials.register(ref, value);
            registered[entry.key] = ref;
          }
          for (final key in ['access_token', 'refresh_token']) {
            final value = output.remove(key);
            if (value is String && !registered.containsKey(key)) {
              final ref = credentials.reference(value);
              if (ref == null) unimplemented();
              registered[key] = ref;
            }
          }
          for (final key in registered.keys) {
            output.remove(key);
          }
          if (credentials.exposes(output)) {
            throw const DriverError('driver_failed');
          }
          return {
            'output': output,
            'credentialRefs': registered,
            'httpStatus': call.httpObservation?.status,
          };
        } on DriverError {
          rethrow;
        } catch (error) {
          if (call.instrumentationFailed) {
            throw const DriverError('driver_failed');
          }
          throw SdkFailure(observation.sdkError(error, call, credentials));
        }
      case 'barrier.arm':
        if (!conformanceEnabled) unimplemented();
        final ref = identifier(args, 'barrierRef');
        if (barriers.any((barrier) => barrier.ref == ref)) violation();
        final point = switch (string(args, 'point')) {
          'sdk-entered' => ConformancePoint.sdkEntered,
          'both-originals-rejected' => ConformancePoint.originalsRejected,
          'refresh-joined' => ConformancePoint.refreshJoined,
          _ => null,
        };
        if (point == null) unimplemented();
        final participants = args['participants'];
        if (participants is! List<Object?> || participants.isEmpty) {
          invalidArgs();
        }
        final ids = <String>{};
        for (final participant in participants) {
          if (participant is! String ||
              !participant.startsWith('c:') ||
              !identifierPattern.hasMatch(participant) ||
              !ids.add(participant) ||
              calls.containsKey(participant)) {
            violation();
          }
        }
        if (barriers.any(
          (barrier) =>
              barrier.point == point && barrier.participants.any(ids.contains),
        )) {
          violation();
        }
        barriers.add(Barrier(ref, point, ids));
        return {'barrierRef': ref, 'state': 'armed'};
      case 'client.observe':
        final after = args['afterSequence'];
        if (after is! int || after < 0) invalidArgs();
        final (call, observation) = lookup(calls, identifier(args, 'callId'));
        return observation.snapshot(call, after);
      default:
        unimplemented();
    }
  }

  Map<String, Object?> handshake(Map<String, Object?> args) {
    if (runId != null) violation();
    fields(args, {
      'protocolVersions',
      'runId',
      'requiredCapabilities',
      'target',
    });
    final versions = args['protocolVersions'];
    if (versions is! List<Object?> || versions.any((v) => v is! int)) {
      invalidArgs();
    }
    if (!versions.contains(1)) throw const DriverError('protocol_mismatch');
    final target = object(args['target']);
    fields(target, {'language', 'role', 'environment'});
    if (target['language'] != 'dart' ||
        target['role'] != 'sdk' ||
        target['environment'] != 'native') {
      unimplemented();
    }
    final required = args['requiredCapabilities'];
    if (required is! List<Object?> || required.any((cap) => cap is! String)) {
      invalidArgs();
    }
    if (required.any((cap) => !capabilities.contains(cap))) unimplemented();
    runId = identifier(args, 'runId');
    return {
      'protocolVersion': 1,
      'driverVersion': driverVersion,
      'capabilities': capabilities,
    };
  }

  (ConformanceCall, Observation) observationFor(
    String id,
    String operation, {
    bool deferTransport = false,
  }) {
    final observation = Observation(id, operation, barriers, flights, (
      barrier,
      callId,
      facts,
    ) async {
      final timeout = remaining(callId)!.inMilliseconds;
      if (timeout <= 0) throw const DriverError('deadline_exceeded');
      final result = await request('barrier.arrive', {
        'caseId': caseId,
        'timeoutMs': timeout,
        'barrierRef': barrier.ref,
        'callId': callId,
        'point': switch (barrier.point) {
          ConformancePoint.sdkEntered => 'sdk-entered',
          ConformancePoint.originalsRejected => 'both-originals-rejected',
          ConformancePoint.refreshJoined => 'refresh-joined',
        },
        'facts': facts,
      });
      fields(result, {'barrierRef', 'state', 'sequence'});
      if (result['barrierRef'] != barrier.ref ||
          result['state'] != 'released' ||
          positive(result, 'sequence') < 1) {
        violation();
      }
    }, deferTransport: deferTransport);
    return (
      ConformanceCall(
        runId: runId!,
        caseId: caseId!,
        callId: id,
        operation: operation,
        observer: observation,
      ),
      observation,
    );
  }

  void close() {
    for (final transport in ownedTransports) {
      transport.close();
    }
    ownedTransports.clear();
  }

  void dispose() {
    close();
    clients.clear();
    stores.clear();
    barriers.clear();
    flights.clear();
    calls.clear();
    deadlines.clear();
    credentials.clear();
  }
}
