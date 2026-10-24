import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app/app_shell.dart';
import 'app/theme.dart';
import 'demo/demo_data.dart';
import 'services/desktop.dart';
import 'services/history_store.dart';
import 'services/home_widget_bridge.dart';
import 'services/notifier.dart';
import 'services/persistence.dart';
import 'state/app_controller.dart';
import 'state/update_controller.dart';
import 'ui/tray_panel.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final demoData = kDemoMode ? DemoData(DateTime.now()) : null;
  final persistence = demoData == null ? await Persistence.open() : await Persistence.openDemo();
  final settings = await persistence.loadSettings();
  final desktop = DesktopIntegration();
  final notifier = Notifier();
  final homeWidget = HomeWidgetBridge();

  final controller = AppController(
    persistence: persistence,
    historyStore: demoData == null
        ? await HistoryStore.open()
        : HistoryStore.demo(demoData.history),
    desktop: desktop,
    notifier: notifier,
    homeWidget: homeWidget,
  );

  await desktop.init(onRefresh: controller.refresh, minimizeToTray: settings.minimizeToTray);
  await notifier.init();
  await homeWidget.init();
  if (demoData == null) {
    await controller.init();
  } else {
    controller.initDemo(demoData);
  }

  final updates = UpdateController(
    readSettings: () => controller.settings,
    saveSettings: controller.updateSettings,
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: controller),
        ChangeNotifierProvider.value(value: updates),
      ],
      child: const TokenBarApp(),
    ),
  );
  unawaited(updates.init());
  if (controller.settings.notificationsEnabled) unawaited(notifier.requestPermission());
  // `token_bar.exe --panel` opens straight into the tray panel (handy for testing).
  if (args.contains('--panel') || const bool.fromEnvironment('TOKENBAR_PANEL')) {
    unawaited(desktop.showPanel());
  }
}

class TokenBarApp extends StatelessWidget {
  const TokenBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<AppController, ThemeMode>((c) => c.settings.themeMode);
    final desktop = context.read<AppController>().desktop;
    return MaterialApp(
      title: 'TokenBar',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // The UI is Chinese. Setting the locale also makes the engine pick Chinese
      // glyph variants (instead of Japanese ones) when it falls back for Han text.
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // The same window doubles as the tray panel; the navigator (and its state)
      // stays alive underneath while the panel is up.
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: desktop.panelMode,
        builder: (context, panel, _) => Stack(
          children: [
            Offstage(offstage: panel, child: child),
            if (panel) const Positioned.fill(child: TrayPanel()),
          ],
        ),
      ),
      home: const AppShell(),
    );
  }
}
