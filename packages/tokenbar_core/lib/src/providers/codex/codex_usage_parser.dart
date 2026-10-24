import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../util/json_utils.dart';

class CodexParsedUsage {
  const CodexParsedUsage({
    required this.windows,
    required this.credits,
    this.plan,
    this.accountId,
    this.email,
  });

  final List<RateWindow> windows;
  final List<Credits> credits;
  final String? plan;
  final String? accountId;
  final String? email;
}

class _RawWindow {
  _RawWindow(this.usedPercent, this.resetsAt, this.windowMinutes);

  final double usedPercent;
  final DateTime? resetsAt;
  final int? windowMinutes;
}

/// Parses `GET /backend-api/wham/usage`.
CodexParsedUsage parseWhamUsage(Map<String, Object?> json) {
  final rateLimit = asMap(json['rate_limit']);
  final windows = <RateWindow>[
    ..._mainWindows(
      _whamWindow(asMap(rateLimit?['primary_window'])),
      _whamWindow(asMap(rateLimit?['secondary_window'])),
    ),
  ];

  for (final entry in asList(json['additional_rate_limits']) ?? const []) {
    final map = asMap(entry);
    if (map == null) continue;
    final name = asString(map['limit_name']) ?? asString(map['metered_feature']) ?? 'extra';
    final rl = asMap(map['rate_limit']);
    windows.addAll(
      _namedWindows(
        name,
        _whamWindow(asMap(rl?['primary_window'])),
        _whamWindow(asMap(rl?['secondary_window'])),
      ),
    );
  }

  final credits = <Credits>[];
  final c = _creditsFrom(asMap(json['credits']));
  if (c != null) credits.add(c);
  final limit = _spendLimit(
    asMap(pick(json, ['individual_limit', 'individualLimit'])) ??
        asMap(pick(rateLimit ?? const {}, ['individual_limit', 'individualLimit'])) ??
        asMap(
          pick(asMap(pick(json, ['spend_control', 'spendControl'])) ?? const {}, [
            'individual_limit',
            'individualLimit',
          ]),
        ),
  );
  if (limit != null) credits.add(limit);

  return CodexParsedUsage(
    windows: windows,
    credits: credits,
    plan: asString(json['plan_type']),
    accountId: asString(pick(json, ['account_id', 'accountId'])),
  );
}

/// Parses `account/rateLimits/read` from `codex app-server`.
CodexParsedUsage parseRpcRateLimits(Map<String, Object?> result, {Map<String, Object?>? account}) {
  final snapshot = asMap(result['rateLimits']) ?? const {};
  final windows = <RateWindow>[
    ..._mainWindows(
      _rpcWindow(asMap(snapshot['primary'])),
      _rpcWindow(asMap(snapshot['secondary'])),
    ),
  ];

  final byId = asMap(pick(result, ['rateLimitsByLimitId', 'rate_limits_by_limit_id']));
  if (byId != null) {
    final mainId = asString(pick(snapshot, ['limitId', 'limit_id']));
    for (final entry in byId.entries) {
      if (entry.key == mainId || entry.key == 'codex') continue;
      final s = asMap(entry.value);
      if (s == null) continue;
      final name = asString(pick(s, ['limitName', 'limit_name'])) ?? entry.key;
      windows.addAll(
        _namedWindows(name, _rpcWindow(asMap(s['primary'])), _rpcWindow(asMap(s['secondary']))),
      );
    }
  }

  final credits = <Credits>[];
  final c = _creditsFrom(asMap(snapshot['credits']));
  if (c != null) credits.add(c);

  final acct = asMap(account?['account']);
  return CodexParsedUsage(
    windows: windows,
    credits: credits,
    plan: asString(pick(snapshot, ['planType', 'plan_type'])) ?? asString(acct?['planType']),
    email: asString(acct?['email']),
  );
}

_RawWindow? _whamWindow(Map<String, Object?>? map) {
  if (map == null) return null;
  final used = asDouble(map['used_percent']);
  if (used == null) return null;
  final seconds = asInt(map['limit_window_seconds']);
  return _RawWindow(
    used,
    epochSeconds(asInt(map['reset_at'])),
    seconds == null ? null : (seconds / 60).round(),
  );
}

