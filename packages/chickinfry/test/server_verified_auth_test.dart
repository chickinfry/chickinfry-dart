import 'dart:async';
import 'dart:convert';

import 'package:chickinfry/server.dart';
import 'package:chickinfry/src/server/application.dart' show decodeHostMetadata;
import 'package:chickinfry/src/server/database.dart'
    show borrowedAuthConnection;
import 'package:test/test.dart';

const anonymous = {'version': 1, 'session': null};
Map<String, Object?> verified(int number) => {
  'version': 1,
  'session': {
    'id': 'session-$number',
    'user': {'id': 'user-$number', 'email': 'u$number@example.test'},
  },
};

ServerRequest request(String path) => ServerRequest(
  method: 'POST',
  uri: Uri.parse('https://example.test$path'),
  headers: {
    'content-type': 'application/json',
    'Authorization': 'Bearer raw',
    'Cookie': 'app=value',
    'Proxy-Authorization': 'Basic raw',
  },
);

Future<ServerResponse> call(
  Application app,
  Object? authFrame, {
  String path = '/probe.protected',
}) => app.handle(
  request(path),
  Stream.value(utf8.encode('{}')),
  authFrame: authFrame,
);

void main() {
  test(
    'verified sessions are request local and raw credentials are omitted',
    () async {
      var calls = 0;
      final together = Completer<void>();
      Future<Map<String, Object?>> dispatch(
        Context context,
        Map<String, Object?> _,
      ) async {
        calls++;
        expect(context.request.headers['authorization'], isNull);
        expect(context.request.headers['cookie'], isNull);
        expect(context.request.headers['proxy-authorization'], isNull);
        final session =
            (context as AuthenticatedContext<Session?>).auth.session;
        if (session == null) return {'session': null};
        if (calls == 3) together.complete();
        await together.future;
        return {
          'session': session.id,
          'user': session.user.id,
          'email': session.user.email,
        };
      }

      final app = Application(
        {
          'probe.public': dispatch,
          'probe.protected': dispatch,
          'auth.session': dispatch,
        },
        authEnabled: true,
        isPublic: (operation) => operation == 'probe.public',
      );
      expect((await call(app, anonymous)).status, 401);
      for (final invalid in [
        null,
        {'version': 1},
        {'version': 2, 'session': null},
        {'version': 1.0, 'session': null},
        {
          'version': 1,
          'session': {'id': ''},
        },
      ]) {
        expect((await call(app, invalid)).status, 500);
      }
      expect(
        (await app.handle(
          request('/probe.protected'),
          Stream.value([123, 125]),
        )).status,
        500,
      );
      expect((await call(app, verified(1), path: '/auth.session')).status, 404);
      expect(calls, 0);
      expect(
        jsonDecode((await call(app, anonymous, path: '/probe.public')).body),
        {'session': null},
      );

      final results = await Future.wait([
        call(app, verified(1)),
        call(app, verified(2), path: '/probe.public'),
      ]);
      for (var number = 1; number <= 2; number++) {
        expect(results[number - 1].status, 200);
        expect(jsonDecode(results[number - 1].body), {
          'session': 'session-$number',
          'user': 'user-$number',
          'email': 'u$number@example.test',
        });
      }
      expect(
        () => decodeHostMetadata(
          '{"auth":{"version":1,"session":null,"session":null}}',
        ),
        throwsFormatException,
      );
    },
  );

  test('auth-free requests retain only customer headers', () async {
    final app = Application({
      'probe.protected': (context, _) async {
        expect(context, isNot(isA<AuthenticatedContext<Session?>>()));
        expect(context.request.headers['authorization'], 'Bearer raw');
        expect(context.request.headers['cookie'], 'app=value');
        expect(context.request.headers['proxy-authorization'], isNull);
        return {};
      },
    });
    expect(
      (await app.handle(
        request('/probe.protected'),
        Stream.value([123, 125]),
      )).status,
      200,
    );
    expect((await call(app, null)).status, 500);
    expect((await call(app, verified(1))).status, 500);
  });

  test('a creating hook only borrows the current transaction', () async {
    const table = TableDefinition(
      'records',
      ['id'],
      [ColumnDefinition('id', 'id')],
    );
    final frames = <Map<String, Object?>>[];
    var postCommit = 0;
    Repository? retained;
    final app = Application(
      {},
      authEnabled: true,
      setup: () async => ApplicationOptions(
        authHooks: AuthHooks(
          userCreating: (db, user) async {
            retained = Repository(db, table);
            await expectLater(
              db.transaction((_) async {}),
              throwsA(isA<DatabaseError>()),
            );
            await retained!.findMany(limit: 1);
            if (user.id == 'fail') throw StateError('internal hook detail');
          },
          userCreated: (_) async {
            postCommit++;
          },
        ),
      ),
    );
    DatabaseConnection borrow(int lease) =>
        borrowedAuthConnection((frame) async {
          frames.add(frame);
          return {'rows': []};
        }, lease);
    Map<String, Object?> hook(String kind, [String user = 'normal']) => {
      'version': 1,
      'hook': kind,
      'user': {
        'id': user,
        'email': 'user@example.test',
        'createdAt': '2026-11-20T00:00:00.000000Z',
      },
    };
    expect((await app.handleAuthHook(hook('userCreating'))).status, 500);
    expect(
      (await app.handleAuthHook(
        hook('userCreated'),
        connection: borrow(1),
      )).status,
      500,
    );
    expect(frames, isEmpty);
    expect(postCommit, 0);
    final failed = await app.handleAuthHook(
      hook('userCreating', 'fail'),
      connection: borrow(7),
    );
    expect(failed.status, 500);
    expect(jsonDecode(failed.body), {'error': 'user_creation_failed'});
    expect(frames.single['op'], 'exec');
    expect(frames.single['lease'], 7);
    await expectLater(
      retained!.findMany(limit: 1),
      throwsA(
        isA<DatabaseError>().having(
          (error) => error.code,
          'code',
          'invalid_host_call',
        ),
      ),
    );
    expect(frames, hasLength(1));
    expect(
      (await app.handleAuthHook(
        hook('userCreating'),
        connection: borrow(9),
      )).status,
      200,
    );
    expect(frames.last['lease'], 9);
    expect((await app.handleAuthHook(hook('userCreated'))).status, 200);
    expect(postCommit, 1);
    expect(frames, hasLength(2));
  });
}
