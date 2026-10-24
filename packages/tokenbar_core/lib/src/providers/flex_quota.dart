import '../util/json_utils.dart';
import 'http_support.dart';

/// Key-name-tolerant quota extraction for providers whose payloads vary
/// (Synthetic, Chutes). Keys are compared lowercased with non-alphanumerics
/// removed, so `reset_at`, `resetAt` and `ResetAt` all match `resetat`.
class FlexKeys {
  const FlexKeys({
    required this.limit,
    required this.used,
    required this.remaining,
    required this.percentUsed,
    required this.percentRemaining,
    required this.reset,
    this.label = const ['label', 'name', 'title', 'type', 'period', 'window'],
  });

  final List<String> limit;
  final List<String> used;
  final List<String> remaining;
  final List<String> percentUsed;
  final List<String> percentRemaining;
  final List<String> reset;
  final List<String> label;
}

class FlexQuota {
  FlexQuota({
    required this.usedPercent,
    this.label,
    this.resetsAt,
    this.windowMinutes,
    this.used,
    this.limit,
  });

  final double usedPercent;
  final String? label;
  final DateTime? resetsAt;
  final int? windowMinutes;
  final double? used;
  final double? limit;
}

String _norm(String key) => key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

Object? flexValue(Map<String, Object?> map, List<String> keys) {
  for (final k in keys) {
    for (final e in map.entries) {
      if (_norm(e.key) == k) return e.value;
    }
  }
  return null;
}

/// Accepts numbers and strings like "$36.00", "1,000" or "42%".
double? flexNumber(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) return double.tryParse(v.trim().replaceAll(RegExp(r'[,$%]'), ''));
  return null;
}

/// Window length from `windowMinutes`/`windowHours`/... or text like "5h".
int? flexMinutes(Map<String, Object?> m) {
  for (final (keys, mult) in [
    (['windowminutes', 'periodminutes', 'durationminutes'], 1.0),
    (['windowhours', 'periodhours', 'durationhours'], 60.0),
    (['windowdays', 'perioddays', 'durationdays'], 1440.0),
    (['windowseconds', 'periodseconds', 'durationseconds'], 1 / 60),
  ]) {
    final n = flexNumber(flexValue(m, keys));
    if (n != null && n > 0) return (n * mult).round();
  }
  final text = asString(flexValue(m, ['window', 'windowlabel', 'period', 'interval', 'duration']))
      ?.toLowerCase()
      .replaceAll(' ', '');
  final match = RegExp(r'^(\d+(?:\.\d+)?)(.+)$').firstMatch(text ?? '');
  if (match == null) return null;
  final unit = match[2]!;
  final mult = RegExp(r'^(min|m$)').hasMatch(unit)
      ? 1
      : RegExp(r'^(hour|hr|h$)').hasMatch(unit)
      ? 60
      : RegExp(r'^(day|d$)').hasMatch(unit)
      ? 1440
      : RegExp(r'^(month|mo$)').hasMatch(unit)
      ? 43200
      : null;
  return mult == null ? null : (double.parse(match[1]!) * mult).round();
}

FlexQuota? parseFlexQuota(Map<String, Object?> m, FlexKeys keys, {bool ratioPercent = true}) {
  final limit = flexNumber(flexValue(m, keys.limit));
  final used = flexNumber(flexValue(m, keys.used));
  final remaining = flexNumber(flexValue(m, keys.remaining));
  final pUsed = flexNumber(flexValue(m, keys.percentUsed));
  final pRemaining = flexNumber(flexValue(m, keys.percentRemaining));
  double normalize(double v) =>
      (ratioPercent && v.abs() < 1 ? v * 100 : v).clamp(0, 100).toDouble();
  final total = limit ?? (used != null && remaining != null ? used + remaining : null);
  final consumed = used ?? (total != null && remaining != null ? total - remaining : null);
  final double? percent = pUsed != null
      ? normalize(pUsed)
      : pRemaining != null
      ? 100 - normalize(pRemaining)
      : (total != null && total > 0 && consumed != null)
      ? consumed / total * 100
      : null;
  if (percent == null) return null;
  return FlexQuota(
    usedPercent: percent.clamp(0, 100).toDouble(),
    label: asString(flexValue(m, keys.label)),
    resetsAt: parseFlexibleDate(flexValue(m, keys.reset)),
    windowMinutes: flexMinutes(m),
    used: consumed,
    limit: total,
  );
}

/// Every quota-like object reachable from [root], depth-first, deduplicated.
List<FlexQuota> collectFlexQuotas(Object? root, FlexKeys keys) {
  final out = <FlexQuota>[];
  final seen = <Object>{};
  void visit(Object? v) {
    if (v is List) {
      v.forEach(visit);
    } else if (v is Map) {
      if (!seen.add(v)) return;
      final m = v.cast<String, Object?>();
      final q = parseFlexQuota(m, keys);
      if (q != null) out.add(q);
      m.values.forEach(visit);
    }
  }

  visit(root);
  return out;
}
