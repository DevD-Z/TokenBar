import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';
import 'package:token_bar/ui/history_series.dart';

UsagePoint _p(
  DateTime at, {
  Map<String, double> used = const {},
  Map<String, double> spend = const {},
}) => UsagePoint(accountId: 'a', at: at, used: used, spend: spend);

void main() {
  final end = DateTime(2026, 10, 24, 12);
  final start = end.subtract(const Duration(hours: 24));

  test('increments are per bucket and the first sample has no baseline', () {
    final points = [
      _p(start.add(const Duration(hours: 1, minutes: 10)), used: {'auto': 10, 'api': 5}),
      _p(start.add(const Duration(hours: 2, minutes: 10)), used: {'auto': 14, 'api': 5}),
      _p(start.add(const Duration(hours: 2, minutes: 40)), used: {'auto': 14, 'api': 9}),
    ];
    final data = buildStackedHistory(
      points: points,
      read: (p) => p.used,
      include: {'auto', 'api'},
      start: start,
      end: end,
      bucket: const Duration(hours: 1),
    );
    expect(data.bucketStarts.length, 24);
    expect(data.totals['auto'], closeTo(4, 1e-9));
    expect(data.totals['api'], closeTo(4, 1e-9));
    expect(data.buckets[2]['auto'], closeTo(4, 1e-9));
    expect(data.buckets[2]['api'], closeTo(4, 1e-9));
    expect(data.buckets[1], isEmpty);
    expect(data.share('auto'), closeTo(50, 1e-9));
  });

  test('a drop means the window reset: the new value counts as usage', () {
    final points = [
      _p(start.add(const Duration(hours: 1)), used: {'w': 80}),
      _p(start.add(const Duration(hours: 3)), used: {'w': 6}),
    ];
    final data = buildStackedHistory(
      points: points,
      read: (p) => p.used,
      include: {'w'},
      start: start,
      end: end,
      bucket: const Duration(hours: 1),
    );
    expect(data.totals['w'], closeTo(6, 1e-9));
  });

  test('series outside the include set are ignored', () {
    final points = [
      _p(start.add(const Duration(hours: 1)), used: {'a': 1, 'b': 1}),
      _p(start.add(const Duration(hours: 2)), used: {'a': 3, 'b': 9}),
    ];
    final data = buildStackedHistory(
      points: points,
      read: (p) => p.used,
      include: {'a'},
      start: start,
      end: end,
      bucket: const Duration(hours: 1),
    );
    expect(data.ids, ['a']);
  });

  test('cost mode reads spend and sorts the largest series first', () {
    final points = [
      _p(start.add(const Duration(hours: 1)), spend: {'x': 1.0, 'y': 1.0}),
      _p(start.add(const Duration(hours: 2)), spend: {'x': 1.5, 'y': 4.0}),
    ];
    final data = buildStackedHistory(
      points: points,
      read: (p) => p.spend,
      include: {'x', 'y'},
      start: start,
      end: end,
      bucket: const Duration(hours: 1),
    );
    expect(data.ids, ['y', 'x']);
    expect(data.grandTotal, closeTo(3.5, 1e-9));
  });

  test('default selection prefers component windows over aggregates', () {
    expect(defaultUsageSeries(['cursor-total', 'cursor-auto', 'cursor-api']), {
      'cursor-auto',
      'cursor-api',
    });
    expect(defaultUsageSeries([RateWindow.sessionId, RateWindow.weeklyId]), {
      RateWindow.sessionId,
      RateWindow.weeklyId,
    });
    expect(defaultUsageSeries([RateWindow.sessionId, RateWindow.weeklyId, 'weekly_opus']), {
      RateWindow.sessionId,
      RateWindow.weeklyId,
      'weekly_opus',
    });
  });

  test('bucket width keeps roughly 24-30 bars', () {
    expect(bucketFor(const Duration(hours: 24)), const Duration(hours: 1));
    expect(bucketFor(const Duration(days: 7)), const Duration(hours: 6));
    expect(bucketFor(const Duration(days: 30)), const Duration(days: 1));
  });

  test('UsagePoint keeps spend through JSON and tolerates old records', () {
    final p = _p(DateTime.utc(2026, 10, 1), used: {'w': 1}, spend: {'c': 2.5});
    final back = UsagePoint.fromJson(p.toJson());
    expect(back.spend, {'c': 2.5});
    final old = UsagePoint.fromJson({
      'a': 'a',
      't': '2026-10-01T00:00:00Z',
      'u': {'w': 1},
    });
    expect(old.spend, isEmpty);
  });
}
