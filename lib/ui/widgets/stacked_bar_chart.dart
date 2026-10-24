import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show ValueListenable, clampDouble;
import 'package:flutter/material.dart';

import '../chart_math.dart';

/// Key of the hover card (lets tests find it).
const chartTooltipKey = ValueKey<String>('chart-tooltip');

/// One line of the hover card: color dot, series name, value.
class ChartTooltipRow {
  const ChartTooltipRow({required this.color, required this.label, required this.value});

  final Color color;
  final String label;
  final String value;
}

/// Content of the hover card of one bar.
class ChartTooltip {
  const ChartTooltip({
    required this.title,
    required this.totalLabel,
    required this.total,
    required this.rows,
  });

  final String title;
  final String totalLabel;
  final String total;
  final List<ChartTooltipRow> rows;
}

/// A stacked bar chart drawn with a [CustomPainter].
///
/// The x axis always spans every bucket of [starts] (empty buckets show a
/// faint stub). Segments are stacked bottom to top in the order of [colors]
/// with a small gap between them; only the topmost segment of a bar has rounded
/// corners. Hovering (mouse) or tapping (touch) a bar highlights it and shows
/// a card next to it that stays inside the chart.
class StackedBarChart extends StatefulWidget {
  const StackedBarChart({
    super.key,
    required this.starts,
    required this.bucket,
    required this.values,
    required this.colors,
    required this.axisLabel,
    required this.xLabel,
    required this.tooltipFor,
    this.animationKey,
    this.height = 220,
  });

  /// Start of each bucket, chronological.
  final List<DateTime> starts;
  final Duration bucket;

  /// `values[bucket][series]`, series ordered from the bottom of the stack up.
  final List<List<double>> values;

  /// One color per series.
  final List<Color> colors;

  /// Text of a y-axis tick.
  final String Function(double value) axisLabel;

  /// Text of the x-axis label of bucket `index`.
  final String Function(int index) xLabel;

  /// Hover card content for bucket `index` (only called for non-empty buckets).
  final ChartTooltip Function(int index) tooltipFor;

  /// Bars grow in again whenever this changes (view, range, filter...).
  final Object? animationKey;
  final double height;

  @override
  State<StackedBarChart> createState() => _StackedBarChartState();
}

