import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tokenbar_core/icon.dart';
import 'package:tokenbar_core/tokenbar_core.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/format.dart';
import '../ui/tray_panel.dart';

/// System tray + window behaviour on Windows / macOS / Linux.
class DesktopIntegration with TrayListener, WindowListener {
  bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  void Function()? _onRefresh;
  bool _minimizeToTray = true;
  bool _trayReady = false;
  bool _quitting = false;
  String? _lastIconKey;
  int _iconGeneration = 0;

  /// True while the single window is acting as the small tray panel
  /// (frameless, always on top, anchored to the tray icon).
  final ValueNotifier<bool> panelMode = ValueNotifier(false);

  static const panelWidth = 392.0;

  /// Height of the panel for the current content; refreshed by [update].
  double _panelHeight = 280;
  Offset? _anchor;
  static const _mainSize = Size(1080, 760);
  static const _mainMinSize = Size(380, 520);

  Rect? _mainBounds;
  bool _panelBusy = false;
  DateTime _panelHiddenAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init({required void Function() onRefresh, required bool minimizeToTray}) async {
    if (!supported) return;
    _onRefresh = onRefresh;
    _minimizeToTray = minimizeToTray;

    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: _mainSize,
      minimumSize: _mainMinSize,
      center: true,
      title: 'TokenBar',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    try {
      trayManager.addListener(this);
      await _setIcon(null, null, false);
      await trayManager.setToolTip('TokenBar');
      await _setMenu(const []);
      _trayReady = true;
    } catch (e) {
      // Some Linux desktops have no tray; the window still works.
      debugPrint('tray unavailable: $e');
    }

    try {
      launchAtStartup.setup(
        appName: 'TokenBar',
        appPath: Platform.resolvedExecutable,
        packageName: 'dev.tokenbar.app',
      );
    } catch (e) {
      debugPrint('launch at startup unavailable: $e');
    }
  }

  Future<void> update(List<UsageSnapshot> snapshots) async {
    if (!supported || !_trayReady) return;
    final height = TrayPanel.heightFor(snapshots);
    if (height != _panelHeight) {
      _panelHeight = height;
      if (panelMode.value && !_panelBusy && _anchor != null && await windowManager.isVisible()) {
        await _layoutPanel();
      }
    }
    final withData = snapshots.where((s) => s.windows.isNotEmpty).toList();
    // Icon follows the most constrained account.
    UsageSnapshot? focus;
    for (final s in withData) {
      final t = s.tightestWindow!;
      if (focus == null || t.remainingPercent < focus.tightestWindow!.remainingPercent) focus = s;
    }
    final top = focus?.session?.remainingPercent ?? focus?.tightestWindow?.remainingPercent;
    final bottom = focus?.weekly?.remainingPercent;
    final hasError = snapshots.any((s) => s.hasError);
    await _setIcon(top, bottom, hasError);

    final now = DateTime.now();
    final lines = <String>[];
    for (final s in snapshots) {
      final name = s.accountLabel ?? s.providerId;
      if (s.windows.isEmpty) {
        lines.add('$name: ${s.error ?? '无数据'}');
        continue;
      }
      final parts = s.windows.take(2).map((w) {
        final reset = w.timeUntilReset(now);
        return '${windowLabel(w)} ${formatPercent(w.remainingPercent)}'
            '${reset == null ? '' : ' (${countdownZh(reset)})'}';
      });
      lines.add('$name: ${parts.join(' · ')}');
    }
    // Windows caps tooltips at 128 chars.
    var tooltip = ['TokenBar', ...lines].join('\n');
    if (Platform.isWindows && tooltip.length > 127) tooltip = '${tooltip.substring(0, 126)}…';
    await trayManager.setToolTip(tooltip);
    if (Platform.isMacOS && focus != null) {
      await trayManager.setTitle(formatPercent(focus.tightestWindow!.remainingPercent));
    }
    await _setMenu(lines);
  }

  Future<void> _setIcon(double? top, double? bottom, bool error) async {
    final key = '${top?.round()}|${bottom?.round()}|$error';
    if (key == _lastIconKey) return;
    _lastIconKey = key;
    final png = TrayIconRenderer.renderPng(top: top, bottom: bottom, error: error);
    final dir = await getTemporaryDirectory();
    // A fresh file name per change: some platforms cache icons by path.
    final gen = _iconGeneration++;
    final ext = Platform.isWindows ? 'ico' : 'png';
    final file = File('${dir.path}${Platform.pathSeparator}tokenbar_tray_$gen.$ext');
    await file.writeAsBytes(Platform.isWindows ? TrayIconRenderer.wrapIco(png) : png);
    await trayManager.setIcon(file.path);
    if (gen > 0) {
      final old = File('${dir.path}${Platform.pathSeparator}tokenbar_tray_${gen - 1}.$ext');
      if (await old.exists()) await old.delete().catchError((_) => old);
    }
  }

