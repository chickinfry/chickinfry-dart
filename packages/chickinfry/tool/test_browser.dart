import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

Map<String, String> get _environment => {
  for (final name in const [
    'HOME',
    'PATH',
    'TMPDIR',
    'LANG',
    'LC_ALL',
    'PUB_CACHE',
    'CHROME_EXECUTABLE',
    'CHICKINFRY_DEVICE_TEST_ROOT',
  ])
    if (Platform.environment[name] != null) name: Platform.environment[name]!,
};

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('Pass an existing scratch directory.');
  final restore = File('${args.first}/browser_restore.js');
  final compiled = await Process.start(
    Platform.resolvedExecutable,
    ['compile', 'js', '-o', restore.path, 'test/browser_restore.dart'],
    mode: ProcessStartMode.inheritStdio,
    includeParentEnvironment: false,
    environment: _environment,
  );
  if (await compiled.exitCode != 0) {
    exitCode = 1;
    return;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18739);
  final peer = _Peer(restore);
  server.listen((request) async {
    try {
      await peer.handle(request);
    } catch (_) {
      // A cancelled Fetch closes streaming responses before the fixture finishes.
      try {
        await request.response.close();
      } catch (_) {}
    }
  });
  try {
    final runner = await Isolate.resolvePackageUri(
      Uri.parse('package:test/src/executable.dart'),
    );
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=${Platform.packageConfig ?? '.dart_tool/package_config.json'}',
        runner!.toFilePath(),
        '--platform',
        'chrome',
        '--reporter',
        'expanded',
        'test/browser_http_test.dart',
        'test/device/web_test.dart',
        '--concurrency=1',
        ...args.skip(1),
      ],
      mode: ProcessStartMode.inheritStdio,
      includeParentEnvironment: false,
      environment: _environment,
    );
    exitCode = await process.exitCode;
  } finally {
    peer.releaseAll();
    await server.close(force: true);
  }
}

class _Peer {
  _Peer(this.restore);
  final File restore;
  final calls = <String, int>{};
  final loads = <String, int>{};
  final sessions = <String, String>{};
  final attempts = <String, String>{};
  int attemptScreens = 0;
  final barriers = <String, Completer<void>>{};
  final arrived = <String>{};
  int destinations = 0;
  int executions = 0;
  bool validBoundary = true;
  String? mismatch;
  Object? restored;
  String? restoreParent;

  void releaseAll() {
    for (final barrier in barriers.values) {
      if (!barrier.isCompleted) barrier.complete();
    }
    barriers.clear();
  }

  void cookie(HttpResponse response, String value, {bool remove = false}) {
    response.cookies.add(
      Cookie('__Host-fixture', value)
        ..path = '/'
        ..httpOnly = true
        ..secure = true
        ..sameSite = SameSite.strict
        ..maxAge = remove ? 0 : 3600,
    );
  }

  String? credential(HttpRequest request) {
    final values = request.cookies.where((c) => c.name == '__Host-fixture');
    return values.length == 1 ? values.single.value : null;
  }

  Map<String, Object?> publicSession(String account) => {
    'id': account,
    'email': '$account@example.test',
    'sessionId': 'session-$account',
    'expiresAt': '2030-01-01T00:00:00Z',
  };

