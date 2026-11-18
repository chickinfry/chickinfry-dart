import 'dart:async';

final class Value<T> {
  const Value(T value) : _value = value, isPresent = true;
  const Value.absent() : _value = null, isPresent = false;
  final T? _value;
  final bool isPresent;
  T get value {
    if (!isPresent) throw StateError('Value is absent.');
    return _value as T;
  }
}

final class DatabaseError implements Exception {
  const DatabaseError(this.code);
  final String code;
  @override
  String toString() => 'Database operation failed.';
}

typedef DatabaseCall = Future<Map<String, Object?>> Function(
  Map<String, Object?> frame,
);

final class DatabaseConnection {
  DatabaseConnection(DatabaseCall call) : _call = call, _lease = null;
  DatabaseConnection._(this._call, this._lease);
  final DatabaseCall _call;
  final int? _lease;
  bool _closed = false;
  bool _transaction = false;

  void close() => _closed = true;
  void _check() {
    if (_closed) throw StateError('Database connection is closed.');
  }

  Future<Map<String, Object?>> _invoke(
    String op, [
    String? sql,
    List<Object?>? params,
  ]) async {
    _check();
    final result = await _call({
      'op': op,
      if (_lease != null) 'lease': _lease,
      if (sql != null) 'sql': sql,
      if (params != null) 'params': params,
    });
    _check();
    if (result.containsKey('error')) {
      final code = result['error'];
      throw DatabaseError(
        code is String &&
                RegExp(
                  r'^(?:[A-Z0-9]{5}|database_failed|commit_unknown|invalid_host_call)$',
                ).hasMatch(code)
            ? code
            : 'database_failed',
      );
    }
    return result;
  }

  Future<List<Map<String, Object?>>> _query(
    String sql,
    List<Object?> params,
  ) async {
    final result = await _invoke(
      _lease == null ? 'query' : 'exec',
      sql,
      params,
    );
    final rows = result['rows'];
    if (rows is! List) throw const DatabaseError('database_failed');
    return rows
        .map((row) => (row as Map).cast<String, Object?>())
        .toList(growable: false);
  }

  Future<T> transaction<T>(Future<T> Function(DatabaseConnection) work) async {
    _check();
    if (_lease != null || _transaction) {
      throw StateError('Nested transactions are unavailable.');
    }
    _transaction = true;
    DatabaseConnection? transaction;
    try {
      final result = await _invoke('begin');
      final lease = result['lease'];
      if (lease is! int || lease <= 0 || lease > 9007199254740991) {
        throw const DatabaseError('database_failed');
      }
      transaction = DatabaseConnection._(_call, lease);
      late T value;
      try {
        value = await work(transaction);
      } catch (_) {
        transaction.close();
        await DatabaseConnection._(_call, lease)._invoke('rollback');
        rethrow;
      }
      // Seal retained aliases before commit, including when its result is unknown.
      transaction.close();
      await DatabaseConnection._(_call, lease)._invoke('commit');
      return value;
    } finally {
      transaction?.close();
      _transaction = false;
    }
  }
}

final class ColumnDefinition {
  const ColumnDefinition(
    this.name,
    this.kind, {
    this.nullable = false,
    this.optional = false,
  });
  final String name, kind;
  final bool nullable, optional;
  static final _extraTimestampZeros = RegExp(r'(\.\d{3,5}?)0+Z$');

  Object? validate(Object? value) {
    if (value == null) {
      if (nullable) return null;
      throw ArgumentError('Column requires a value.');
    }
    if (kind == 'integer') {
      if (value is! int || value < -2147483648 || value > 2147483647) {
        throw ArgumentError('Integer is outside its range.');
      }
      return value;
    }
    if (value is! String || value.contains('\u0000')) {
      throw ArgumentError('Invalid string.');
    }
    if (kind == 'id' &&
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(value)) {
      throw ArgumentError('Invalid identifier.');
    }
    if (kind == 'date') {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
        throw ArgumentError('Invalid date.');
      }
      final date = DateTime.tryParse(value);
      if (date == null ||
          date.year < 1 ||
          date.toIso8601String().substring(0, 10) != value) {
        throw ArgumentError('Invalid date.');
      }
    }
    if (kind == 'timestamp') {
      ColumnDefinition(
        name,
        'date',
      ).validate(value.substring(0, value.length < 10 ? value.length : 10));
      if (!RegExp(
        r'^\d{4}-\d{2}-\d{2}[T ](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3])(?::?[0-5]\d)?)$',
      ).hasMatch(value)) {
        throw ArgumentError('Invalid timestamp.');
      }
      final utc = DateTime.tryParse(value)?.toUtc();
      if (utc == null || utc.year < 1 || utc.year > 9999) {
        throw ArgumentError('Invalid timestamp.');
      }
      return utc.toIso8601String().replaceFirstMapped(
        _extraTimestampZeros,
        (match) => '${match[1]}Z',
      );
    }
    return value;
  }
}