  Future<void> _setMenu(List<String> lines) => trayManager.setContextMenu(
    Menu(
      items: [
        for (final line in lines) MenuItem(label: line, disabled: true),
        if (lines.isNotEmpty) MenuItem.separator(),
        MenuItem(key: 'show', label: '打开 TokenBar'),
        MenuItem(key: 'refresh', label: '立即刷新'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ],
    ),
  );

  Future<void> setMinimizeToTray(bool value) async => _minimizeToTray = value;

  Future<void> setLaunchAtStartup(bool value) async {
    if (!supported) return;
    try {
      value ? await launchAtStartup.enable() : await launchAtStartup.disable();
    } catch (e) {
      debugPrint('launch at startup failed: $e');
    }
  }

  Future<void> showWindow() async {
    if (!supported) return;
    await showMainWindow();
  }

  /// Leaves panel mode (if needed) and brings the full window forward.
  Future<void> showMainWindow() async {
    if (!supported) return;
    _panelBusy = true;
    try {
      if (panelMode.value) {
        panelMode.value = false;
        await windowManager.hide();
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setResizable(true);
        await windowManager.setMinimumSize(_mainMinSize);
        final b = _mainBounds;
        if (b != null) {
          await windowManager.setBounds(b);
        } else {
          await windowManager.setSize(_mainSize);
          await windowManager.center();
        }
      }
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } finally {
      _panelBusy = false;
    }
  }

  /// Tray icon click: toggle the panel (or focus the main window if it is open).
  Future<void> _onTrayClick() async {
    if (_panelBusy) return;
    final visible = await windowManager.isVisible();
    if (visible && !panelMode.value) {
      await showMainWindow();
      return;
    }
    if (visible && panelMode.value) {
      await hidePanel();
      return;
    }
    // Clicking the tray icon blurs (and hides) the panel just before this
    // handler runs; ignore that click so the panel does not instantly reopen.
    if (DateTime.now().difference(_panelHiddenAt) < const Duration(milliseconds: 350)) return;
    await showPanel();
  }

  Future<void> showPanel() async {
    if (!supported || !_trayReady) return;
    _panelBusy = true;
    try {
      if (!panelMode.value) {
        _mainBounds = await windowManager.getBounds();
        panelMode.value = true;
        await windowManager.setMinimumSize(const Size(panelWidth, 120));
        await windowManager.setAsFrameless();
        await windowManager.setResizable(false);
        await windowManager.setSkipTaskbar(true);
        await windowManager.setAlwaysOnTop(true);
      }
      _anchor = await screenRetriever.getCursorScreenPoint();
      await _layoutPanel();
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('show panel failed: $e');
    } finally {
      _panelBusy = false;
    }
  }

  Future<void> hidePanel() async {
    _panelHiddenAt = DateTime.now();
    await windowManager.hide();
  }

  /// Top-left corner for the panel: centred on the cursor (which is over the
  /// tray icon), above a bottom taskbar or below a top menu bar, kept on screen.
  Future<void> _layoutPanel() async {
    final origin = await _panelOrigin(_anchor!);
    await windowManager.setBounds(origin & Size(panelWidth, _panelHeight));
  }

  Future<Offset> _panelOrigin(Offset cursor) async {
    const margin = 8.0;
    final displays = await screenRetriever.getAllDisplays();
    Rect area = Rect.fromLTWH(0, 0, 1920, 1080);
    for (final d in displays) {
      final pos = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      final r = pos & size;
      if (r.inflate(80).contains(cursor)) {
        area = r;
        break;
      }
      if (d == displays.first) area = r;
    }
    final x = (cursor.dx - panelWidth / 2).clamp(
      area.left + margin,
      area.right - panelWidth - margin,
    );
    _panelHeight = _panelHeight.clamp(120, area.height - margin * 2).toDouble();
    final height = _panelHeight;
    final below = cursor.dy < area.center.dy;
    final y = below ? area.top + margin : area.bottom - height - margin;
    return Offset(x.toDouble(), y);
  }

  Future<void> quit() => _quit();

  Future<void> _quit() async {
    _quitting = true;
    if (_trayReady) await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => _onTrayClick();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'refresh':
        _onRefresh?.call();
      case 'quit':
        _quit();
    }
  }

  @override
  void onWindowBlur() {
    if (panelMode.value && !_panelBusy) hidePanel();
  }

  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (_minimizeToTray && _trayReady) {
      await windowManager.hide();
    } else {
      await _quit();
    }
  }
}
