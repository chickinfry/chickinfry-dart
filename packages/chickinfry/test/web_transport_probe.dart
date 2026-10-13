import 'dart:js_interop';

import 'package:chickinfry/chickinfry.dart';

@JS('fetchCalls')
external int get fetchCalls;

Future<void> main() async {
  final root = HttpTransport('https://example.com');
  final transports = [root.withBearer('A' * 43), root];
  var rejected = 0;
  try {
    for (final transport in transports) {
      ClientException? failure;
      try {
        await transport.invoke('thing.get', {});
      } on ClientException catch (error) {
        failure = error;
      }
      if (failure?.code == 'unsupported_platform' &&
          failure.toString().contains('not supported yet')) {
        rejected++;
      }
    }
    print(
      'web transport: unsupported_platform=$rejected; fetch calls=$fetchCalls',
    );
    if (fetchCalls != 0) {
      throw StateError('Expected zero fetch calls, observed $fetchCalls.');
    }
    if (rejected != transports.length) {
      throw StateError('Expected unsupported_platform before network access.');
    }
  } finally {
    root.close();
  }
}
