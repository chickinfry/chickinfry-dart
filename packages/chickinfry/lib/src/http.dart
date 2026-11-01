import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'device/store.dart';
import 'http_client_stub.dart'
    if (dart.library.io) 'http_client_io.dart'
    if (dart.library.js_interop) 'http_client_web.dart'
    as platform;
import 'origin.dart';
import 'session.dart';
import 'testing/conformance.dart';

/// ClientTransport is the generated client's operation boundary.
abstract interface class ClientTransport {
  Future<Object?> invoke(String operation, Map<String, Object?> input);
}

final _operationPattern = RegExp(r'^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$');
final _errorPattern = RegExp(r'^[a-z_]+$');
final _refreshes = <(String, String), _RefreshFlight>{};
final _uncertain = <(String, String), Set<SessionCredentials>>{};

class _RefreshFlight {
  _RefreshFlight(this.expected);
  final SessionCredentials expected;
  final result = Completer<SessionCredentials>();
}

/// HttpTransport uses a fixed origin and a finite per-request deadline.
/// Browsers use cookies only; native targets can attach bearer credentials.
final class HttpTransport implements ClientTransport {
  factory HttpTransport(
    String origin, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (conformanceEnabled &&
        currentConformanceCall != null &&
        currentConformanceConstruction == null) {
      return observeConstruction(() => HttpTransport(origin, timeout: timeout));
    }
    final normalized = normalizeOrigin(origin);
    if (timeout <= Duration.zero) {
      throw const ClientError('invalid_argument');
    }
    return HttpTransport._(
      normalized,
      timeout,
      platform.createClient(timeout),
      true,
      null,
      null,
    );
  }

  HttpTransport._(
    this.origin,
    this.timeout,
    this._client,
    this._ownsClient,
    this._bearer,
    this._store,
  );

  final String origin;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;
  final String? _bearer;
  final SessionStore? _store;

  /// withBearer returns an independent authentication context sharing this connection.
  HttpTransport withBearer(String token) {
    if (!platform.isNative) {
      throw const ClientError('unimplemented');
    }
    if (!tokenPattern.hasMatch(token)) {
      throw const ClientError('invalid_argument');
    }
    return HttpTransport._(origin, timeout, _client, false, token, null);
  }

  /// withSession reads fresh credentials for every call to this origin.
  HttpTransport withSession(SessionStore store) {
    if (!platform.isNative) {
      throw const ClientError('unimplemented');
    }
    if (normalizeOrigin(store.origin) != origin) {
      throw const ClientError('failed_precondition');
    }
    if (store.coordinationKey.isEmpty) {
      throw const ClientError('invalid_argument');
    }
    return HttpTransport._(origin, timeout, _client, false, null, store);
  }

  /// close releases connections only on the original transport, including its copies.
  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<Object?> invoke(String operation, Map<String, Object?> input) async {
    if (conformanceEnabled) {
      currentConformanceCall?.elapsed.start();
      final barrier = currentConformanceCall?.arrive(
        ConformancePoint.sdkEntered,
        ConformanceFacts(operation: operation),
      );
      if (barrier != null) await barrier;
    }
    if (!platform.isSupported) {
      throw const ClientError('unimplemented');
    }
    if (!_operationPattern.hasMatch(operation)) {
      throw const ClientError('invalid_argument');
    }
    final Uint8List body;
    try {
      body = Uint8List.fromList(utf8.encode(jsonEncode(input)));
    } catch (_) {
      throw const ClientError('invalid_argument');
    }
    if (body.length > 4 * 1024 * 1024) {
      throw const ClientError('resource_exhausted');
    }
    final store = _store;
    final credentials = store == null ? null : await _read(store);
    if (store != null) {
      final key = (origin, store.coordinationKey);
      final uncertain = _uncertain[key];
      uncertain?.removeWhere((value) => value != credentials);
      if (uncertain?.isEmpty ?? false) _uncertain.remove(key);
    }
    if (operation == 'auth.refresh' && store is DeviceStore) {
      if (credentials == null ||
          input['refresh_token'] != credentials.refreshToken) {
        throw const ClientError('unauthenticated');
      }
      return (await _refresh(store, credentials)).toJson();
    }
    final token = operation == 'auth.refresh'
        ? null
        : credentials?.accessToken ?? _bearer;
    try {
      return await _send(operation, body, token);
    } on OperationError catch (error) {
      if (conformanceEnabled) {
        final call = currentConformanceCall;
        final barrier = call?.arrive(
          ConformancePoint.originalsRejected,
          ConformanceFacts(
            operation: operation,
            credentials: credentials,
            attempt: call.httpAttempts,
            code: error.code,
            status: error.status,
          ),
        );
        if (barrier != null) await barrier;
      }
      if (operation == 'auth.refresh' ||
          store == null ||
          credentials == null ||
          error.status != 401 ||
          error.code != 'invalid_token') {
        rethrow;
      }
      if (_uncertain[(origin, store.coordinationKey)]?.contains(credentials) ??
          false) {
        throw const ClientError('unauthenticated');
      }
      final refreshed = await _refresh(store, credentials);
      final latest = await _read(store);
      if (latest != refreshed) throw const ClientError('failed_precondition');
      return _send(operation, body, refreshed.accessToken);
    }
  }