final class TableDefinition {
  const TableDefinition(this.name, this.primaryKey, this.columns);
  final String name;
  final List<String> primaryKey;
  final List<ColumnDefinition> columns;
  ColumnDefinition column(String name) => columns.firstWhere(
    (column) => column.name == name,
    orElse: () => throw ArgumentError('Unknown column.'),
  );
}

String _quote(String name) => '"${name.replaceAll('"', '""')}"';

final class Field<T> {
  const Field(this.table, this.column);
  final String table;
  final ColumnDefinition column;
  Filter eq(T value) => value == null ? isNull() : _compare('=', value);
  Filter ne(T value) => value == null ? isNotNull() : _compare('<>', value);
  Filter gt(T value) => _compare('>', value);
  Filter gte(T value) => _compare('>=', value);
  Filter lt(T value) => _compare('<', value);
  Filter lte(T value) => _compare('<=', value);
  Filter _compare(String op, T value) => Filter._((name, params) {
    _belongs(name);
    params.add(column.validate(value));
    return '${_quote(column.name)} $op \$${params.length}';
  });
  Filter isIn(Iterable<T> values) {
    final snapshot = List<T>.of(values);
    return Filter._((name, params) {
      _belongs(name);
      if (snapshot.isEmpty) return 'FALSE';
      final placeholders = snapshot
          .map((value) {
            params.add(column.validate(value));
            return '\$${params.length}';
          })
          .join(', ');
      return '${_quote(column.name)} IN ($placeholders)';
    });
  }

  Filter isNull() => _null(false);
  Filter isNotNull() => _null(true);
  Filter _null(bool negate) => Filter._((name, params) {
    _belongs(name);
    return '${_quote(column.name)} IS ${negate ? 'NOT ' : ''}NULL';
  });
  Order asc() => Order._(table, column.name, 'ASC');
  Order desc() => Order._(table, column.name, 'DESC');
  void _belongs(String name) {
    if (table != name) throw ArgumentError('Column belongs to another table.');
  }
}

final class Filter {
  const Filter._(this._sql);
  final String Function(String table, List<Object?> params) _sql;
  static Filter and(List<Filter> filters) => _combine('AND', filters);
  static Filter or(List<Filter> filters) => _combine('OR', filters);
  static Filter not(Filter filter) =>
      Filter._((table, params) => 'NOT (${filter._sql(table, params)})');
  static Filter _combine(String operator, List<Filter> filters) {
    if (filters.isEmpty) {
      throw ArgumentError('At least one condition is required.');
    }
    final snapshot = List<Filter>.of(filters);
    return Filter._(
      (table, params) =>
          '(${snapshot.map((filter) => filter._sql(table, params)).join(' $operator ')})',
    );
  }
}

final class Order {
  const Order._(this._table, this._column, this._direction);
  final String _table, _column, _direction;
  String _sql(String table) {
    if (table != _table) {
      throw ArgumentError('Column belongs to another table.');
    }
    return '${_quote(_column)} $_direction';
  }
}

final class Repository {
  Repository(this._connection, this._table);
  final DatabaseConnection _connection;
  final TableDefinition _table;
  String get _name => _quote(_table.name);
  String get _columns =>
      _table.columns.map((column) => _quote(column.name)).join(', ');

  Future<List<Map<String, Object?>>> _run(
    String sql,
    List<Object?> params,
  ) async {
    final rows = await _connection._query(sql, params);
    return rows
        .map((row) {
          if (row.length != _table.columns.length ||
              !_table.columns.every((column) => row.containsKey(column.name))) {
            throw const DatabaseError('database_failed');
          }
          return {
            for (final column in _table.columns)
              column.name: column.validate(row[column.name]),
          };
        })
        .toList(growable: false);
  }

  Map<String, Object?> _values(Map<String, Object?> values) => {
    for (final entry in values.entries)
      entry.key: _table.column(entry.key).validate(entry.value),
  };
  String _key(Map<String, Object?> key, List<Object?> params) {
    if (key.length != _table.primaryKey.length ||
        !_table.primaryKey.every(key.containsKey)) {
      throw ArgumentError('Complete primary key is required.');
    }
    return _table.primaryKey
        .map((name) {
          final value = key[name];
          if (value == null) {
            throw ArgumentError('Primary key requires a value.');
          }
          params.add(_table.column(name).validate(value));
          return '${_quote(name)} = \$${params.length}';
        })
        .join(' AND ');
  }

  Future<Map<String, Object?>> insert(Map<String, Object?> input) =>
      _insert(input);

  Future<Map<String, Object?>> upsert(Map<String, Object?> input) =>
      _insert(input, upsert: true);

