import 'package:flutter/material.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../../app/theme.dart';
import '../format.dart';
import 'usage_bar.dart';

/// One quota window: label, remaining %, bar with pace marker, reset info.
class WindowRow extends StatelessWidget {
  const WindowRow({super.key, required this.window, required this.now, this.dense = false});

  final RateWindow window;
  final DateTime now;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final reset = window.timeUntilReset(now);
    final elapsed = window.elapsedFraction(now);
    final pace = window.paceDelta(now);
    final remaining = window.remainingPercent;

    final details = <String>['已用 ${formatPercent(window.usedClamped)}'];
    if (reset != null) {
      details.add('${countdownZh(reset)}后重置 · ${resetTimeZh(window.resetsAt!, now)}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                windowLabel(window),
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              formatPercent(remaining),
              style: (dense ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)?.copyWith(
                fontWeight: FontWeight.w700,
                color: quotaColor(remaining, theme.brightness),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Text('剩余', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
        ),
        const SizedBox(height: 4),
        UsageBar(remaining: remaining, paceRemaining: elapsed == null ? null : 100 - elapsed * 100),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                details.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (pace != null && pace.abs() >= 5)
              Text(
                pace > 0 ? '快于节奏 ${pace.round()}%' : '低于节奏 ${(-pace).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: pace > 0 ? quotaColor(15, theme.brightness) : muted,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