  Future<void> json(
    HttpResponse response,
    Object value, [
    int status = 200,
  ]) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('cache-control', 'no-store');
    response.write(jsonEncode(value));
    await response.close();
  }

  Future<void> handle(HttpRequest request) async {
    if (request.uri.path.startsWith('/restore.')) {
      loads.update(request.uri.path, (n) => n + 1, ifAbsent: () => 1);
    }
    if (request.uri.path == '/restore.html') {
      final parent = Uri.tryParse(request.headers.value('referer') ?? '');
      if (parent?.scheme != 'http' || parent?.host != '127.0.0.1') {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      if (parent!.origin != 'http://127.0.0.1:18739') {
        restoreParent = parent.origin;
      }
      // Keep the test runner's frame origin across a child document reload.
      request.response.headers
        ..removeAll('x-frame-options')
        ..set(
          'content-security-policy',
          'frame-ancestors ${restoreParent ?? parent.origin}',
        )
        ..contentType = ContentType.html;
      request.response.write('<script src="/restore.js"></script>');
      await request.response.close();
      return;
    }
    if (request.uri.path == '/restore.js') {
      request.response.headers.contentType = ContentType('text', 'javascript');
      await request.response.addStream(restore.openRead());
      await request.response.close();
      return;
    }
    if (request.uri.path == '/destination') {
      destinations++;
      await json(request.response, {});
      return;
    }
    final origin = request.headers.value('origin');
    final uri = origin == null ? null : Uri.tryParse(origin);
    if (uri?.scheme != 'http' ||
        !{'localhost', '127.0.0.1'}.contains(uri?.host)) {
      await json(request.response, {'error': 'origin_not_allowed'}, 403);
      return;
    }
    request.response.headers
      ..set('access-control-allow-origin', origin!)
      ..set('access-control-allow-credentials', 'true')
      ..set('access-control-allow-headers', 'content-type,x-chik-browser')
      ..set('access-control-allow-methods', 'POST');
    if (request.method == 'OPTIONS') {
      await request.response.close();
      return;
    }
    final operation = request.uri.path.substring(1);
    final input = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    if (operation == 'test.control') {
      if (input['reset'] == true) {
        releaseAll();
        calls.clear();
        loads.clear();
        sessions.clear();
        attempts.clear();
        attemptScreens = 0;
        arrived.clear();
        destinations = 0;
        executions = 0;
        validBoundary = true;
        restored = null;
        restoreParent = null;
        cookie(request.response, '', remove: true);
      }
      if (input['restored'] case final Map<String, Object?> value) {
        restored = value;
      }
      if (input['mismatch'] case final String field) mismatch = field;
      if (input['release'] case final String key) {
        final barrier = barriers[key];
        if (barrier != null && !barrier.isCompleted) barrier.complete();
      }
      if (input['revoke'] case final String account) {
        sessions.removeWhere((_, value) => value == account);
      }
      await json(request.response, {
        'calls': calls,
        'attemptScreens': attemptScreens,
        'restored': restored,
        'loads': loads,
        'destinations': destinations,
        'boundary': validBoundary,
        'arrived': arrived.toList(),
        'active': sessions.values.toList(),
        'executions': executions,
      });
      return;
    }
    calls.update(operation, (n) => n + 1, ifAbsent: () => 1);
    final valid =
        request.method == 'POST' &&
        request.headers.contentType?.mimeType == 'application/json' &&
        request.headers.value('x-chik-browser') == '1' &&
        request.headers.value('authorization') == null;
    validBoundary = validBoundary && valid;
    if (!valid) {
      await json(request.response, {'error': 'invalid_browser_request'}, 403);
      return;
    }
    final captured = credential(request);
    final account = sessions[captured];
    Future<void> barrier() async {
      if (input['hold'] case final String key) {
        final wait = barriers.putIfAbsent(key, Completer<void>.new);
        arrived.add(key);
        await wait.future;
      }
    }

    switch (operation) {
      case 'auth.send_verification_email':
        if (attempts.containsKey(input['attempt'])) {
          attemptScreens++;
          await json(request.response, {
            'accepted': true,
            'matches': attempts[input['attempt']] == input['expectedEmail'],
          });
        } else {
          await json(request.response, {'error': 'invalid_code'}, 400);
        }
      case 'auth.verify_email':
      case 'auth.signin_with_code':
        if (!attempts.containsKey(input['attempt'])) {
          await json(request.response, {'error': 'invalid_code'}, 400);
          return;
        }
        attempts.remove(input['attempt']);
        final value = base64Url.encode(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
        sessions[value] = 'a';
        cookie(request.response, value);
        await json(request.response, publicSession('a'));
      case 'auth.signin':
      case 'auth.signup':
      case 'auth.identity':
        if (operation == 'auth.signup' && input['pending'] == true) {
          final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
          final hex = bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          final id =
              '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
          attempts[id] = input['email'] as String;
          await barrier();
          await json(request.response, {'accepted': true, 'attempt': id});
          return;
        }
        final name = input['account'] as String? ?? 'a';
        if (captured != null) sessions.remove(captured);
        final value = base64Url.encode(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
        sessions[value] = name;
        await barrier();
        if (input['omitCookie'] != true) cookie(request.response, value);
        await json(request.response, publicSession(name));
      case 'auth.session':
        if (account == null) {
          await json(request.response, {'error': 'invalid_token'}, 401);
        } else {
          final value = publicSession(account);
          if (mismatch != null) {
            value[mismatch!] = 'different';
            mismatch = null;
          }
          await json(request.response, value);
        }
      case 'auth.logout':
        if (input['fail'] == true) {
          await json(request.response, {'error': 'database_error'}, 500);
          return;
        }
        sessions.remove(captured);
        await barrier();
        cookie(request.response, '', remove: true);
        await json(request.response, {});
      case 'thing.protected':
        if (account != null) executions++;
        await barrier();
        await json(
          request.response,
          account == null ? {'error': 'invalid_token'} : {'id': account},
          account == null ? 401 : 200,
        );
      case 'thing.reject':
        await barrier();
        final status = input['status'] as int;
        await json(request.response, {
          'error': status == 401 ? 'invalid_token' : 'not_allowed',
        }, status);
      case 'thing.redirect':
        request.response.statusCode = input['status'] as int;
        request.response.headers.set(
          'location',
          input['external'] == true
              ? 'http://localhost:18739/destination'
              : '/destination',
        );
        await request.response.close();
      case 'thing.bytes':
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"data":"');
        request.response.write('x' * ((input['size'] as int) - 11));
        request.response.write('"}');
        await request.response.close();
      case 'thing.slow':
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"data":"');
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.write('end"}');
        await request.response.close();
      case 'thing.cors':
        request.response.headers.removeAll('access-control-allow-origin');
        await json(request.response, {});
      case 'thing.invalid':
        request.response.statusCode = input['status'] as int? ?? 200;
        request.response.add(
          input['utf8'] == false ? [255] : utf8.encode(input['body'] as String),
        );
        await request.response.close();
      default:
        await json(request.response, input);
    }
  }
}
