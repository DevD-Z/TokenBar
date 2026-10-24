import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../state/settings.dart';
import '../ui/format.dart';

/// Publishes a compact summary to the Android / iOS home screen widget.
///
/// Keys (read by `TokenBarWidgetProvider.kt` and `TokenBarWidget.swift`):
/// `tb_count`, `tb_updated`, and per row `i` (0-3): `tb_{i}_name`,
/// `tb_{i}_session`, `tb_{i}_weekly` (remaining %, -1 if unknown),
/// `tb_{i}_detail`.
class HomeWidgetBridge {
  static const appGroupId = 'group.dev.tokenbar.app';
  static const androidName = 'TokenBarWidgetProvider';
  static const iOSName = 'TokenBarWidget';
  static const maxRows = 4;

  bool _ready = false;

  Future<void> init() async {
    if (!isMobilePlatform) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      _ready = true;
    } catch (e) {
      debugPrint('home widget unavailable: $e');
    }
  }

  Future<void> publish(List<UsageSnapshot> snapshots) async {
    if (!_ready) return;
    final now = DateTime.now();
    final rows = snapshots.where((s) => s.windows.isNotEmpty).take(maxRows).toList();
    try {
      await HomeWidget.saveWidgetData<int>('tb_count', rows.length);
      await HomeWidget.saveWidgetData<String>(
        'tb_updated',
        '${two(now.hour)}:${two(now.minute)} 更新',
      );
      for (var i = 0; i < maxRows; i++) {
        final s = i < rows.length ? rows[i] : null;
        final session = s?.session ?? s?.tightestWindow;
        final weekly = s?.weekly;
        final reset = session?.timeUntilReset(now);
        await HomeWidget.saveWidgetData<String>(
          'tb_${i}_name',
          s?.accountLabel ?? s?.providerId ?? '',
        );
        await HomeWidget.saveWidgetData<int>(
          'tb_${i}_session',
          session?.remainingPercent.round() ?? -1,
        );
        await HomeWidget.saveWidgetData<int>(
          'tb_${i}_weekly',
          weekly?.remainingPercent.round() ?? -1,
        );
        await HomeWidget.saveWidgetData<String>(
          'tb_${i}_detail',
          s == null ? '' : (reset == null ? planLabel(s.plan) : '${countdownZh(reset)}后重置'),
        );
      }
      await HomeWidget.updateWidget(androidName: androidName, iOSName: iOSName);
    } catch (e) {
      debugPrint('home widget update failed: $e');
    }
  }
}
