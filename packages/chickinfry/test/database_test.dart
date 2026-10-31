import 'dart:async';

import 'package:chickinfry/server.dart';
import 'package:test/test.dart';

const table = TableDefinition(
  'records',
  ['id', 'part'],
  [
    ColumnDefinition('id', 'id'),
    ColumnDefinition('part', 'integer'),
    ColumnDefinition('name', 'string'),
    ColumnDefinition('note', 'string', nullable: true, optional: true),
  ],
);
const id = '00000000-0000-0000-0000-000000000001';
const name = Field<String>('records', ColumnDefinition('name', 'string'));
const part = Field<int>('records', ColumnDefinition('part', 'integer'));

void main() {
  test('absent differs from explicit null', () {
    expect(const Value<String?>.absent().isPresent, isFalse);
    expect(const Value<String?>(null).isPresent, isTrue);
    expect(const Value<String?>(null).value, isNull);
    expect(() => const Value<String>.absent().value, throwsStateError);
  });
  test('parameterized conditions reject foreign columns and invalid values before I/O', () async {
    final frames = <Map<String, Object?>>[];
    final repository = Repository(
      DatabaseConnection((frame) async {
        frames.add(frame);
        return {'rows': <Object?>[]};
      }),
      table,
    );
    await repository.findMany(
      where: Filter.and([
        name.eq("quote'--"),
        Filter.not(part.isIn([1, 2])),
      ]),
      orderBy: [part.desc()],
      limit: 4,
      offset: 1,
    );
    expect(frames.single['params'], ["quote'--", 1, 2, 4, 1]);
    expect(
      frames.single['sql'],
      'SELECT "id", "part", "name", "note" FROM "records" WHERE ("name" = \$1 AND NOT ("part" IN (\$2, \$3))) ORDER BY "part" DESC LIMIT \$4 OFFSET \$5',
    );
    frames.clear();
    await expectLater(
      repository.insert({'id': id, 'part': 2147483648, 'name': 'x'}),
      throwsArgumentError,
    );
    await expectLater(
      repository.insert({'id': id, 'part': 1.5, 'name': 'x'}),
      throwsArgumentError,
    );
    await expectLater(
      repository.insert({'id': 'invalid', 'part': 1, 'name': 'x'}),
      throwsArgumentError,
    );
    await expectLater(repository.findById({'id': id}), throwsArgumentError);
    await expectLater(
      repository.findById({'id': id, 'part': null}),
      throwsArgumentError,
    );
    await expectLater(
      repository.update({'id': id, 'part': 1}, {'part': 2}),
      throwsArgumentError,
    );
    expect(() => repository.findMany(limit: -1), throwsArgumentError);
    expect(
      () => repository.findMany(limit: 9007199254740992),
      throwsArgumentError,
    );
    expect(
      () => repository.findMany(
        where: const Field<String>(
          'other',
          ColumnDefinition('name', 'string'),
        ).eq('x'),
      ),
      throwsArgumentError,
    );
    expect(frames, isEmpty);
  });
  test('omitted insert and unchanged patch preserve defaults', () async {
    final frames = <Map<String, Object?>>[];
    final repository = Repository(
      DatabaseConnection((frame) async {
        frames.add(frame);
        return {
          'rows': [
            {'id': id, 'part': 1, 'name': 'x', 'note': 'default'},
          ],
        };
      }),
      table,
    );
    await repository.insert({'id': id, 'part': 1, 'name': 'x'});
    expect(frames.last['params'], [id, 1, 'x']);
    await repository.insert({'id': id, 'part': 1, 'name': 'x', 'note': null});
    expect(frames.last['params'], [id, 1, 'x', null]);
    await repository.update({'id': id, 'part': 1}, {});
    expect((frames.last['sql'] as String).startsWith('SELECT'), isTrue);
  });
  test('delete returns the removed row or null', () async {
    final row = {'id': id, 'part': 1, 'name': 'x', 'note': null};
    var rows = <Map<String, Object?>>[row];
    final repository = Repository(
      DatabaseConnection((_) async => {'rows': rows}),
      table,
    );
    final key = {'id': id, 'part': 1};
    expect(await repository.delete(key), row);
    rows = [];
    expect(await repository.delete(key), isNull);
  });
  test('missing update target returns not_found', () async {
    final repository = Repository(
      DatabaseConnection((_) async => {'rows': <Object?>[]}),
      table,
    );
    final key = {'id': id, 'part': 1};
    for (final patch in <Map<String, Object?>>[
      {},
      {'name': 'changed'},
    ]) {
      await expectLater(
        repository.update(key, patch),
        throwsA(
          isA<DatabaseError>().having((e) => e.code, 'code', 'not_found'),
        ),
      );
    }
  });
  test('conditional writes and upsert use one parameterized statement and preserve results', () async {
    const writes = TableDefinition(
      'records',
      ['id', 'part'],
      [
        ColumnDefinition('id', 'id'),
        ColumnDefinition('part', 'integer'),
        ColumnDefinition('name', 'string'),
        ColumnDefinition('count', 'integer'),
        ColumnDefinition('note', 'string', nullable: true, optional: true),
      ],
    );
    final row = {'id': id, 'part': 1, 'name': 'new', 'count': 8, 'note': null};
    final frames = <Map<String, Object?>>[];
    var rows = <Map<String, Object?>>[row];
    String? error;
    final repository = Repository(
      DatabaseConnection((frame) async {
        frames.add(frame);
        return error == null ? {'rows': rows} : {'error': error};
      }),
      writes,
    );
    final key = {'id': id, 'part': 1};
    final condition = part.isIn([1]);
    final calls = <Future<Object?> Function()>[
      () => repository.updateIf(key, condition, {'name': 'new'}),
      () => repository.upsert({'id': id, 'part': 1, 'name': 'new', 'count': 8}),
      () => repository.increment(key, {'count': 1}),
      () =>
          repository.incrementIf(key, condition, {'count': 1}, {'name': 'new'}),
    ];
    final sql = [
      'UPDATE "records" SET "name" = \$1 WHERE "id" = \$2 AND "part" = \$3 AND ("part" IN (\$4)) RETURNING "id", "part", "name", "count", "note"',
      'INSERT INTO "records" ("id", "part", "name", "count") VALUES (\$1, \$2, \$3, \$4) ON CONFLICT ("id", "part") DO UPDATE SET "name" = EXCLUDED."name", "count" = EXCLUDED."count" RETURNING "id", "part", "name", "count", "note"',
      'UPDATE "records" SET "count" = "count" + \$1 WHERE "id" = \$2 AND "part" = \$3 RETURNING "id", "part", "name", "count", "note"',
      'UPDATE "records" SET "count" = "count" + \$1, "name" = \$2 WHERE "id" = \$3 AND "part" = \$4 AND ("part" IN (\$5)) RETURNING "id", "part", "name", "count", "note"',
    ];
    final params = [
      ['new', id, 1, 1],
      [id, 1, 'new', 8],
      [1, id, 1],
      [1, 'new', id, 1, 1],
    ];
    for (var index = 0; index < calls.length; index++) {
      rows = [row];
      expect(await calls[index](), row);
      expect(frames.last['sql'], sql[index]);
      expect(frames.last['params'], params[index]);
      rows = [];
      if (index == 0 || index == 3) {
        expect(await calls[index](), isNull);
      } else if (index == 2) {
        await expectLater(
          calls[index](),
          throwsA(
            isA<DatabaseError>().having((e) => e.code, 'code', 'not_found'),
          ),
        );
      } else {
        // An absent upsert target is inserted by the same statement.
        rows = [row];
        expect(await calls[index](), row);
      }
      error = '23505';
      await expectLater(
        calls[index](),
        throwsA(isA<DatabaseError>().having((e) => e.code, 'code', '23505')),
      );
      error = null;
    }
    frames.clear();
    final invalid = <Future<Object?> Function()>[
      () => repository.upsert({'id': id, 'name': 'new', 'count': 8}),
      () => repository.updateIf(key, condition, {'part': 2}),
      () => repository.increment(key, {'name': 1}),
      () => repository.increment(key, {'part': 1}),
      () => repository.increment(key, {'count': 0}),
      () => repository.increment(key, {'count': 9007199254740992}),
      () => repository.increment(key, <String, int>{}),
      () => repository.incrementIf(key, condition, {'count': 1}, {'count': 2}),
      () => repository.incrementIf(key, condition, {
        'count': 1,
      }, <String, Object?>{}),
      () => repository.updateIf(
        key,
        const Field<int>(
          'other',
          ColumnDefinition('count', 'integer'),
        ).isIn([1]),
        {'name': 'x'},
      ),
    ];
    for (final call in invalid) {
      await expectLater(Future.sync(call), throwsArgumentError);
    }
    expect(frames, isEmpty);
  });
  test('timestamp preserves microseconds and normalizes offset; invalid dates fail', () {
    const timestamp = ColumnDefinition('at', 'timestamp');
    expect(
      () => timestamp.validate('0001-01-01T00:00:00+01:00'),
      throwsArgumentError,
    );
    expect(
      () => timestamp.validate('9999-12-31T23:59:59-01:00'),
      throwsArgumentError,
    );
    expect(
      () => timestamp.validate('2026-10-15T00:00:00+99:99'),
      throwsArgumentError,
    );
    expect(
      () => const ColumnDefinition('day', 'date').validate('0000-01-01'),
      throwsArgumentError,
    );
    expect(
      timestamp.validate('2026-10-15T09:00:00.123456+09:00'),
      '2026-10-15T00:00:00.123456Z',
    );
    expect(
      timestamp.validate('2026-10-15T00:00:00.000001Z'),
      '2026-10-15T00:00:00.000001Z',
    );
    expect(
      () => timestamp.validate('2026-10-15T00:00:00.1234567Z'),
      throwsArgumentError,
    );
    expect(
      () => const ColumnDefinition('day', 'date').validate('2026-02-30'),
      throwsArgumentError,
    );
    expect(
      () => const ColumnDefinition('name', 'string').validate('x\u0000'),
      throwsArgumentError,
    );
  });
  test('transaction uses exec and seals connection and repository aliases before commit', () async {
    final frames = <Map<String, Object?>>[];
    late DatabaseConnection retained;
    late Repository alias;
    var nestedCalls = 0;
    final connection = DatabaseConnection((frame) async {
      frames.add(frame);
      if (frame['op'] == 'begin') return {'lease': 7};
      if (frame['op'] == 'commit') {
        await expectLater(
          Repository(retained, table).findMany(),
          throwsStateError,
        );
      }
      return {'rows': <Object?>[]};
    });
    expect(
      await connection.transaction((tx) async {
        retained = tx;
        alias = Repository(tx, table);
        await expectLater(
          tx.transaction((_) async {
            nestedCalls++;
          }),
          throwsStateError,
        );
        await alias.findMany();
        return 42;
      }),
      42,
    );
    expect(nestedCalls, 0);
    expect(frames.map((frame) => frame['op']), ['begin', 'exec', 'commit']);
    expect(frames[1]['lease'], 7);
    expect(frames[2]['lease'], 7);
    await expectLater(alias.findMany(), throwsStateError);
    await expectLater(Repository(retained, table).findMany(), throwsStateError);
    expect(frames.length, 3);
  });
  test('callback failure rolls back once; unknown commit never retries or compensates', () async {
    for (final unknown in [false, true]) {
      final operations = <Object?>[];
      var callbacks = 0;
      final connection = DatabaseConnection((frame) async {
        operations.add(frame['op']);
        if (frame['op'] == 'begin') return {'lease': 1};
        if (unknown && frame['op'] == 'commit') {
          return {'error': 'commit_unknown'};
        }
        return <String, Object?>{};
      });
      await expectLater(
        connection.transaction((_) async {
          callbacks++;
          if (!unknown) throw StateError('callback failed');
        }),
        unknown
            ? throwsA(
                isA<DatabaseError>().having(
                  (error) => error.code,
                  'code',
                  'commit_unknown',
                ),
              )
            : throwsStateError,
      );
      expect(callbacks, 1);
      expect(operations, ['begin', unknown ? 'commit' : 'rollback']);
    }
  });
  test('request close rejects late results and new calls', () async {
    final barrier = Completer<Map<String, Object?>>();
    var calls = 0;
    final connection = DatabaseConnection((_) {
      calls++;
      return barrier.future;
    });
    final pending = Repository(connection, table).findMany();
    connection.close();
    barrier.complete({'rows': <Object?>[]});
    await expectLater(pending, throwsStateError);
    await expectLater(
      Repository(connection, table).findMany(),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
