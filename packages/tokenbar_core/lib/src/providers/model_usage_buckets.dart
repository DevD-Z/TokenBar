import '../models/model_usage.dart';

/// Ranges up to this length use 1-hour buckets, longer ones use 1-day buckets.
const modelUsageHourlyMaxRange = Duration(hours: 36);

/// Bucket width for a per-model usage range `[from, to]`: 1 hour when the range is at
/// most 36 hours long (for example 24 h), otherwise 1 day (7 / 30 days).
Duration modelUsageBucketWidth(DateTime from, DateTime to) =>
    to.difference(from) <= modelUsageHourlyMaxRange
    ? const Duration(hours: 1)
    : const Duration(days: 1);

/// Start of the bucket containing [time], aligned to the local time zone: the local hour
/// start for hourly buckets, local midnight for daily ones.
DateTime modelUsageBucketStart(DateTime time, Duration bucket) {
  final local = time.toLocal();
  return bucket >= const Duration(days: 1)
      ? DateTime(local.year, local.month, local.day)
      : DateTime(local.year, local.month, local.day, local.hour);
}

/// Collects `(time, model, numbers)` samples into a [ModelUsageSeries].
///
/// Only names and numbers go in; callers must never pass prompts, paths or credentials.
class ModelUsageAggregator {
  ModelUsageAggregator({required this.from, required this.to})
    : bucket = modelUsageBucketWidth(from, to);

  final DateTime from;
  final DateTime to;
  final Duration bucket;

  final Map<DateTime, Map<String, _Cell>> _cells = {};

  /// Adds one sample. Samples outside `[from, to]` are ignored. [costUsd] null means "cost
  /// unknown": the bucket/model cost then stays null instead of showing a partial sum.
  void add(
    DateTime time,
    String model, {
    required double tokens,
    double? costUsd,
    int requests = 1,
  }) {
    if (time.isBefore(from) || time.isAfter(to)) return;
    final start = modelUsageBucketStart(time, bucket);
    final cell = _cells.putIfAbsent(start, () => {}).putIfAbsent(model, _Cell.new);
    cell.tokens += tokens;
    cell.requests += requests;
    if (costUsd == null) {
      cell.costKnown = false;
    } else {
      cell.costUsd += costUsd;
    }
  }

  /// Chronological series; empty buckets are omitted and models inside a bucket are
  /// ordered by tokens (largest first).
  ModelUsageSeries build({String? source}) {
    final starts = _cells.keys.toList()..sort();
    return ModelUsageSeries(
      from: from,
      to: to,
      bucket: bucket,
      source: source,
      buckets: [
        for (final start in starts)
          ModelUsageBucket(
            start: start,
            usage: [
              for (final entry in _sortedModels(_cells[start]!))
                ModelUsage(
                  model: entry.key,
                  tokens: entry.value.tokens,
                  costUsd: entry.value.costKnown ? entry.value.costUsd : null,
                  requests: entry.value.requests,
                ),
            ],
          ),
      ],
    );
  }

  static List<MapEntry<String, _Cell>> _sortedModels(Map<String, _Cell> cells) =>
      cells.entries.toList()..sort((a, b) {
        final byTokens = b.value.tokens.compareTo(a.value.tokens);
        return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
      });
}

class _Cell {
  double tokens = 0;
  double costUsd = 0;
  bool costKnown = true;
  int requests = 0;
}
