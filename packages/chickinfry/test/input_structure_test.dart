import 'dart:convert';

import 'package:chickinfry/server.dart';
import 'package:test/test.dart';

import 'fixtures/input_structure_io.dart'
    if (dart.library.js_interop) 'fixtures/input_structure_web.dart';

Future<void> main() async {
  final fixture =
      jsonDecode(await loadInputStructure()) as Map<String, dynamic>;
  var calls = 0;
  var contexts = 0;
  late Application app;
  setUp(() {
    calls = 0;
    contexts = 0;
    app = Application(
      {
        for (final name in [
          ...(fixture['inputs'] as Map).keys.cast<String>(),
          'auth.signin',
        ])
          name: (context, input) async {
            calls++;
            return {};
          },
      },
      contextFactory: (request, connection) {
        contexts++;
        return Context(request);
      },
    );
  });
  Future<ServerResponse> call(
    String body, [
    String operation = 'catalog.create',
  ]) => app.handle(
    ServerRequest(
      method: 'POST',
      uri: Uri.parse('https://example.test/$operation'),
      headers: {'content-type': 'application/json'},
    ),
    Stream.value(utf8.encode(body)),
  );

  for (final vector
      in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('shared input structure: ${vector['name']}', () async {
      final operation = vector['operation'] as String;
      final input = jsonDecode(jsonEncode(fixture['inputs'][operation])) as Map;
      final path = vector['path'] as List;
      Object? parent = input;
      for (final key in path.take(path.length - 1)) {
        parent = parent is List ? parent[key as int] : (parent as Map)[key];
      }
      const marker = '__input_structure_value__';
      (parent as Map)[path.last] = marker;
      final value = vector['value'] as Map;
      final arrays = value.containsKey('depth')
          ? (value['depth'] as int) -
                ((fixture['rootDepth'] as int) + path.length - 1)
          : 0;
      final leaf = value.containsKey('integerDigits')
          ? '9' * (value['integerDigits'] as int)
          : value['rawJSON'] ?? value['leafJSON'];
      final raw = '${'[' * arrays}$leaf${']' * arrays}';
      final replacement = value.containsKey('duplicateFinalJSON')
          ? '$raw,${jsonEncode(path.last)}:${value['duplicateFinalJSON']}'
          : raw;
      final body = jsonEncode(input)
          .replaceFirst(jsonEncode(marker), replacement);
      final response = await call(body, operation);
      expect(calls, vector['expectedHandlerCalls']);
      expect(contexts, vector['expectedHandlerCalls']);
      expect(response.status, vector['expectedStatus']);
      expect(jsonDecode(response.body), {
        if (vector.containsKey('expectedError'))
          'error': vector['expectedError'],
      });
    });
  }

  final invalidStructures = <String, String>{
    'duplicate root key': '{"a":0,"a":1}',
    'duplicate nested key': '{"items":[{"a":0,"a":1}]}',
    'escaped duplicate key': r'{"a":0,"\u0061":1}',
    'escaped supplementary duplicate key': r'{"\ud83d\ude00":0,"😀":1}',
    'duplicate empty key': '{"":0,"":1}',
    'overwritten overflow': '{"ignored":1e999,"ignored":0}',
    'overwritten deep value':
        '{"ignored":${'[' * 20000}0${']' * 20000},"ignored":0}',
    'high surrogate value': r'{"ignored":"\ud800"}',
    'low surrogate value': r'{"ignored":"\udfff"}',
    'surrogate key': r'{"\ud800":0}',
    'nested surrogate': r'{"a":[{"b":"\ud800x"}]}',
    'high high low surrogate': r'{"a":"\ud800\ud800\udc00"}',
    'low high surrogate': r'{"a":"\udc00\ud800"}',
    'split surrogate': r'{"a":"\ud800\\udc00"}',
    'surrogate before overwritten value': r'{"a":"\ud800","a":0}',
    'long positive integer overflow': '{"a":${'9' * 5000}}',
    'long negative integer overflow': '{"a":-${'9' * 5000}}',
  };
  for (final entry in invalidStructures.entries) {
    test('I-JSON structure: ${entry.key}', () async {
      final response = await call(entry.value);
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_input"}');
      expect(calls, 0);
      expect(contexts, 0);
    });
  }

  final validStructures = <String, String>{
    'same key in different objects': '{"a":{"x":0},"b":{"x":1}}',
    'same key in sibling array objects': '{"a":[{"x":0},{"x":1}]}',
    'escaped literal and control keys': r'{"\\ud800":0,"\n":1,"\"":2}',
    'surrogate pair': r'{"\ud800\udc00":"\udbff\udfff"}',
    'literal supplementary value': '{"a":"😀"}',
    'long finite integer': '{"a":${'9' * 300}}',
    'long finite negative integer': '{"a":-${'9' * 300}}',
    'finite precision loss': '{"a":9007199254740993,"b":1.234567890123456789}',
  };
  for (final entry in validStructures.entries) {
    test('I-JSON accepted: ${entry.key}', () async {
      final response = await call(entry.value);
      expect(response.status, 200);
      expect(calls, 1);
      expect(contexts, 1);
    });
  }

  final malformedStructures = <String, String>{
    'duplicate followed by bad escape': r'{"a":0,"a":"\q"}',
    'duplicate followed by trailing comma': '{"a":0,"a":1,}',
    'surrogate followed by bad escape': r'{"a":"\ud800","b":"\q"}',
    'surrogate followed by malformed number': r'{"a":"\udc00","b":01}',
    'overflow followed by trailing data': '{"a":1e999}!',
    'overwritten deep duplicate then syntax error':
        '{"a":${'[' * 20000}0${']' * 20000},"a":0,}',
  };
  for (final entry in malformedStructures.entries) {
    test('syntax wins over I-JSON structure: ${entry.key}', () async {
      final response = await call(entry.value);
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_json"}');
      expect(calls, 0);
      expect(contexts, 0);
    });
  }

  test(
    'decoder-limit depth is rejected before context or handler work',
    () async {
      final response = await call(
        '{"ignored":${'[' * 100000}0${']' * 100000}}',
      );
      expect(calls, 0);
      expect(contexts, 0);
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_input"}');
    },
  );

  final deepValue = '${'[' * 64}0${']' * 64}';
  final malformedDeepBodies = <String, String>{
    'garbage before nesting': 'x${'[' * 65}',
    'unclosed review reproduction': '{"v":${'[' * 64}0',
    'bad escape before nesting':
        r'{"s":"\q","v":'
        '$deepValue}',
    'bad escape inside nesting':
        '{"v":${'[' * 64}'
        r'"\q"'
        '${']' * 64}}',
    'bad unicode escape':
        '{"v":$deepValue,"s":'
        r'"\u12xz"}',
    'short unicode escape':
        '{"v":$deepValue,"s":'
        r'"\u123"}',
    'unterminated string': '{"v":$deepValue,"s":"tail',
    'unescaped control': '{"v":$deepValue,"s":"line\nfeed"}',
    'unbalanced deep body': '{"v":$deepValue',
    'mismatched closing container': '{"v":${'[' * 64}0${']' * 63}}}',
    'trailing garbage': '{"v":$deepValue}x',
    'second root value': '{"v":$deepValue} []',
    'array trailing comma': '{"v":$deepValue,"a":[0,]}',
    'object trailing comma': '{"v":$deepValue,}',
    'missing comma': '{"v":$deepValue "s":0}',
    'missing colon': '{"v":$deepValue,"s" 0}',
    'non-string key': '{"v":$deepValue,0:0}',
    'missing value': '{"v":$deepValue,"s":}',
    'leading zero': '{"v":$deepValue,"n":01}',
    'missing fraction digits': '{"v":$deepValue,"n":1.}',
    'missing exponent digits': '{"v":$deepValue,"n":1e+}',
    'missing integer digits': '{"v":$deepValue,"n":-}',
    'invalid literal': '{"v":$deepValue,"b":tru}',
  };
  for (final entry in malformedDeepBodies.entries) {
    test('deep malformed JSON: ${entry.key}', () async {
      final response = await call(entry.value);
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_json"}');
      expect(contexts, 0);
      expect(calls, 0);
    });
  }

  test('deep valid JSON grammar retains the depth error', () async {
    for (final value in [
      r'{"s":"\"\\\/\b\f\n\r\t\u005b\uD800","n":[-0,0,12,-12.34,1e2,1E-2,1e+999],"v":[true,false,null,{},[]]}',
      '${'{"a":[' * 40}0${']}' * 40}',
      '{"a":0,"a":$deepValue}',
    ]) {
      final response = await call(
        ' \r\n\t{"v":${'[' * 64}$value${']' * 64}} \t',
      );
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_input"}');
      expect(contexts, 0);
      expect(calls, 0);
    }
  });

  test('auth-named operations share input structure validation', () async {
    for (final value in [
      '${'[' * 64}null${']' * 64}',
      '1e999',
      '-1e999',
      '{"a":0,"a":1}',
      r'"\ud800"',
    ]) {
      final response = await call('{"ignored":$value}', 'auth.signin');
      expect(calls, 0);
      expect(contexts, 0);
      expect(response.status, 400);
      expect(response.body, '{"error":"invalid_input"}');
    }
    expect((await call('{}', 'auth.signin')).status, 200);
    expect(calls, 1);
  });

  test(
    'strings and sibling containers do not increase nesting depth',
    () async {
      final body = jsonEncode({
        'quoted': '${'[{\\"' * 1000}tail\\',
        'siblings': List.generate(100, (_) => {'value': null}),
      });
      final response = await call(body);
      expect(response.status, 200);
      expect(calls, 1);
    },
  );

  test('object nesting counts the root container', () async {
    for (final depth in [64, 65]) {
      calls = 0;
      final response = await call('${'{"v":' * depth}null${'}' * depth}');
      expect(response.status, depth == 64 ? 200 : 400);
      expect(calls, depth == 64 ? 1 : 0);
      if (depth == 65) {
        expect(response.body, '{"error":"invalid_input"}');
      }
    }
  });

  test(
    'malformed JSON and non-object roots retain their error envelopes',
    () async {
      for (final body in ['{', '{"v":NaN}', '{"v":Infinity}', '{"v":1e}']) {
        final response = await call(body);
        expect(response.status, 400);
        expect(response.body, '{"error":"invalid_json"}');
      }
      for (final body in ['[]', 'null', 'true', '1', '"text"']) {
        final response = await call(body);
        expect(response.status, 400);
        expect(response.body, '{"error":"invalid_input"}');
      }
      expect(calls, 0);
    },
  );
}
