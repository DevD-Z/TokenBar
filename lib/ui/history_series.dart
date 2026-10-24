import 'package:tokenbar_core/tokenbar_core.dart';

/// What the stacked chart measures.
enum HistoryMetric {
  /// Newly consumed quota, in percentage points of each window.
  usage,

  /// Newly spent money / credits.
  cost,
}

/// Per-bucket increments for a set of series, ready for a stacked bar chart.
class StackedHistory {
  const StackedHistory({
    required this.ids,
    required this.bucketStarts,
    required this.buckets,
    required this.totals,
  });

  /// Series ids, in a stable order (largest total first).
  final List<String> ids;
  final List<DateTime> bucketStarts;

  /// `buckets[i][id]` = increment of series `id` inside bucket `i`.
  final List<Map<String, double>> buckets;

  /// Sum of increments per series over the whole range.
  final Map<String, double> totals;

  double get grandTotal => totals.values.fold(0, (a, b) => a + b);
  bool get isEmpty => grandTotal <= 0;

  double bucketTotal(int i) => buckets[i].values.fold(0, (a, b) => a + b);

  /// Share of [id] in the whole range, 0-100.
  double share(String id) => grandTotal <= 0 ? 0 : (totals[id] ?? 0) / grandTotal * 100;
}

/// Bucket width for a chart range: roughly 24-30 bars.
Duration bucketFor(Duration range) {
  if (range <= const Duration(hours: 24)) return const Duration(hours: 1);
  if (range <= const Duration(days: 7)) return const Duration(hours: 6);
  return const Duration(days: 1);
}

/// Index of the bucket containing [t] (the last start that is <= [t]),
/// or -1 when [t] is before the first bucket.
int bucketIndexFor(List<DateTime> starts, DateTime t) {
  var lo = 0;
  var hi = starts.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (starts[mid].isAfter(t)) {
      hi = mid - 1;
    } else {
      found = mid;
      lo = mid + 1;
    }
  }
  return found;
}

/// Windows that are aggregates of other windows (session, weekly, monthly
/// totals). Stacking them together with their own components double counts.
bool isAggregateWindow(String id) =>
    id == RateWindow.sessionId || id == RateWindow.weeklyId || id.endsWith('-total');

/// Default series selection: the component windows (e.g. Cursor Auto / API,
/// Claude Opus / Sonnet) when there are at least two, otherwise everything.
Set<String> defaultUsageSeries(Iterable<String> windowIds) {
  final all = windowIds.toSet();
  final components = all.where((id) => !isAggregateWindow(id)).toSet();
  return components.length >= 2 ? components : all;
}

/// Turns cumulative samples into per-bucket increments.
///
/// A sample lower than the previous one means the window reset, so the new
/// value itself is the usage since the reset. The first sample has no baseline
/// and contributes nothing.
StackedHistory buildStackedHistory({
  required List<UsagePoint> points,
  required Map<String, double> Function(UsagePoint) read,
  required Set<String> include,
  required DateTime start,
  required DateTime end,
  required Duration bucket,
  List<DateTime>? alignedStarts,
}) {
  final sorted = [...points]..sort((a, b) => a.at.compareTo(b.at));
  // With [alignedStarts] (see `alignedBucketStarts`) the buckets sit on clock
  // boundaries; otherwise they are fixed-width slices from [start].
  final count =
      alignedStarts?.length ??
      (end.difference(start).inMilliseconds / bucket.inMilliseconds).ceil().clamp(1, 400);
  final starts = alignedStarts ?? [for (var i = 0; i < count; i++) start.add(bucket * i)];
  final buckets = List.generate(count, (_) => <String, double>{});
  final totals = <String, double>{};
  final previous = <String, double>{};

  for (final p in sorted) {
    final values = read(p);
    for (final entry in values.entries) {
      if (!include.contains(entry.key)) continue;
      final prev = previous[entry.key];
      previous[entry.key] = entry.value;
      if (prev == null) continue;
      var delta = entry.value - prev;
      if (delta < 0) delta = entry.value;
      if (delta <= 0.0001) continue;
      final at = p.at.toLocal();
      if (at.isBefore(start) || at.isAfter(end)) continue;
      final i = alignedStarts != null
          ? bucketIndexFor(starts, at)
          : (at.difference(start).inMilliseconds / bucket.inMilliseconds).floor().clamp(
              0,
              count - 1,
            );
      if (i < 0) continue;
      buckets[i][entry.key] = (buckets[i][entry.key] ?? 0) + delta;
      totals[entry.key] = (totals[entry.key] ?? 0) + delta;
    }
  }

  final ids = totals.keys.toList()..sort((a, b) => totals[b]!.compareTo(totals[a]!));
  return StackedHistory(ids: ids, bucketStarts: starts, buckets: buckets, totals: totals);
}
