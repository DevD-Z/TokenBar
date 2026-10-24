/// One quota window (e.g. Codex 5-hour session, Claude weekly).
class RateWindow {
  const RateWindow({
    required this.id,
    required this.label,
    required this.usedPercent,
    this.resetsAt,
    this.windowMinutes,
  });

  /// Stable ids: `session`, `weekly`, `weekly_opus`, `weekly_sonnet`, or
  /// provider-specific ids such as `codex-spark`.
  final String id;
  final String label;

  /// 0-100.
  final double usedPercent;
  final DateTime? resetsAt;
  final int? windowMinutes;

  static const sessionId = 'session';
  static const weeklyId = 'weekly';

  double get usedClamped => usedPercent.clamp(0, 100).toDouble();
  double get remainingPercent => 100 - usedClamped;

  Duration? timeUntilReset(DateTime now) {
    final reset = resetsAt;
    if (reset == null) return null;
    final diff = reset.difference(now);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// Fraction of the window that has elapsed (0-1), when the window length
  /// and reset time are known.
  double? elapsedFraction(DateTime now) {
    final reset = resetsAt;
    final minutes = windowMinutes;
    if (reset == null || minutes == null || minutes <= 0) return null;
    final total = Duration(minutes: minutes).inSeconds;
    final left = reset.difference(now).inSeconds.clamp(0, total);
    return (total - left) / total;
  }

  /// Positive when consuming faster than a linear pace would allow.
  /// Example: 60% used after 40% of the window elapsed => +20.
  double? paceDelta(DateTime now) {
    final elapsed = elapsedFraction(now);
    if (elapsed == null) return null;
    return usedClamped - elapsed * 100;
  }

  /// Projected usage at reset time if the current average pace continues.
  double? projectedUsedAtReset(DateTime now) {
    final elapsed = elapsedFraction(now);
    if (elapsed == null || elapsed < 0.05) return null;
    return usedClamped / elapsed;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'usedPercent': usedPercent,
    if (resetsAt != null) 'resetsAt': resetsAt!.toUtc().toIso8601String(),
    if (windowMinutes != null) 'windowMinutes': windowMinutes,
  };

  factory RateWindow.fromJson(Map<String, Object?> json) => RateWindow(
    id: json['id'] as String,
    label: json['label'] as String? ?? json['id'] as String,
    usedPercent: (json['usedPercent'] as num).toDouble(),
    resetsAt: json['resetsAt'] == null ? null : DateTime.tryParse(json['resetsAt'] as String),
    windowMinutes: (json['windowMinutes'] as num?)?.toInt(),
  );
}
