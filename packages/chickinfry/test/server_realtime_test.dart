import 'dart:convert';

import 'package:chickinfry/server.dart';
import 'package:test/test.dart';

ServerRequest request(String path) => ServerRequest(
  method: 'POST',
  uri: Uri.parse('https://example.test$path'),
  headers: {'content-type': 'application/json'},
);

Future<ServerResponse> call(
  Application app,
  String path,
  Object? input, {
  RealtimeCall? realtime,
  Object? authFrame,
}) => authFrame == null
    ? app.handle(
        request(path),
        Stream.value(utf8.encode(jsonEncode(input))),
        realtime: realtime,
      )
    : app.handle(
        request(path),
        Stream.value(utf8.encode(jsonEncode(input))),
        realtime: realtime,
        authFrame: authFrame,
      );

final class RealtimeContext extends Context {
  RealtimeContext(super.request, this.realtime);

  final Realtime realtime;
}

void main() {
  test(
    'publish sends one frame and maps host replies like TypeScript',
    () async {
      final frames = <Map<String, Object?>>[];
      final replies = <Object>[];
      final realtime = Realtime((frame) async {
        frames.add(frame);
        final reply = replies.removeAt(0);
        if (reply is Exception) throw reply;
        return reply as Map<String, Object?>;
      });
      Future<Object?> publish(Object reply) async {
        replies.add(reply);
        try {
          await realtime.publish('orders', {
            'id': 'A',
            'items': [1, 2],
          });
          return null;
        } on OperationError catch (error) {
          return '${error.status}:${error.code}';
        }
      }

      expect(await publish(<String, Object?>{}), isNull);
      expect(frames.single, {
        'op': 'publish',
        'input': {
          'channel': 'orders',
          'payload': {
            'id': 'A',
            'items': [1, 2],
          },
        },
      });
      expect(
        await publish({'error': 'unauthorized_project', 'status': 403}),
        '403:unauthorized_project',
      );
      expect(
        await publish({
          'error': 'realtime_publish_outcome_unknown',
          'status': 503,
        }),
        '503:realtime_publish_outcome_unknown',
      );
      expect(
        await publish({'error': 'binding_unavailable'}),
        '503:service_unavailable',
      );
      for (final reply in <Object>[
        {'ok': true},
        {'error': 'conflict', 'status': 200},
        {'error': 'conflict', 'status': '409'},
        {'error': 'invalid_host_call'},
        Exception('host failure'),
      ]) {
        expect(await publish(reply), '500:operation_failed');
      }
    },
  );

  test('a publish rejection reaches the operation response', () async {
    final app = Application(
      {
        'orders.announce': (context, _) async {
          await (context as RealtimeContext).realtime.publish('orders', 'A');
          return {'value': 'published'};
        },
      },
      contextFactory: (request, _, _, _, _, _, realtime) =>
          RealtimeContext(request, Realtime(realtime!)),
    );
    final accepted = await call(
      app,
      '/orders.announce',
      {},
      realtime: (_) async => {},
    );
    expect(
      [accepted.status, jsonDecode(accepted.body)],
      [
        200,
        {'value': 'published'},
      ],
    );
    final rejected = await call(
      app,
      '/orders.announce',
      {},
      realtime: (_) async => {'error': 'unauthorized_project', 'status': 403},
    );
    expect(
      [rejected.status, jsonDecode(rejected.body)],
      [
        403,
        {'error': 'unauthorized_project'},
      ],
    );
  });

  test(
    'realtime authorization asks the application and denies by default',
    () async {
      Application app(RealtimeAuthorizer? authorize) => Application(
        {},
        setup: () async => ApplicationOptions(authorizeRealtime: authorize),
      );
      Future<Object?> decide(Application app, Object? input) async =>
          jsonDecode(
            (await call(
              app,
              '/realtime.authorize',
              input,
              realtime: (_) async => {},
            )).body,
          );

      final allowOrders = app((_, channel) async => channel == 'orders');
      expect(await decide(allowOrders, {'channel': 'orders'}), {
        'allowed': true,
      });
      expect(await decide(allowOrders, {'channel': 'other'}), {
        'allowed': false,
      });
      expect(await decide(allowOrders, {'channel': 4}), {'allowed': false});
      expect(await decide(app(null), {'channel': 'orders'}), {
        'allowed': false,
      });
      expect(
        await decide(app((_, _) async => throw StateError('private')), {
          'channel': 'orders',
        }),
        {'allowed': false},
      );
      expect(await decide(Application({}), {'channel': 'orders'}), {
        'allowed': false,
      });
    },
  );

  test(
    'realtime authorization takes the optional revalidated session',
    () async {
      final sessions = <String?>[];
      final app = Application(
        {},
        authEnabled: true,
        setup: () async => ApplicationOptions(
          authorizeRealtime: (context, _) async {
            sessions.add(
              (context as AuthenticatedContext<Session?>).auth.session?.id,
            );
            return true;
          },
        ),
      );
      final anonymous = await call(
        app,
        '/realtime.authorize',
        {'channel': 'orders'},
        realtime: (_) async => {},
        authFrame: {'version': 1, 'session': null},
      );
      final signedIn = await call(
        app,
        '/realtime.authorize',
        {'channel': 'orders'},
        realtime: (_) async => {},
        authFrame: {
          'version': 1,
          'session': {
            'id': 'session-1',
            'user': {'id': 'user-1', 'email': 'u1@example.test'},
          },
        },
      );
      expect([anonymous.status, signedIn.status], [200, 200]);
      expect(sessions, [null, 'session-1']);
    },
  );
}