  Future<Map<String, Object?>> _insert(
    Map<String, Object?> input, {
    bool upsert = false,
  }) async {
    final values = _values(input);
    for (final column in _table.columns) {
      if (!column.optional && !values.containsKey(column.name)) {
        throw ArgumentError('Required column is missing.');
      }
    }
    final params = values.values.toList();
    final clause = values.isEmpty
        ? 'DEFAULT VALUES'
        : '(${values.keys.map(_quote).join(', ')}) VALUES (${List.generate(params.length, (index) => '\$${index + 1}').join(', ')})';
    var conflict = '';
    if (upsert) {
      _key({
        for (final name in _table.primaryKey)
          if (values.containsKey(name)) name: values[name],
      }, []);
      final mutable = values.keys.where(
        (name) => !_table.primaryKey.contains(name),
      );
      if (mutable.isEmpty) {
        throw ArgumentError('Upsert requires mutable values.');
      }
      conflict =
          ' ON CONFLICT (${_table.primaryKey.map(_quote).join(', ')}) DO UPDATE SET ${mutable.map((name) => '${_quote(name)} = EXCLUDED.${_quote(name)}').join(', ')}';
    }
    return (await _run(
      'INSERT INTO $_name $clause$conflict RETURNING $_columns',
      params,
    )).single;
  }

  Future<Map<String, Object?>?> findById(Map<String, Object?> key) async {
    final params = <Object?>[];
    final where = _key(key, params);
    final rows = await _run(
      'SELECT $_columns FROM $_name WHERE $where',
      params,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<Map<String, Object?>>> findMany({
    Filter? where,
    List<Order> orderBy = const [],
    int? limit,
    int? offset,
  }) {
    for (final value in [limit, offset]) {
      if (value != null && (value < 0 || value > 9007199254740991)) {
        throw ArgumentError('Invalid pagination.');
      }
    }
    final params = <Object?>[];
    var sql = 'SELECT $_columns FROM $_name';
    if (where != null) sql += ' WHERE ${where._sql(_table.name, params)}';
    if (orderBy.isNotEmpty) {
      sql +=
          ' ORDER BY ${orderBy.map((order) => order._sql(_table.name)).join(', ')}';
    }
    if (limit != null) {
      params.add(limit);
      sql += ' LIMIT \$${params.length}';
    }
    if (offset != null) {
      params.add(offset);
      sql += ' OFFSET \$${params.length}';
    }
    return _run(sql, params);
  }

  Map<String, Object?> _patch(Map<String, Object?> patch) {
    final values = _values(patch);
    if (values.keys.any(_table.primaryKey.contains)) {
      throw ArgumentError('Primary key cannot be updated.');
    }
    return values;
  }

  Future<Map<String, Object?>> update(
    Map<String, Object?> key,
    Map<String, Object?> patch,
  ) async {
    final values = _patch(patch);
    final row = values.isEmpty
        ? await findById(key)
        : await _update(key, values);
    if (row == null) throw const DatabaseError('not_found');
    return row;
  }

  Future<Map<String, Object?>?> updateIf(
    Map<String, Object?> key,
    Filter condition,
    Map<String, Object?> patch,
  ) {
    final values = _patch(patch);
    if (values.isEmpty) throw ArgumentError('No columns to update.');
    return _update(key, values, condition: condition);
  }

  Future<Map<String, Object?>> increment(
    Map<String, Object?> key,
    Map<String, int> columns,
  ) async {
    final row = await _update(key, const {}, increments: columns);
    if (row == null) throw const DatabaseError('not_found');
    return row;
  }

  Future<Map<String, Object?>?> incrementIf(
    Map<String, Object?> key,
    Filter condition,
    Map<String, int> columns,
    Map<String, Object?> patch,
  ) {
    final values = _patch(patch);
    if (values.isEmpty) throw ArgumentError('No columns to update.');
    return _update(key, values, condition: condition, increments: columns);
  }

  Future<Map<String, Object?>?> _update(
    Map<String, Object?> key,
    Map<String, Object?> values, {
    Filter? condition,
    Map<String, int>? increments,
  }) async {
    final params = <Object?>[];
    final assignments = <String>[];
    if (increments != null) {
      if (increments.isEmpty) throw ArgumentError('No columns to increment.');
      for (final entry in increments.entries) {
        if (_table.column(entry.key).kind != 'integer' ||
            _table.primaryKey.contains(entry.key) ||
            values.containsKey(entry.key) ||
            entry.value == 0 ||
            entry.value < -9007199254740991 ||
            entry.value > 9007199254740991) {
          throw ArgumentError('Invalid increment.');
        }
        params.add(entry.value);
        final name = _quote(entry.key);
        assignments.add('$name = $name + \$${params.length}');
      }
    }
    for (final entry in values.entries) {
      params.add(entry.value);
      assignments.add('${_quote(entry.key)} = \$${params.length}');
    }
    var where = _key(key, params);
    if (condition != null) {
      where += ' AND (${condition._sql(_table.name, params)})';
    }
    final rows = await _run(
      'UPDATE $_name SET ${assignments.join(', ')} WHERE $where RETURNING $_columns',
      params,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<Map<String, Object?>?> delete(Map<String, Object?> key) async {
    final params = <Object?>[];
    final where = _key(key, params);
    final rows = await _run(
      'DELETE FROM $_name WHERE $where RETURNING $_columns',
      params,
    );
    return rows.isEmpty ? null : rows.single;
  }
}
