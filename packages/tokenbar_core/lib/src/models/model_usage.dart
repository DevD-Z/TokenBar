/// Usage of one model inside one time bucket.
class ModelUsage {
  const ModelUsage({required this.model, this.tokens = 0, this.costUsd, this.requests = 0});

  /// Model name exactly as the source reports it (for example `gpt-5-codex`).
  final String model;

  /// Total tokens (input + output + cache, as the source counts them).
  final double tokens;

  /// Cost in US dollars when the source reports or can compute it, otherwise null.
  final double? costUsd;

  /// Number of requests / events.
  final int requests;
}

/// All models used inside one time bucket `[start, start + series.bucket)`.
class ModelUsageBucket {
  const ModelUsageBucket({required this.start, required this.usage});

  final DateTime start;
  final List<ModelUsage> usage;
}

/// Per-model usage over time for one account, ready for a stacked bar chart.
///
/// This is aggregated data only (names and numbers). It never contains prompts,
/// file paths or credentials.
class ModelUsageSeries {
  const ModelUsageSeries({
    required this.from,
    required this.to,
    required this.bucket,
    required this.buckets,
    this.source,
  });

  final DateTime from;
  final DateTime to;

  /// Width of every bucket (for example 1 hour for a 24 h range, 1 day for 7 / 30 days).
  final Duration bucket;

  /// Chronological, one entry per bucket (empty buckets may be omitted).
  final List<ModelUsageBucket> buckets;

  /// Where the data came from, for display: `cursor-events`, `codex-logs`, ...
  final String? source;

  bool get isEmpty => buckets.every((b) => b.usage.isEmpty);

  /// Every model that appears, ordered by total tokens (largest first).
  List<String> get models {
    final totals = <String, double>{};
    for (final b in buckets) {
      for (final u in b.usage) {
        totals[u.model] = (totals[u.model] ?? 0) + u.tokens;
      }
    }
    return totals.keys.toList()..sort((a, b) => totals[b]!.compareTo(totals[a]!));
  }
}
