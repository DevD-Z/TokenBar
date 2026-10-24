import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/update/app_version.dart';
import '../services/update/update_service.dart';
import 'settings.dart';

enum UpdateStatus { idle, checking, upToDate, available, error }

/// Checks GitHub Releases for a newer TokenBar and tells the UI when to prompt.
///
/// An automatic check runs once at launch (can be turned off in settings) and
/// stays silent unless a version newer than the one the user skipped exists.
/// A manual check always reports its outcome.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.readSettings,
    required this.saveSettings,
    UpdateService? service,
    Future<String> Function()? versionLoader,
  }) : _service = service ?? UpdateService(),
       _versionLoader = versionLoader ?? _packageVersion;

  final AppSettings Function() readSettings;
  final Future<void> Function(AppSettings) saveSettings;
  final UpdateService _service;
  final Future<String> Function() _versionLoader;

  UpdateStatus status = UpdateStatus.idle;
  ReleaseInfo? release;

  /// `network`, `rate_limit` or `bad_response` while [status] is `error`.
  String? errorCode;

  /// Installed version, e.g. `1.0.0`; empty until [init] has run.
  String currentVersion = '';
  DateTime? lastChecked;

  bool _promptPending = false;
  bool _disposed = false;

  static Future<String> _packageVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Loads the installed version and runs the automatic check.
  Future<void> init() async {
    try {
      currentVersion = await _versionLoader();
    } on Object {
      currentVersion = '';
    }
    _notify();
    if (readSettings().autoCheckUpdates) await check(manual: false);
  }

  /// The release to show in the "update available" dialog, once. `null` when
  /// there is nothing to show.
  ReleaseInfo? takePrompt() {
    if (!_promptPending || status != UpdateStatus.available) return null;
    _promptPending = false;
    return release;
  }

  /// Don't offer [r] again automatically (a newer release will still be offered).
  Future<void> skip(ReleaseInfo r) => saveSettings(readSettings().copyWith(skippedVersion: r.tag));

  Future<void> check({required bool manual}) async {
    if (status == UpdateStatus.checking) return;
    status = UpdateStatus.checking;
    errorCode = null;
    _notify();
    try {
      final latest = await _service.fetchLatest(currentVersion: currentVersion);
      lastChecked = DateTime.now();
      final installed = AppVersion.tryParse(currentVersion);
      if (latest != null && installed != null && latest.version > installed) {
        release = latest;
        status = UpdateStatus.available;
        _promptPending = manual || readSettings().skippedVersion != latest.tag;
      } else {
        release = null;
        status = UpdateStatus.upToDate;
      }
    } on UpdateException catch (e) {
      errorCode = e.code;
      status = UpdateStatus.error;
      // Background checks fail quietly (offline is normal); only manual ones show it.
    } on Object {
      errorCode = 'bad_response';
      status = UpdateStatus.error;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _service.close();
    super.dispose();
  }
}
