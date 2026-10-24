import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../util/json_utils.dart';

class CursorUsage {
  const CursorUsage({required this.windows, required this.credits, this.plan});

  final List<RateWindow> windows;
  final List<Credits> credits;
  final String? plan;
}

/// Parses `GET https://cursor.com/api/usage-summary`.
///
/// Mirrors CodexBar's projection: percent fields are already in percent
/// units (0.36 means 0.36%); money fields are cents. The headline percent
/// falls back plan.totalPercentUsed -> auto/api average -> plan used/limit
/// -> individualUsage.overall (enterprise member cap) -> teamUsage.pooled.
CursorUsage parseCursorUsageSummary(Map<String, Object?> json) {
  final start = DateTime.tryParse(asString(json['billingCycleStart']) ?? '');
  final end = DateTime.tryParse(asString(json['billingCycleEnd']) ?? '');
  final cycleMinutes = (start != null && end != null && end.isAfter(start))
      ? end.difference(start).inMinutes
      : null;

  final individual = asMap(json['individualUsage']);
  final plan = asMap(individual?['plan']);
  final overall = asMap(individual?['overall']);
  final onDemand = asMap(individual?['onDemand']);
  final team = asMap(json['teamUsage']);
  final pooled = asMap(team?['pooled']);
  final teamOnDemand = asMap(team?['onDemand']);

  double? pct(Object? v) => asDouble(v)?.clamp(0, 100).toDouble();
  double? ratio(Map<String, Object?>? m) {
    final used = asDouble(m?['used']);
    final limit = asDouble(m?['limit']);
    if (used == null || limit == null || limit <= 0) return null;
    return (used / limit * 100).clamp(0, 100).toDouble();
  }

  final auto = pct(plan?['autoPercentUsed']);
  final api = pct(plan?['apiPercentUsed']);
  final total =
      pct(plan?['totalPercentUsed']) ??
      (auto != null && api != null ? (auto + api) / 2 : null) ??
      api ??
      auto ??
      ratio(plan) ??
      ratio(overall) ??
      ratio(pooled);

  final unlimited = asBool(json['isUnlimited']) ?? false;
  final windows = <RateWindow>[
    if (total != null)
      RateWindow(
        id: 'cursor-total',
        label: 'Monthly',
        usedPercent: total,
        resetsAt: end,
        windowMinutes: cycleMinutes,
      ),
    if (auto != null)
      RateWindow(
        id: 'cursor-auto',
        label: 'Auto',
        usedPercent: auto,
        resetsAt: end,
        windowMinutes: cycleMinutes,
      ),
    if (api != null)
      RateWindow(
        id: 'cursor-api',
        label: 'API',
        usedPercent: api,
        resetsAt: end,
        windowMinutes: cycleMinutes,
      ),
  ];

  Credits? money(String id, String label, Map<String, Object?>? m, {bool requireActivity = false}) {
    if (m == null) return null;
    final used = asDouble(m['used']);
    final limit = asDouble(m['limit']);
    final enabled = asBool(m['enabled']) ?? true;
    if (used == null && limit == null) return null;
    if (requireActivity && !enabled && (used ?? 0) == 0) return null;
    return Credits(
      id: id,
      label: label,
      used: (used ?? 0) / 100,
      limit: limit == null ? null : limit / 100,
      currency: 'USD',
      resetsAt: end,
    );
  }

  final spendSource = (asDouble(plan?['limit']) ?? 0) > 0 || (asDouble(plan?['used']) ?? 0) > 0
      ? plan
      : (overall ?? pooled);
  final credits = <Credits>[
    ?money('cursor-plan', 'Plan usage', spendSource),
    ?money('cursor-on-demand', 'On-demand', onDemand, requireActivity: true),
    ?money('cursor-team-on-demand', 'Team on-demand', teamOnDemand, requireActivity: true),
    if (unlimited && windows.isEmpty)
      const Credits(id: 'cursor-plan', label: 'Plan usage', unlimited: true),
  ];

  return CursorUsage(windows: windows, credits: credits, plan: asString(json['membershipType']));
}

/// `sub` looks like `auth0|user_01ABC`; the cookie wants the last segment.
String? cursorUserIdFromJwt(Map<String, Object?>? claims) {
  final sub = asString(claims?['sub']);
  if (sub == null) return null;
  final id = sub.split('|').where((s) => s.isNotEmpty).lastOrNull;
  return (id == null || id.isEmpty) ? null : id;
}
