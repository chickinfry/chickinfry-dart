part of 'auth.dart';

extension on Authentication {
  Future<void> _cleanup(DateTime now, String issuedSessionId) async {
    final cutoff = Authentication._timestamp(now);
    final idle = Authentication._timestamp(
      now.subtract(Duration(seconds: _policy.idleTimeoutSeconds)),
    );
    final legacy = Authentication._timestamp(
      now.subtract(const Duration(days: 7)),
    );
    final absolute = Authentication._timestamp(
      now.subtract(Duration(seconds: _policy.absoluteLifetimeSeconds)),
    );
    const columns = AppAuthSessionsColumns();
    // A concurrent replay can revoke the family this request just issued.
    final ended = Filter.and([
      columns.id.ne(issuedSessionId),
      Filter.or([
        columns.revokedAt.isNotNull(),
        columns.lastRenewedAt.lte(idle),
        Filter.and([
          columns.lastRenewedAt.isNull(),
          Filter.or([
            columns.expiresAt.lte(idle),
            columns.createdAt.lte(legacy),
          ]),
        ]),
        if (_policy.absoluteLifetimeSeconds != 0)
          Filter.or([
            columns.firstLoginAt.lte(absolute),
            Filter.and([
              columns.firstLoginAt.isNull(),
              columns.createdAt.lte(absolute),
            ]),
          ]),
      ]),
    ]);
    final bytes = randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = hexBytes(bytes);
    final start =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    const limit = 32;
    final sessions = _db.appAuthSessions;
    final candidates = (await sessions.findMany(
      where: (c) => Filter.and([ended, c.id.gte(start)]),
      orderBy: (c) => [c.id.asc()],
      limit: limit,
    )).toList();
    if (candidates.length < limit) {
      candidates.addAll(
        await sessions.findMany(
          where: (c) => Filter.and([ended, c.id.lt(start)]),
          orderBy: (c) => [c.id.asc()],
          limit: limit - candidates.length,
        ),
      );
    }
    var remaining = limit;
    for (final candidate in candidates) {
      await _db.transaction((db) async {
        final sessions = db.appAuthSessions;
        final key = AppAuthSessionsPrimaryKey(id: candidate.id);
        final locked = await sessions.updateIf(
          key,
          (c) => Filter.and([c.expiresAt.eq(candidate.expiresAt), ended]),
          AppAuthSessionsUpdate(expiresAt: Value(candidate.expiresAt)),
        );
        if (locked == null) return;
        if (locked.revokedAt == null &&
            _familyExpiry(
                  now,
                  locked,
                  await Authentication._latest(db, locked.id),
                ) !=
                null) {
          return;
        }

        final refresh = db.appAuthRefreshTokens;
        if (remaining > 0) {
          final children = await refresh.findMany(
            where: (c) => c.sessionId.eq(locked.id),
            orderBy: (c) => [c.expiresAt.asc(), c.id.asc()],
            limit: remaining,
          );
          for (final child in children) {
            final key = AppAuthRefreshTokensPrimaryKey(id: child.id);
            final row = await refresh.updateIf(
              key,
              (c) => Filter.and([
                c.sessionId.eq(locked.id),
                c.expiresAt.eq(child.expiresAt),
              ]),
              AppAuthRefreshTokensUpdate(expiresAt: Value(child.expiresAt)),
            );
            if (row == null) continue;
            remaining--;
            await refresh.delete(key);
          }
        }
        final references = await refresh.findMany(
          where: (c) => c.sessionId.eq(locked.id),
          limit: 1,
        );
        if (references.isEmpty) await sessions.delete(key);
      });
    }
    final rates = _db.appAuthRateLimits;
    final expired = await rates.findMany(
      where: (c) => c.expiresAt.lte(cutoff),
      orderBy: (c) => [c.expiresAt.asc(), c.action.asc(), c.keyHash.asc()],
      limit: limit,
    );
    for (final candidate in expired) {
      await _db.transaction((db) async {
        final rates = db.appAuthRateLimits;
        final key = AppAuthRateLimitsPrimaryKey(
          action: candidate.action,
          keyHash: candidate.keyHash,
        );
        final locked = await rates.updateIf(
          key,
          (c) => Filter.and([
            c.expiresAt.lte(cutoff),
            c.attemptCount.eq(candidate.attemptCount),
          ]),
          AppAuthRateLimitsUpdate(expiresAt: Value(candidate.expiresAt)),
        );
        if (locked != null) await rates.delete(key);
      });
    }
  }
}
