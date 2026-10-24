import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/ui/chart_math.dart';
import 'package:token_bar/ui/history_series.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

ModelUsageBucket _bucket(DateTime start, Map<String, double> tokens, {Map<String, double>? cost}) =>
    ModelUsageBucket(
      start: start,
      usage: [
        for (final e in tokens.entries)
          ModelUsage(model: e.key, tokens: e.value, costUsd: cost?[e.key]),
      ],
    );

void main() {
  // 2026-10-24 17:30 local, a Saturday.
  final now = DateTime(2026, 10, 24, 17, 30);

  group('abbreviateNumber', () {
    test('small numbers stay as they are', () {
      expect(abbreviateNumber(0), '0');
      expect(abbreviateNumber(7), '7');
      expect(abbreviateNumber(7.5), '7.5');
      expect(abbreviateNumber(950), '950');
    });

    test('K / M / B suffixes with at most one decimal', () {
      expect(abbreviateNumber(1000), '1K');
      expect(abbreviateNumber(1200), '1.2K');
      expect(abbreviateNumber(123456), '123K');
      expect(abbreviateNumber(1234567), '1.2M');
      expect(abbreviateNumber(12345678), '12.3M');
      expect(abbreviateNumber(2.5e9), '2.5B');
      expect(abbreviateNumber(3e12), '3T');
    });

    test('rounding up never prints 1000K', () {
      expect(abbreviateNumber(999960), '1M');
      expect(abbreviateNumber(999999999), '1B');
    });

    test('negative and non-finite values', () {
      expect(abbreviateNumber(-1500), '-1.5K');
      expect(abbreviateNumber(double.nan), '0');
      expect(abbreviateNumber(double.infinity), '0');
    });

    test('money axis ticks', () {
      expect(formatAxisMoney(0, 'USD'), r'$0');
      expect(formatAxisMoney(2.5, 'USD'), r'$2.5');
      expect(formatAxisMoney(10, 'USD'), r'$10');
      expect(formatAxisMoney(1500, 'USD'), r'$1.5K');
      expect(formatAxisMoney(5, null), '5');
    });
  });

  group('niceScale', () {
    test('rounds the maximum up to a tidy number of steps', () {
      final a = niceScale(87);
      expect(a.max, closeTo(100, 1e-9));
      expect(a.step, closeTo(25, 1e-9));
      final b = niceScale(1200);
      expect(b.max, closeTo(1500, 1e-9));
      expect(b.step, closeTo(500, 1e-9));
      final c = niceScale(0.37);
      expect(c.max, closeTo(0.4, 1e-9));
      expect(c.step, closeTo(0.1, 1e-9));
    });

    test('exact multiples are not padded', () {
      final s = niceScale(100);
      expect(s.max, closeTo(100, 1e-9));
      expect(s.step, closeTo(25, 1e-9));
    });

    test('empty data still gets a usable axis', () {
      final s = niceScale(0);
      expect(s.max, 1);
      expect(s.step, greaterThan(0));
    });

    test('ticks run from zero to the maximum', () {
      final ticks = scaleTicks(niceScale(87));
      expect(ticks.length, 5);
      expect(ticks.first, 0);
      expect(ticks.last, closeTo(100, 1e-9));
    });
  });

  group('alignedBucketStarts', () {
    test('24 hours: hourly buckets, newest contains now, oldest covers the range', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(hours: 24),
        bucket: const Duration(hours: 1),
      );
      expect(starts.last, DateTime(2026, 10, 24, 17));
      expect(starts.first, DateTime(2026, 10, 23, 17));
      expect(starts.length, 25);
      expect(starts.every((s) => s.minute == 0), isTrue);
    });

    test('7 days: buckets sit on 0 / 6 / 12 / 18 o\'clock', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(days: 7),
        bucket: const Duration(hours: 6),
      );
      expect(starts.last, DateTime(2026, 10, 24, 12));
      expect(starts.first.isAfter(now.subtract(const Duration(days: 7, hours: 6))), isTrue);
      expect(starts.first.isAfter(now.subtract(const Duration(days: 7))), isFalse);
      expect(starts.every((s) => s.hour % 6 == 0), isTrue);
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i].isAfter(starts[i - 1]), isTrue);
      }
    });

    test('30 days: local midnights', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(days: 30),
        bucket: const Duration(days: 1),
      );
      expect(starts.last, DateTime(2026, 10, 24));
      expect(starts.first, DateTime(2026, 9, 24));
      expect(starts.length, 31);
    });

    test('minCount pads very coarse buckets', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(hours: 24),
        bucket: const Duration(days: 1),
        minCount: 2,
      );
      expect(starts.length, 2);
      expect(starts.last, DateTime(2026, 10, 24));
      expect(starts.first, DateTime(2026, 10, 23));
    });
  });

  test('bucketIndexFor finds the containing bucket', () {
    final starts = [for (var i = 0; i < 4; i++) DateTime(2026, 10, 24, i * 6)];
    expect(bucketIndexFor(starts, DateTime(2026, 10, 23, 23)), -1);
    expect(bucketIndexFor(starts, DateTime(2026, 10, 24, 0)), 0);
    expect(bucketIndexFor(starts, DateTime(2026, 10, 24, 5, 59)), 0);
    expect(bucketIndexFor(starts, DateTime(2026, 10, 24, 6)), 1);
    expect(bucketIndexFor(starts, DateTime(2026, 10, 24, 20)), 3);
  });

  group('buildModelHistory', () {
    final starts = alignedBucketStarts(
      now: now,
      range: const Duration(days: 7),
      bucket: const Duration(hours: 6),
    );
    const bucket = Duration(hours: 6);
    final series = ModelUsageSeries(
      from: now.subtract(const Duration(days: 7)),
      to: now,
      bucket: const Duration(hours: 1),
      buckets: [
        // Two hourly buckets fall into the same 6 h display bucket (12:00-18:00).
        _bucket(DateTime(2026, 10, 24, 12), {'a': 100, 'b': 40}, cost: {'a': 1.0}),
        _bucket(DateTime(2026, 10, 24, 14), {'a': 50, '': 10}, cost: {'a': 0.5}),
        _bucket(DateTime(2026, 10, 20, 1), {'b': 500}),
        // Outside the grid: ignored.
        _bucket(DateTime(2026, 9, 1), {'zzz': 999}),
        _bucket(DateTime(2026, 10, 25, 1), {'zzz': 999}),
      ],
    );

    test('tokens: complete grid, aggregated per display bucket, largest first', () {
      final h = buildModelHistory(series: series, starts: starts, bucket: bucket, cost: false);
      expect(h.bucketStarts.length, starts.length);
      expect(h.buckets.length, starts.length);
      expect(h.ids, ['b', 'a', unknownModelId]);
      expect(h.totals['a'], 150);
      expect(h.totals['b'], 540);
      expect(h.totals[unknownModelId], 10);
      expect(h.buckets.last['a'], 150);
      expect(h.buckets.where((b) => b.isNotEmpty).length, 2);
      expect(h.totals.containsKey('zzz'), isFalse);
    });

    test('cost ignores models without a cost', () {
      final h = buildModelHistory(series: series, starts: starts, bucket: bucket, cost: true);
      expect(h.ids, ['a']);
      expect(h.totals['a'], closeTo(1.5, 1e-9));
    });

    test('an empty series gives an empty but complete grid', () {
      final h = buildModelHistory(
        series: ModelUsageSeries(from: now, to: now, bucket: bucket, buckets: const []),
        starts: starts,
        bucket: bucket,
        cost: false,
      );
      expect(h.isEmpty, isTrue);
      expect(h.buckets.length, starts.length);
    });
  });

  group('mergeTailSeries', () {
    StackedHistory twelve() {
      final starts = [DateTime(2026, 10, 24), DateTime(2026, 10, 25)];
      final totals = {for (var i = 0; i < 12; i++) 'm$i': 120.0 - i * 10};
      return StackedHistory(
        ids: totals.keys.toList(),
        bucketStarts: starts,
        buckets: [
          {for (var i = 0; i < 12; i++) 'm$i': 60.0 - i * 5},
          {for (var i = 0; i < 12; i++) 'm$i': 60.0 - i * 5},
        ],
        totals: totals,
      );
    }

    test('folds everything beyond the palette into one trailing "other"', () {
      final h = twelve();
      final merged = mergeTailSeries(h, maxSeries: 10);
      expect(merged.ids.length, 10);
      expect(merged.ids.last, otherSeriesId);
      expect(merged.ids.take(9), h.ids.take(9));
      // m9 + m10 + m11 = 30 + 20 + 10 per... totals are 30, 20, 10 -> 60 overall.
      expect(merged.totals[otherSeriesId], closeTo(30 + 20 + 10, 1e-9));
      expect(merged.grandTotal, closeTo(h.grandTotal, 1e-9));
      expect(merged.buckets.first[otherSeriesId], closeTo(15 + 10 + 5, 1e-9));
      expect(merged.buckets.first.containsKey('m9'), isFalse);
    });

    test('leaves short lists alone', () {
      final h = twelve();
      expect(identical(mergeTailSeries(h, maxSeries: 12), h), isTrue);
      expect(identical(mergeTailSeries(h, maxSeries: 20), h), isTrue);
    });
  });

  group('filterSeries / toggleHidden', () {
    final h = StackedHistory(
      ids: const ['a', 'b', 'c'],
      bucketStarts: [DateTime(2026, 10, 24)],
      buckets: const [
        {'a': 3.0, 'b': 2.0, 'c': 1.0},
      ],
      totals: const {'a': 3.0, 'b': 2.0, 'c': 1.0},
    );

    test('hidden series disappear and the axis total shrinks', () {
      final f = filterSeries(h, {'a'});
      expect(f.ids, ['b', 'c']);
      expect(f.buckets.first.containsKey('a'), isFalse);
      expect(f.grandTotal, 3);
      expect(f.bucketTotal(0), 3);
      expect(f.share('b'), closeTo(66.666, 0.01));
    });

    test('nothing hidden returns the same object', () {
      expect(identical(filterSeries(h, {}), h), isTrue);
    });

    test('toggle flips one series', () {
      expect(toggleHidden({}, 'a', h.ids), {'a'});
      expect(toggleHidden({'a'}, 'a', h.ids), <String>{});
      expect(toggleHidden({'a'}, 'b', h.ids), {'a', 'b'});
    });

    test('hiding every series restores them all', () {
      expect(toggleHidden({'a', 'b'}, 'c', h.ids), <String>{});
    });
  });

  group('pickAxisLabels', () {
    List<DateTime> hourly() => alignedBucketStarts(
      now: now,
      range: const Duration(hours: 24),
      bucket: const Duration(hours: 1),
    );

    test('day chart: clock-aligned hours, sparser on narrow charts', () {
      final starts = hourly();
      final wide = pickAxisLabels(
        starts: starts,
        bucket: const Duration(hours: 1),
        slot: 30,
        labelWidth: 34,
      );
      expect(wide.every((i) => starts[i].hour % 2 == 0), isTrue);
      final narrow = pickAxisLabels(
        starts: starts,
        bucket: const Duration(hours: 1),
        slot: 12,
        labelWidth: 34,
      );
      expect(narrow.length, lessThan(wide.length));
      expect(narrow.every((i) => starts[i].hour % 4 == 0), isTrue);
    });

    test('labels never overlap', () {
      final starts = hourly();
      for (final slot in [8.0, 12.0, 20.0, 40.0]) {
        final picked = pickAxisLabels(
          starts: starts,
          bucket: const Duration(hours: 1),
          slot: slot,
          labelWidth: 34,
        );
        for (var k = 1; k < picked.length; k++) {
          expect((picked[k] - picked[k - 1]) * slot, greaterThanOrEqualTo(34));
        }
      }
    });

    test('week chart labels midnights only', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(days: 7),
        bucket: const Duration(hours: 6),
      );
      final picked = pickAxisLabels(
        starts: starts,
        bucket: const Duration(hours: 6),
        slot: 24,
        labelWidth: 30,
      );
      expect(picked, isNotEmpty);
      expect(picked.every((i) => starts[i].hour == 0), isTrue);
      expect(picked.length, 7);
    });

    test('month chart thins out and always includes the newest day', () {
      final starts = alignedBucketStarts(
        now: now,
        range: const Duration(days: 30),
        bucket: const Duration(days: 1),
      );
      final picked = pickAxisLabels(
        starts: starts,
        bucket: const Duration(days: 1),
        slot: 12,
        labelWidth: 32,
      );
      expect(picked.last, starts.length - 1);
      expect(picked.length, lessThan(starts.length ~/ 2));
      for (var k = 1; k < picked.length; k++) {
        expect((picked[k] - picked[k - 1]) * 12, greaterThanOrEqualTo(32));
      }
    });
  });

  test('buildStackedHistory on an aligned grid keeps every bucket', () {
    final starts = alignedBucketStarts(
      now: now,
      range: const Duration(days: 7),
      bucket: const Duration(hours: 6),
    );
    final points = [
      UsagePoint(accountId: 'a', at: DateTime(2026, 10, 24, 1), used: const {'w': 10}),
      UsagePoint(accountId: 'a', at: DateTime(2026, 10, 24, 13), used: const {'w': 25}),
    ];
    final h = buildStackedHistory(
      points: points,
      read: (p) => p.used,
      include: {'w'},
      start: starts.first,
      end: now,
      bucket: const Duration(hours: 6),
      alignedStarts: starts,
    );
    expect(h.bucketStarts, starts);
    expect(h.buckets.length, starts.length);
    expect(h.buckets.last['w'], 15);
    expect(h.totals['w'], 15);
  });
}
