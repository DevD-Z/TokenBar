import 'package:flutter/foundation.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../l10n/app_localizations.dart';

/// Web build: no tray / window management.
class DesktopIntegration {
  bool get supported => false;

  final ValueNotifier<bool> panelMode = ValueNotifier(false);

  Future<void> init({
    required void Function() onRefresh,
    required bool minimizeToTray,
    required AppLocalizations l10n,
  }) async {}

  Future<void> update(List<UsageSnapshot> snapshots, AppLocalizations l10n) async {}

  Future<void> setMinimizeToTray(bool value) async {}

  Future<void> setLaunchAtStartup(bool value) async {}

  Future<void> showWindow() async {}

  Future<void> showMainWindow() async {}

  Future<void> showPanel() async {}

  Future<void> hidePanel() async {}

  Future<void> quit() async {}
}
