import 'dart:math' as math;

import 'package:tokenbar_core/tokenbar_core.dart';

import 'history_series.dart';

/// Id of the synthetic series that collects every series beyond the palette.
const otherSeriesId = '\u0000other';

/// Name used for model rows the source reports without a model name.
const unknownModelId = 'unknown';

/// `950`, `1.2K`, `12.3M`, `4.5B`: compact number for tokens and axis labels.
String abbreviateNumber(double value) {
  if (!value.isFinite) return '0';
  const units = ['', 'K', 'M', 'B', 'T'];
  final negative = value < 0;
  var scaled = value.abs();
  var unit = 0;
  String render(double v, int unit) {
    final decimals = unit == 0 ? (v < 10 ? 2 : (v < 100 ? 1 : 0)) : (v < 100 ? 1 : 0);
    var text = v.toStringAsFixed(decimals);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return text;
  }

  while (scaled >= 1000 && unit < units.length - 1) {
    scaled /= 1000;
    unit++;
  }
  // 999.96K rounds to "1000K": promote it to 1M instead.
  if (unit < units.length - 1 && double.parse(render(scaled, unit)) >= 1000) {
    scaled /= 1000;
    unit++;
  }
  final text = render(scaled, unit);
  return '${negative && text != '0' ? '-' : ''}$text${units[unit]}';
}

/// A money amount for an axis tick: symbol, thousands abbreviated, no trailing zeros.
String formatAxisMoney(double value, String? currency) {
  final symbol = currency == null ? '' : formatMoney(0, currency).replaceAll('0.00', '');
  if (value.abs() >= 1000) return '$symbol${abbreviateNumber(value)}';
  var text = value.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$symbol$text';
}

/// "Nice" axis scale: a maximum that is a whole number of steps, where the
/// step is 1 / 2 / 2.5 / 5 × 10^n. Aims for about [targetTicks] intervals.
({double max, double step}) niceScale(double maxValue, {int targetTicks = 4}) {
  if (!maxValue.isFinite || maxValue <= 0) return (max: 1.0, step: 1.0 / targetTicks);
  final raw = maxValue / targetTicks;
  final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final normalized = raw / magnitude;
  final factor = normalized <= 1
      ? 1.0
      : normalized <= 2
      ? 2.0
      : normalized <= 2.5
      ? 2.5
      : normalized <= 5
      ? 5.0
      : 10.0;
  final step = factor * magnitude;
  final steps = (maxValue / step - 1e-9).ceil().clamp(1, 1000);
  return (max: steps * step, step: step);
}

/// Tick values `0, step, 2*step ... max` for [niceScale].
List<double> scaleTicks(({double max, double step}) scale) {
  final count = (scale.max / scale.step).round();
  return [for (var i = 0; i <= count; i++) i * scale.step];
}

/// Start times of the chart buckets, aligned to local clock boundaries
/// (whole hours / multiples of the bucket hours / local midnight) so the
/// x axis lands on tidy labels. The last bucket contains [now] and the
/// buckets cover at least [range] back from [now]; empty buckets are included.
List<DateTime> alignedBucketStarts({
  required DateTime now,
  required Duration range,
  required Duration bucket,
  int minCount = 1,
}) {
  final local = now.toLocal();
  final daily = bucket >= const Duration(days: 1);
  final bucketDays = math.max(1, bucket.inDays);
  final bucketHours = math.max(1, bucket.inHours);

  DateTime shift(DateTime t, int k) => daily
      ? DateTime(t.year, t.month, t.day + k * bucketDays)
      : DateTime(t.year, t.month, t.day, t.hour + k * bucketHours);

  final last = daily
      ? DateTime(local.year, local.month, local.day)
      : DateTime(local.year, local.month, local.day, (local.hour ~/ bucketHours) * bucketHours);
  final firstWanted = local.subtract(range);
  var count = 1;
  while (count < 400 && shift(last, -(count - 1)).isAfter(firstWanted)) {
    count++;
  }
  count = math.max(count, minCount).clamp(1, 400);
  return [for (var i = count - 1; i >= 0; i--) shift(last, -i)];
}

/// Per-model totals per bucket on the given grid. [cost] selects USD cost
/// instead of tokens. Buckets outside the grid are ignored; the grid is
/// always complete (empty buckets stay empty).
StackedHistory buildModelHistory({
  required ModelUsageSeries series,
  required List<DateTime> starts,
  required Duration bucket,
  required bool cost,
}) {
  final buckets = List.generate(starts.length, (_) => <String, double>{});
  final totals = <String, double>{};
  if (starts.isNotEmpty) {
    final end = starts.last.add(bucket);
    for (final b in series.buckets) {
      final at = b.start.toLocal();
      if (!at.isBefore(end)) continue;
      final i = bucketIndexFor(starts, at);
      if (i < 0) continue;
      for (final u in b.usage) {
        final v = cost ? (u.costUsd ?? 0) : u.tokens;
        if (!v.isFinite || v <= 0) continue;
        final name = u.model.trim().isEmpty ? unknownModelId : u.model;
        buckets[i][name] = (buckets[i][name] ?? 0) + v;
        totals[name] = (totals[name] ?? 0) + v;
      }
    }
  }
  return StackedHistory(
    ids: _sortedByTotal(totals),
    bucketStarts: starts,
    buckets: buckets,
    totals: totals,
  );
}

