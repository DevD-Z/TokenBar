import 'usage_snapshot.dart';

/// Compact history sample: used% per window id and cumulative spend per
/// credits id at a point in time.
class UsagePoint {
  const UsagePoint({
    required this.accountId,
    required this.at,
    required this.used,
    this.spend = const {},
  });

  final String accountId;
  final DateTime at;
  final Map<String, double> used;

  /// Cumulative `Credits.used` per credits id (money or provider credits).
  final Map<String, double> spend;

  static UsagePoint? fromSnapshot(UsageSnapshot s) {
    if (s.hasError || !s.hasData) return null;
    return UsagePoint(
      accountId: s.accountId,
      at: s.fetchedAt,
      used: {for (final w in s.windows) w.id: w.usedPercent},
      spend: {
        for (final c in s.credits)
          if (c.used != null) c.id: c.used!,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'a': accountId,
    't': at.toUtc().toIso8601String(),
    'u': used,
    if (spend.isNotEmpty) 'c': spend,
  };

  factory UsagePoint.fromJson(Map<String, Object?> json) => UsagePoint(
    accountId: json['a'] as String,
    at: DateTime.parse(json['t'] as String),
    used: (json['u'] as Map).map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
    spend: ((json['c'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
    ),
  );
}

/// Keeps at most one point per [bucket] per account (latest wins) – used to
/// downsample older history.
List<UsagePoint> downsample(List<UsagePoint> points, Duration bucket) {
  final byKey = <String, UsagePoint>{};
  for (final p in points) {
    final slot = p.at.millisecondsSinceEpoch ~/ bucket.inMilliseconds;
    byKey['${p.accountId}|$slot'] = p;
  }
  final result = byKey.values.toList()..sort((a, b) => a.at.compareTo(b.at));
  return result;
}