  Future<SessionCredentials?> _read(SessionStore store) async {
    try {
      return store is DeviceStore
          ? await store.waitForSession(timeout)
          : await store.read();
    } on ClientError catch (error) {
      if (error.code == 'invalid_argument' ||
          error.code == 'data_loss' ||
          store is DeviceStore) {
        rethrow;
      }
      throw const ClientError('failed_precondition');
    } catch (_) {
      throw const ClientError('failed_precondition');
    }
  }

  Future<bool> _replace(
    SessionStore store,
    SessionCredentials expected,
    SessionCredentials? next, {
    OperationError? failure,
  }) async {
    try {
      return await store.compareAndSet(expected, next);
    } on ClientError catch (error) {
      if (store is DeviceStore) {
        throw ClientError(error.code, operationError: failure);
      }
      throw ClientError('failed_precondition', operationError: failure);
    } catch (_) {
      throw ClientError('failed_precondition', operationError: failure);
    }
  }

  Future<SessionCredentials> _refresh(
    SessionStore store,
    SessionCredentials expected,
  ) {
    final key = (origin, store.coordinationKey);
    final existing = _refreshes[key];
    if (existing != null && existing.expected == expected) {
      if (conformanceEnabled) {
        return observeRefresh(
          existing.result.future,
          existing,
          expected,
          initiator: false,
        );
      }
      return existing.result.future;
    }
    final flight = _RefreshFlight(expected);
    _refreshes[key] = flight;
    if (conformanceEnabled) startRefreshObservation(flight, expected);
    unawaited(() async {
      try {
        flight.result.complete(await _runRefresh(store, expected));
      } catch (error, stack) {
        flight.result.completeError(error, stack);
      } finally {
        if (identical(_refreshes[key], flight)) _refreshes.remove(key);
      }
    }());
    if (conformanceEnabled) {
      return observeRefresh(
        flight.result.future,
        flight,
        expected,
        initiator: true,
      );
    }
    return flight.result.future;
  }

  bool _sameSession(SessionCredentials left, SessionCredentials right) =>
      left.userId == right.userId && left.sessionId == right.sessionId;

  Future<SessionCredentials> _runRefresh(
    SessionStore store,
    SessionCredentials expected,
  ) async {
    final latest = await _read(store);
    if (latest == null) throw const ClientError('unauthenticated');
    if (!_sameSession(latest, expected)) {
      throw const ClientError('failed_precondition');
    }
    if (latest != expected) return latest;
    DeviceState? claimed;
    if (store is DeviceStore) {
      claimed = await store.claimRefresh(expected);
      if (claimed == null) {
        final winner = await _read(store);
        if (winner == null ||
            !_sameSession(winner, expected) ||
            winner == expected) {
          throw const ClientError('failed_precondition');
        }
        return winner;
      }
    }
    final key = (origin, store.coordinationKey);
    var confirmed = false;
    try {
      final value = await _send(
        'auth.refresh',
        utf8.encode(jsonEncode({'refresh_token': expected.refreshToken})),
        null,
      );
      final SessionCredentials refreshed;
      try {
        refreshed = SessionCredentials.fromJson(value);
      } on ClientError {
        throw const ClientError('internal');
      }
      if (!_sameSession(refreshed, expected)) {
        throw const ClientError('internal');
      }
      if (conformanceEnabled) {
        currentConformanceCall?.refreshObservation?.credentialsValidated = true;
      }
      final saved = store is DeviceStore
          ? await store.finishRefresh(claimed!, refreshed)
          : await _replace(store, expected, refreshed);
      if (!saved) {
        throw const ClientError('failed_precondition');
      }
      confirmed = true;
      if (conformanceEnabled) {
        currentConformanceCall?.refreshObservation?.credentialsStored = true;
      }
      return refreshed;
    } on OperationError catch (error) {
      if (error.status == 401) {
        confirmed = true;
        if (conformanceEnabled) {
          currentConformanceCall?.refreshObservation?.rejected401 = true;
        }
        if (store is DeviceStore) {
          try {
            await store.finishRefresh(claimed!, null);
          } on ClientError catch (failure) {
            throw ClientError(failure.code, operationError: error);
          }
        } else {
          await _replace(store, expected, null, failure: error);
        }
      }
      rethrow;
    } finally {
      // Only saved success or a validated rejection rules out token reuse.
      if (!confirmed) {
        (_uncertain[key] ??= {}).add(expected);
      }
    }
  }