List<String> _sortedByTotal(Map<String, double> totals) {
  final ids = totals.keys.toList();
  ids.sort((a, b) {
    final c = totals[b]!.compareTo(totals[a]!);
    return c != 0 ? c : a.compareTo(b);
  });
  return ids;
}

/// Keeps the [maxSeries] - 1 biggest series and folds the rest into one
/// [otherId] series (always last). Returns [h] unchanged when it already fits.
StackedHistory mergeTailSeries(
  StackedHistory h, {
  required int maxSeries,
  String otherId = otherSeriesId,
}) {
  if (maxSeries < 2 || h.ids.length <= maxSeries) return h;
  final keep = h.ids.take(maxSeries - 1).toList();
  final tail = h.ids.skip(maxSeries - 1).toSet();
  final buckets = <Map<String, double>>[];
  for (final b in h.buckets) {
    final merged = <String, double>{};
    var other = 0.0;
    for (final e in b.entries) {
      if (tail.contains(e.key)) {
        other += e.value;
      } else {
        merged[e.key] = e.value;
      }
    }
    if (other > 0) merged[otherId] = other;
    buckets.add(merged);
  }
  final totals = <String, double>{for (final id in keep) id: h.totals[id]!};
  totals[otherId] = tail.fold<double>(0, (a, id) => a + h.totals[id]!);
  return StackedHistory(
    ids: [...keep, otherId],
    bucketStarts: h.bucketStarts,
    buckets: buckets,
    totals: totals,
  );
}

/// [h] without the [hidden] series (order of the rest is kept).
StackedHistory filterSeries(StackedHistory h, Set<String> hidden) {
  if (hidden.isEmpty) return h;
  return StackedHistory(
    ids: [
      for (final id in h.ids)
        if (!hidden.contains(id)) id,
    ],
    bucketStarts: h.bucketStarts,
    buckets: [
      for (final b in h.buckets)
        {
          for (final e in b.entries)
            if (!hidden.contains(e.key)) e.key: e.value,
        },
    ],
    totals: {
      for (final e in h.totals.entries)
        if (!hidden.contains(e.key)) e.key: e.value,
    },
  );
}

/// Legend toggle: flips [id]; hiding every series of [all] restores them all.
Set<String> toggleHidden(Set<String> hidden, String id, Iterable<String> all) {
  final next = {...hidden};
  if (!next.remove(id)) next.add(id);
  if (all.every(next.contains)) return {};
  return next;
}

/// Whether the x axis shows clock times (a day or less) instead of dates.
bool axisShowsTime(List<DateTime> starts, Duration bucket) =>
    bucket < const Duration(days: 1) &&
    starts.length > 1 &&
    starts.last.difference(starts.first) < const Duration(days: 2);

/// Which buckets get an x-axis label. Spacing is sparse (labels never
/// overlap) and lands on clock-aligned hours for day charts, or on
/// midnights counted back from the newest bucket for longer ranges.
List<int> pickAxisLabels({
  required List<DateTime> starts,
  required Duration bucket,
  required double slot,
  required double labelWidth,
  double minGap = 12,
}) {
  final n = starts.length;
  if (n == 0) return const [];
  final need = labelWidth + minGap;
  if (axisShowsTime(starts, bucket)) {
    final bucketHours = math.max(1, bucket.inHours);
    for (final step in const [1, 2, 3, 4, 6, 8, 12, 24]) {
      if (step % bucketHours != 0) continue;
      if (step / bucketHours * slot < need && step != 24) continue;
      return [
        for (var i = 0; i < n; i++)
          if (starts[i].hour % step == 0 && starts[i].minute == 0) i,
      ];
    }
    return const [];
  }
  final candidates = [
    for (var i = 0; i < n; i++)
      if (bucket >= const Duration(days: 1) || starts[i].hour == 0) i,
  ];
  if (candidates.isEmpty) return [n - 1];
  final spacing = candidates.length > 1 ? (candidates[1] - candidates[0]) * slot : slot * 4;
  var stride = 1;
  for (final s in const [1, 2, 3, 5, 7, 10, 14, 30]) {
    stride = s;
    if (s * spacing >= need) break;
  }
  return [for (var k = candidates.length - 1; k >= 0; k -= stride) candidates[k]].reversed.toList();
}