_RawWindow? _rpcWindow(Map<String, Object?>? map) {
  if (map == null) return null;
  final used = asDouble(map['usedPercent']);
  if (used == null) return null;
  return _RawWindow(used, epochSeconds(asInt(map['resetsAt'])), asInt(map['windowDurationMins']));
}

enum _Role { session, weekly, unknown }

_Role _role(_RawWindow w) => switch (w.windowMinutes) {
  300 => _Role.session,
  10080 => _Role.weekly,
  _ => _Role.unknown,
};

/// Mirrors CodexBar's CodexRateWindowNormalizer: order by window length so
/// a weekly-only response does not show up as the 5-hour lane.
List<RateWindow> _mainWindows(_RawWindow? primary, _RawWindow? secondary) {
  _RawWindow? session;
  _RawWindow? weekly;
  if (primary != null && secondary != null) {
    final swap = _role(primary) == _Role.weekly && _role(secondary) != _Role.weekly;
    session = swap ? secondary : primary;
    weekly = swap ? primary : secondary;
  } else {
    final only = primary ?? secondary;
    if (only != null) {
      if (_role(only) == _Role.weekly) {
        weekly = only;
      } else {
        session = only;
      }
    }
  }
  return [
    if (session != null) _toWindow(RateWindow.sessionId, _label(session, '5-hour'), session),
    if (weekly != null) _toWindow(RateWindow.weeklyId, _label(weekly, 'Weekly'), weekly),
  ];
}

List<RateWindow> _namedWindows(String name, _RawWindow? primary, _RawWindow? secondary) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final main = _mainWindows(primary, secondary);
  return [
    for (final w in main)
      RateWindow(
        id: w.id == RateWindow.sessionId ? slug : '$slug-weekly',
        label: '$name ${w.id == RateWindow.sessionId ? w.label : 'Weekly'}',
        usedPercent: w.usedPercent,
        resetsAt: w.resetsAt,
        windowMinutes: w.windowMinutes,
      ),
  ];
}

String _label(_RawWindow w, String fallback) {
  final minutes = w.windowMinutes;
  if (minutes == null || minutes == 300 || minutes == 10080) return fallback;
  if (minutes % 1440 == 0) return '${minutes ~/ 1440}-day';
  if (minutes % 60 == 0) return '${minutes ~/ 60}-hour';
  return '$minutes-min';
}

RateWindow _toWindow(String id, String label, _RawWindow w) => RateWindow(
  id: id,
  label: label,
  usedPercent: w.usedPercent,
  resetsAt: w.resetsAt,
  windowMinutes: w.windowMinutes,
);

Credits? _creditsFrom(Map<String, Object?>? map) {
  if (map == null) return null;
  final hasCredits = asBool(pick(map, ['has_credits', 'hasCredits'])) ?? false;
  final unlimited = asBool(map['unlimited']) ?? false;
  final balance = asDouble(map['balance']);
  if (!hasCredits && !unlimited && (balance == null || balance == 0)) {
    return null;
  }
  return Credits(id: 'codex-credits', label: 'Credits', balance: balance, unlimited: unlimited);
}

Credits? _spendLimit(Map<String, Object?>? map) {
  if (map == null) return null;
  final limit = asDouble(map['limit']);
  final used = asDouble(map['used']);
  final remainingPercent = asDouble(pick(map, ['remainingPercent', 'remaining_percent']));
  if (limit == null && used == null && remainingPercent == null) return null;
  final resolvedUsed =
      used ??
      (limit != null && remainingPercent != null ? limit * (100 - remainingPercent) / 100 : null);
  return Credits(
    id: 'codex-spend-limit',
    label: 'Monthly credit limit',
    used: resolvedUsed,
    limit: limit,
    resetsAt: epochSeconds(asInt(pick(map, ['resetsAt', 'resets_at', 'reset_at']))),
  );
}