class _StackedBarChartState extends State<StackedBarChart> with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  final ValueNotifier<int?> _active = ValueNotifier(null);
  late List<double> _totals;
  late ({double max, double step}) _scale;
  late List<double> _ticks;

  @override
  void initState() {
    super.initState();
    _recompute();
    _grow.forward();
  }

  @override
  void didUpdateWidget(StackedBarChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.values, widget.values)) _recompute();
    if (old.animationKey != widget.animationKey) _grow.forward(from: 0);
  }

  @override
  void dispose() {
    _grow.dispose();
    _active.dispose();
    super.dispose();
  }

  void _recompute() {
    _totals = [for (final row in widget.values) row.fold<double>(0, (a, b) => a + b)];
    final maxTotal = _totals.fold<double>(0, math.max);
    _scale = niceScale(maxTotal);
    _ticks = scaleTicks(_scale);
  }

  int? _hit(_Geometry geo, double dx) {
    final i = geo.indexAt(dx);
    return i != null && i < _totals.length && _totals[i] > 0 ? i : null;
  }

  Size _measure(BuildContext context, Iterable<String> texts, TextStyle style) {
    var w = 0.0;
    var h = 0.0;
    for (final t in texts) {
      final p = TextPainter(
        text: TextSpan(text: t, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      w = math.max(w, p.width);
      h = math.max(h, p.height);
      p.dispose();
    }
    return Size(w, h);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final labelStyle = (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final count = widget.starts.length;
    final tickTexts = [for (final t in _ticks) widget.axisLabel(t)];
    final xTexts = [for (var i = 0; i < count; i++) widget.xLabel(i)];
    final axisW = _measure(context, tickTexts, labelStyle).width + 8;
    final xLabelW = _measure(context, xTexts, labelStyle).width;
    final labelH = _measure(context, const ['0'], labelStyle).height;

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);
          final geo = _Geometry(size, axisW, count, labelH);
          final xLabels = pickAxisLabels(
            starts: widget.starts,
            bucket: widget.bucket,
            slot: geo.slot,
            labelWidth: xLabelW,
          );
          final boxW = xLabelW + 4;
          return MouseRegion(
            onHover: (e) => _active.value = _hit(geo, e.localPosition.dx),
            onExit: (_) => _active.value = null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                // A mouse hover already shows the card; taps pin it for touch only.
                if (d.kind == PointerDeviceKind.mouse) return;
                final i = _hit(geo, d.localPosition.dx);
                _active.value = i == _active.value ? null : i;
              },
              onHorizontalDragUpdate: (d) => _active.value = _hit(geo, d.localPosition.dx),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _BarsPainter(
                          geo: geo,
                          values: widget.values,
                          colors: widget.colors,
                          maxY: _scale.max,
                          ticks: _ticks,
                          gridColor: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.10),
                          baselineColor: scheme.onSurface.withValues(alpha: dark ? 0.22 : 0.16),
                          highlightColor: scheme.onSurface.withValues(alpha: dark ? 0.09 : 0.06),
                          stubColor: scheme.onSurface.withValues(alpha: dark ? 0.12 : 0.08),
                          active: _active,
                          progress: _grow,
                        ),
                      ),
                    ),
                  ),
                  for (var k = 0; k < _ticks.length; k++)
                    Positioned(
                      left: 0,
                      width: axisW - 6,
                      top: geo.yOf(_ticks[k], _scale.max) - labelH / 2,
                      child: Text(
                        tickTexts[k],
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                        style: labelStyle,
                      ),
                    ),
                  for (final i in xLabels)
                    Positioned(
                      left: (geo.centerX(i) - boxW / 2).clamp(
                        0.0,
                        math.max(0.0, size.width - boxW),
                      ),
                      width: boxW,
                      top: geo.plot.bottom + 6,
                      child: Text(
                        xTexts[i],
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: labelStyle,
                      ),
                    ),
                  Positioned.fill(
                    child: ValueListenableBuilder<int?>(
                      valueListenable: _active,
                      builder: (context, i, _) {
                        if (i == null || i >= _totals.length || _totals[i] <= 0) {
                          return const SizedBox.shrink();
                        }
                        return IgnorePointer(
                          child: CustomSingleChildLayout(
                            delegate: _TooltipLayout(
                              barLeft: geo.centerX(i) - geo.barWidth / 2,
                              barRight: geo.centerX(i) + geo.barWidth / 2,
                              top: geo.plot.top,
                            ),
                            child: _TooltipCard(data: widget.tooltipFor(i)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Plot rectangle and per-bucket slot math shared by painter, labels and hit testing.
class _Geometry {
  _Geometry(this.size, double axisWidth, this.count, double labelHeight)
    : plot = Rect.fromLTRB(
        axisWidth + 4,
        10,
        math.max(axisWidth + 5, size.width - 6),
        math.max(11, size.height - labelHeight - 12),
      ) {
    slot = plot.width / math.max(1, count);
    barWidth = math.min(slot, (slot * 0.62).clamp(2.0, 28.0));
  }

  final Size size;
  final Rect plot;
  final int count;
  late final double slot;
  late final double barWidth;

  double centerX(int i) => plot.left + slot * (i + 0.5);

  double yOf(double value, double maxY) => plot.bottom - value / maxY * plot.height;

  int? indexAt(double dx) {
    if (dx < plot.left || dx >= plot.right || count == 0) return null;
    return ((dx - plot.left) / slot).floor().clamp(0, count - 1);
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.geo,
    required this.values,
    required this.colors,
    required this.maxY,
    required this.ticks,
    required this.gridColor,
    required this.baselineColor,
    required this.highlightColor,
    required this.stubColor,
    required this.active,
    required this.progress,
  }) : super(repaint: Listenable.merge([active, progress]));

  final _Geometry geo;
  final List<List<double>> values;
  final List<Color> colors;
  final double maxY;
  final List<double> ticks;
  final Color gridColor;
  final Color baselineColor;
  final Color highlightColor;
  final Color stubColor;
  final ValueListenable<int?> active;
  final Animation<double> progress;

  static const _gap = 1.8;
  static const _maxRadius = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geo.plot;

    // Light dashed grid.
    final grid = Path();
    for (final tick in ticks) {
      if (tick <= 0) continue;
      final y = geo.yOf(tick, maxY);
      for (var x = plot.left; x < plot.right; x += 7) {
        grid
          ..moveTo(x, y)
          ..lineTo(math.min(x + 3, plot.right), y);
      }
    }
    canvas.drawPath(
      grid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = gridColor,
    );
    canvas.drawLine(
      plot.bottomLeft,
      plot.bottomRight,
      Paint()
        ..strokeWidth = 1
        ..color = baselineColor,
    );

    final act = active.value;
    final t = progress.value;
    final n = geo.count;
    final barW = geo.barWidth;
    for (var i = 0; i < n && i < values.length; i++) {
      final cx = geo.centerX(i);
      final left = cx - barW / 2;
      if (act == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - geo.slot / 2 + 1, plot.top, cx + geo.slot / 2 - 1, plot.bottom),
            const Radius.circular(8),
          ),
          Paint()..color = highlightColor,
        );
      }
      final row = values[i];
      var first = -1;
      var last = -1;
      for (var j = 0; j < row.length; j++) {
        if (row[j] > 0) {
          if (first < 0) first = j;
          last = j;
        }
      }
      if (first < 0) {
        // Empty bucket: a faint stub keeps the full range visible.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, plot.bottom - 2, barW, 2),
            const Radius.circular(1),
          ),
          Paint()..color = stubColor,
        );
        continue;
      }
      // Staggered grow-in: later bars start a little after earlier ones.
      final local = ((t - 0.3 * i / n) / 0.7).clamp(0.0, 1.0);
      final grow = Curves.easeOutCubic.transform(local);
      final alpha = act != null && act != i ? 0.45 : 1.0;
      final radius = (barW * 0.25).clamp(2.0, _maxRadius);
      var y = plot.bottom;
      for (var j = 0; j < row.length; j++) {
        final v = row[j];
        if (v <= 0) continue;
        final h = v / maxY * plot.height * grow;
        if (h <= 0) continue;
        final top = y - h;
        // Gap below every segment but the first (skip it for hairline segments).
        final bottom = (j != first && h > _gap + 1) ? y - _gap : y;
        y = top;
        final rect = Rect.fromLTRB(left, top, left + barW, math.max(top, bottom));
        final base = colors[j % colors.length];
        final shaded = Color.lerp(base, Colors.white, 0.16)!;
        final paint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              shaded.withValues(alpha: alpha),
              base.withValues(alpha: alpha),
            ],
          ).createShader(rect);
        final r = j == last ? math.min(radius, rect.height) : 0.0;
        canvas.drawRRect(
          RRect.fromRectAndCorners(rect, topLeft: Radius.circular(r), topRight: Radius.circular(r)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}

/// Places the card beside the bar (right by default, left near the right
/// edge), never over the bar and always inside the chart.
class _TooltipLayout extends SingleChildLayoutDelegate {
  const _TooltipLayout({required this.barLeft, required this.barRight, required this.top});

  final double barLeft;
  final double barRight;
  final double top;

  static const _gap = 10.0;
  static const _ideal = 220.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = math.max(constraints.maxWidth - barRight - _gap, barLeft - _gap);
    final width = math.min(constraints.maxWidth, math.min(_ideal, math.max(room, 120.0)));
    return BoxConstraints(maxWidth: width, maxHeight: constraints.maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final spaceRight = size.width - barRight - _gap;
    final spaceLeft = barLeft - _gap;
    final onRight =
        spaceRight >= childSize.width || (spaceLeft < childSize.width && spaceRight >= spaceLeft);
    var dx = onRight ? barRight + _gap : barLeft - _gap - childSize.width;
    dx = clampDouble(dx, 0, math.max(0.0, size.width - childSize.width));
    final dy = clampDouble(top, 0, math.max(0.0, size.height - childSize.height));
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_TooltipLayout old) =>
      old.barLeft != barLeft || old.barRight != barRight || old.top != top;
}

class _TooltipCard extends StatelessWidget {
  const _TooltipCard({required this.data}) : super(key: chartTooltipKey);

  final ChartTooltip data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final text = theme.textTheme;
    const figures = [FontFeature.tabularFigures()];
    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3A3C) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.4 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              data.title,
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    data.totalLabel,
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  data.total,
                  style: text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: figures,
                  ),
                ),
              ],
            ),
            if (data.rows.isNotEmpty) ...[
              const SizedBox(height: 6),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 6),
            ],
            for (final r in data.rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: r.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        r.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      r.value,
                      style: text.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: figures,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