  Future<Object?> _send(String operation, List<int> body, String? token) async {
    if (conformanceEnabled) observeHttp(operation);
    if (conformanceEnabled && operation == 'auth.refresh') {
      currentConformanceCall?.refreshObservation?.attempt =
          currentConformanceCall?.httpObservation;
    }
    final abort = Completer<void>();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.requestCancel();
      }
      if (!abort.isCompleted) abort.complete();
    });
    int? status;
    try {
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse('$origin/$operation'),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['content-type'] = 'application/json'
            ..bodyBytes = body;
      if (token != null) request.headers['authorization'] = 'Bearer $token';
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.record(
          ConformancePhase.sending,
          null,
        );
      }
      // IOClient attaches abort only after opening the connection.
      final response = await _client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () {
              if (conformanceEnabled) {
                currentConformanceCall?.httpObservation?.requestCancel();
              }
              if (!abort.isCompleted) abort.complete();
              throw const ClientError('deadline_exceeded');
            },
          );
      status = response.statusCode;
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.record(
          ConformancePhase.response,
          status,
        );
        currentConformanceCall?.httpObservation?.transport(
          ConformanceTransportPhase.headers,
        );
      }
      if (status >= 300 && status < 400) {
        if (conformanceEnabled) {
          currentConformanceCall?.httpObservation?.requestCancel();
        }
        if (!abort.isCompleted) abort.complete();
        await response.stream.listen(null).cancel();
        if (conformanceEnabled) {
          currentConformanceCall?.httpObservation?.closeReader();
        }
        throw ClientError('internal', status: status);
      }
      // Dart pins da6595cd6bb5d4c0a185d759a025e879ff06e631 (3.13.0) and
      // 04bcd1036cdc799ac6564988f159ee454d42c822 (3.13.5):
      // sdk/lib/internal/bytes_builder.dart:179-219 retains exact owned chunks;
      // copy:true grows with spare capacity (:119-137), outside this proof.
      final bytes = BytesBuilder(copy: false);
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.readerStarted = true;
      }
      await for (final chunk in response.stream) {
        if (conformanceEnabled) {
          currentConformanceCall?.httpObservation?.read(chunk.length);
        }
        if (chunk.length > 1024 * 1024 - bytes.length) {
          if (conformanceEnabled) {
            currentConformanceCall?.httpObservation?.transport(
              ConformanceTransportPhase.limit,
            );
            currentConformanceCall?.httpObservation?.requestCancel();
          }
          if (!abort.isCompleted) abort.complete();
          throw ClientError('resource_exhausted', status: status);
        }
        bytes.add(Uint8List.fromList(chunk));
        if (conformanceEnabled) {
          currentConformanceCall?.httpObservation?.retain(chunk.length);
        }
      }
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.record(
          ConformancePhase.bodyComplete,
          status,
        );
      }
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.materializeBody();
      }
      final Object? value = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (status < 200 || status >= 300) {
        final code = value is Map<String, Object?> ? value['error'] : null;
        if (code is! String || !_errorPattern.hasMatch(code)) {
          throw ClientError('internal', status: status);
        }
        if (conformanceEnabled) {
          currentConformanceCall?.httpObservation?.responseConfirmed = true;
        }
        throw OperationError(
          code,
          status,
          responseMessage:
              value is Map<String, Object?> && value['message'] is String
              ? value['message']! as String
              : null,
        );
      }
      if (value is! Map<String, Object?>) {
        throw ClientError('internal', status: status);
      }
      if (conformanceEnabled) {
        currentConformanceCall?.httpObservation?.completed = true;
      }
      return value;
    } on OperationError {
      rethrow;
    } on ClientError {
      rethrow;
    } on FormatException {
      throw ClientError('internal', status: status);
    } catch (_) {
      throw ClientError(
        timedOut ? 'deadline_exceeded' : 'unavailable',
        status: status,
      );
    } finally {
      timer.cancel();
      if (conformanceEnabled) {
        if (currentConformanceCall?.httpObservation?.readerStarted ?? false) {
          currentConformanceCall?.httpObservation?.closeReader();
        }
        currentConformanceCall?.httpObservation?.runtimeRetainedBytes = 0;
        currentConformanceCall?.httpObservation?.finish(status);
      }
    }
  }
}
