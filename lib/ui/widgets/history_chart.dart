import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../../app/theme.dart';
import '../../l10n/app_localizations.dart';
import '../format.dart';
import '../history_series.dart';

/// Stacked usage history. Each bar is one time bucket; the segments are the
/// increments of each series (quota window / model, or spend line) inside it.
/// Below the chart, a legend shows every series' share and amount.
class HistoryChart extends StatefulWidget {
  const HistoryChart({
    super.key,
    required this.points,
    required this.windowLabels,
    required this.credits,
    required this.range,
  });

  final List<UsagePoint> points;

  /// Window id → display label.
  final Map<String, String> windowLabels;

  /// Credits id → credits (for labels and currency).
  final Map<String, Credits> credits;
  final Duration range;

  @override
  State<HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<HistoryChart> {
  HistoryMetric? _metric;
  Set<String>? _usageSelection;
  Set<String>? _costSelection;

  List<String> get _usageIds =>
      <String>{for (final p in widget.points) ...p.used.keys}.toList()..sort();
  List<String> get _costIds =>
      <String>{for (final p in widget.points) ...p.spend.keys}.toList()..sort();

  HistoryMetric get _effectiveMetric {
    final m = _metric ?? (_usageIds.isNotEmpty ? HistoryMetric.usage : HistoryMetric.cost);
    if (m == HistoryMetric.usage && _usageIds.isEmpty) return HistoryMetric.cost;
    if (m == HistoryMetric.cost && _costIds.isEmpty) return HistoryMetric.usage;
    return m;
  }

  Set<String> _defaultCost(List<String> ids) {
    if (ids.isEmpty) return {};
    final firstCurrency = widget.credits[ids.first]?.currency;
    return {
      for (final id in ids)
        if (widget.credits[id]?.currency == firstCurrency) id,
    };
  }

  String _label(AppLocalizations l, HistoryMetric metric, String id) =>
      metric == HistoryMetric.usage
      ? (widget.windowLabels[id] ?? id)
      : (widget.credits[id] == null ? id : creditsLabel(l, widget.credits[id]!));

  String _amount(HistoryMetric metric, String id, double value) {
    if (metric == HistoryMetric.usage) return '+${formatPercent(value)}';
    final currency = widget.credits[id]?.currency;
    return currency == null ? value.toStringAsFixed(2) : formatMoney(value, currency);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (widget.points.length < 2) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Text(
            l.historyNotEnough,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }

    final metric = _effectiveMetric;
    final allIds = metric == HistoryMetric.usage ? _usageIds : _costIds;
    final selection = metric == HistoryMetric.usage
        ? (_usageSelection ??= defaultUsageSeries(allIds))
        : (_costSelection ??= _defaultCost(allIds));

    final now = DateTime.now();
    final start = now.subtract(widget.range);
    final data = buildStackedHistory(
      points: widget.points,
      read: (p) => metric == HistoryMetric.usage ? p.used : p.spend,
      include: selection,
      start: start,
      end: now,
      bucket: bucketFor(widget.range),
    );
    Color colorOf(String id) => seriesPalette[allIds.indexOf(id) % seriesPalette.length];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_usageIds.isNotEmpty && _costIds.isNotEmpty)
              SegmentedButton<HistoryMetric>(
                segments: [
                  ButtonSegment(value: HistoryMetric.usage, label: Text(l.metricUsage)),
                  ButtonSegment(value: HistoryMetric.cost, label: Text(l.metricCost)),
                ],
                selected: {metric},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (v) => setState(() => _metric = v.first),
              ),
          ],
        ),
        if (_usageIds.isNotEmpty && _costIds.isNotEmpty) const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final id in allIds)
              FilterChip(
                selected: selection.contains(id),
                showCheckmark: false,
                avatar: CircleAvatar(radius: 5, backgroundColor: colorOf(id)),
                label: Text(_label(l, metric, id)),
                visualDensity: VisualDensity.compact,
                onSelected: (on) => setState(() {
                  final next = {...selection};
                  on ? next.add(id) : next.remove(id);
                  if (metric == HistoryMetric.usage) {
                    _usageSelection = next;
                  } else {
                    _costSelection = next;
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (data.isEmpty)
          SizedBox(
            height: 180,
            child: Center(
              child: Text(
                selection.isEmpty
                    ? l.selectAtLeastOne
                    : metric == HistoryMetric.usage
                    ? l.noUsageChanges
                    : l.noCostChanges,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ),
          )
        else
          SizedBox(
            height: 220,
            child: LayoutBuilder(
              builder: (context, box) => _chart(context, data, metric, colorOf, box.maxWidth),
            ),
          ),
        if (!data.isEmpty) ...[
          const SizedBox(height: 16),
          _Breakdown(
            data: data,
            colorOf: colorOf,
            label: (id) => _label(l, metric, id),
            amount: (id, v) => _amount(metric, id, v),
          ),
          if (metric == HistoryMetric.usage)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l.usageNote, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
            ),
        ],
      ],
    );
  }

  Widget _chart(
    BuildContext context,
    StackedHistory data,
    HistoryMetric metric,
    Color Function(String) colorOf,
    double chartWidth,
  ) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final gridColor = theme.colorScheme.onSurface.withValues(alpha: 0.07);
    final count = data.bucketStarts.length;
    // Bars take ~60% of their slot (slot = plot width / bucket count).
    final barWidth = ((chartWidth - 50) / count * 0.6).clamp(5.0, 28.0);
    final maxTotal = [for (var i = 0; i < count; i++) data.bucketTotal(i)]
        .fold<double>(0, (a, b) => a > b ? a : b);
    final maxY = _niceMax(maxTotal);
    final dayLabels = widget.range.inHours > 24;
    final labelEvery = (count / 5).ceil().clamp(1, count);
    final currency = metric == HistoryMetric.cost && data.ids.isNotEmpty
        ? widget.credits[data.ids.first]?.currency
        : null;

    String axis(double v) {
      if (metric == HistoryMetric.usage) return '${v.round()}%';
      final text = v >= 100
          ? v.round().toString()
          : (v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1));
      return currency == null ? text : '${formatMoney(0, currency).replaceAll('0.00', '')}$text';
    }

    String bucketTitle(int i) {
      final t = data.bucketStarts[i];
      if (dayLabels && bucketFor(widget.range) >= const Duration(days: 1)) {
        return l.monthDay(t.month, t.day);
      }
      return '${t.month}/${t.day} ${two(t.hour)}:00';
    }

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        groupsSpace: 2,
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (_) => FlLine(color: gridColor, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: maxY / 4,
              getTitlesWidget: (v, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  axis(v),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= count || i % labelEvery != 0) return const SizedBox.shrink();
                final t = data.bucketStarts[i];
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    dayLabels ? '${t.month}/${t.day}' : '${two(t.hour)}:00',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 220,
            tooltipBorderRadius: BorderRadius.circular(10),
            tooltipPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            getTooltipColor: (_) => const Color(0xEE2C2C2E),
            getTooltipItem: (group, i, rod, _) {
              final bucket = data.buckets[i];
              final items = [
                for (final id in data.ids)
                  if ((bucket[id] ?? 0) > 0) id,
              ];
              final total = data.bucketTotal(i);
              return BarTooltipItem(
                '${bucketTitle(i)}\n',
                const TextStyle(color: Colors.white70, fontSize: 11, height: 1.5),
                textAlign: TextAlign.left,
                children: [
                  for (final id in items)
                    TextSpan(
                      text: '● ',
                      style: TextStyle(color: colorOf(id), fontSize: 11),
                      children: [
                        TextSpan(
                          text:
                              '${_label(l, metric, id)}  ${_amount(metric, id, bucket[id]!).replaceFirst('+', '')}'
                              '  ${(bucket[id]! / total * 100).round()}%\n',
                          style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.5),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < count; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: data.bucketTotal(i),
                  width: barWidth,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular((barWidth / 3).clamp(2.0, 6.0)),
                  ),
                  color: Colors.transparent,
                  rodStackItems: _stack(data, i, colorOf),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<BarChartRodStackItem> _stack(StackedHistory data, int i, Color Function(String) colorOf) {
    final items = <BarChartRodStackItem>[];
    var from = 0.0;
    for (final id in data.ids) {
      final v = data.buckets[i][id] ?? 0;
      if (v <= 0) continue;
      items.add(BarChartRodStackItem(from, from + v, colorOf(id)));
      from += v;
    }
    return items;
  }

  /// Round the axis maximum up to a tidy 1/1.5/2/2.5/3/4/5/6/8 × 10^n.
  double _niceMax(double v) {
    if (v <= 0) return 1;
    var exp = 1.0;
    while (v / exp >= 10) {
      exp *= 10;
    }
    while (v / exp < 1) {
      exp /= 10;
    }
    final n = v / exp;
    for (final step in const [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0]) {
      if (n <= step) return step * exp;
    }
    return 10 * exp;
  }
}

/// Share list: color dot, label, a proportional bar, share % and amount.
class _Breakdown extends StatelessWidget {
  const _Breakdown({
    required this.data,
    required this.colorOf,
    required this.label,
    required this.amount,
  });

  final StackedHistory data;
  final Color Function(String) colorOf;
  final String Function(String) label;
  final String Function(String, double) amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      children: [
        // One stacked proportion bar.
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: SizedBox(
            height: 10,
            child: Row(
              children: [
                for (final id in data.ids)
                  Expanded(
                    flex: (data.share(id) * 100).round().clamp(1, 10000),
                    child: Container(color: colorOf(id)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (final id in data.ids)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorOf(id),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label(id),
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    formatPercent(data.share(id)),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    amount(id, data.totals[id]!),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
