final class SessionPolicy {
  SessionPolicy(this.idleTimeoutSeconds, this.absoluteLifetimeSeconds) {
    if (idleTimeoutSeconds < 3600 || idleTimeoutSeconds > 31536000) {
      throw ArgumentError.value(idleTimeoutSeconds, 'idleTimeoutSeconds');
    }
    if (absoluteLifetimeSeconds != 0 &&
        (absoluteLifetimeSeconds < 3600 ||
            absoluteLifetimeSeconds > 31536000)) {
      throw ArgumentError.value(
        absoluteLifetimeSeconds,
        'absoluteLifetimeSeconds',
      );
    }
  }

  final int idleTimeoutSeconds;
  final int absoluteLifetimeSeconds;

  (DateTime, DateTime) expirations(DateTime issued, DateTime firstLogin) {
    final idle = issued.add(Duration(seconds: idleTimeoutSeconds));
    final family = absoluteLifetimeSeconds == 0
        ? idle
        : _earlier(
            idle,
            firstLogin.add(Duration(seconds: absoluteLifetimeSeconds)),
          );
    return (_earlier(issued.add(const Duration(minutes: 15)), family), family);
  }

  DateTime? familyExpiry(
    DateTime checked,
    DateTime firstLogin,
    DateTime renewed,
    DateTime stored,
  ) {
    final (_, computed) = expirations(renewed, firstLogin);
    final deadline = _earlier(stored, computed);
    return deadline.isAfter(checked) ? deadline : null;
  }
}

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
