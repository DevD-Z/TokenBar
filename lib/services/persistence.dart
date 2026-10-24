import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../state/settings.dart';

/// Settings + accounts in shared_preferences, secrets in secure storage.
class Persistence {
  Persistence._(this._prefs, {this.useSecureStorage = true});

  static Future<Persistence> open() async => Persistence._(await SharedPreferences.getInstance());

  /// In-memory storage for demo mode: nothing is read from or written to the
  /// real preferences or the system secure storage.
  static Future<Persistence> openDemo() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    return Persistence._(await SharedPreferences.getInstance(), useSecureStorage: false);
  }

  final SharedPreferences _prefs;
  final bool useSecureStorage;
  static const _secure = FlutterSecureStorage();

  static const _settingsKey = 'tokenbar.settings';
  static const _accountsKey = 'tokenbar.accounts';
  static const _snapshotsKey = 'tokenbar.snapshots';
  static const _notifyStateKey = 'tokenbar.notifyState';
  static const _serverTokenKey = 'tokenbar.serverToken';
  static String _secretKey(String accountId) => 'tokenbar.secret.$accountId';

  Future<String?> _readSecret(String key) async {
    if (!useSecureStorage) return _prefs.getString('fallback.$key');
    try {
      return await _secure.read(key: key);
    } catch (e) {
      // Secure storage can be unavailable (e.g. Linux without libsecret,
      // insecure web context); fall back to prefs so the app keeps working.
      debugPrint('secure storage read failed: $e');
      return _prefs.getString('fallback.$key');
    }
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (!useSecureStorage) {
      if (value == null || value.isEmpty) {
        await _prefs.remove('fallback.$key');
      } else {
        await _prefs.setString('fallback.$key', value);
      }
      return;
    }
    try {
      if (value == null || value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (e) {
      debugPrint('secure storage write failed: $e');
      if (value == null || value.isEmpty) {
        await _prefs.remove('fallback.$key');
      } else {
        await _prefs.setString('fallback.$key', value);
      }
    }
  }

  Future<AppSettings> loadSettings() async {
    final raw = _prefs.getString(_settingsKey);
    final token = await _readSecret(_serverTokenKey) ?? '';
    if (raw == null) return AppSettings.defaults().copyWith(serverToken: token);
    return AppSettings.fromJson(jsonDecode(raw) as Map<String, Object?>, token: token);
  }

  Future<void> saveSettings(AppSettings s) async {
    await _prefs.setString(_settingsKey, jsonEncode(s.toJson()));
    await _writeSecret(_serverTokenKey, s.serverToken);
  }

  Future<List<AccountConfig>> loadAccounts() async {
    final raw = _prefs.getString(_accountsKey);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
    final accounts = <AccountConfig>[];
    for (final json in list) {
      final account = AccountConfig.fromJson(json);
      final secret = account.sourceType == SourceType.apiKey
          ? await _readSecret(_secretKey(account.id))
          : null;
      accounts.add(secret == null ? account : account.copyWith(secret: secret));
    }
    return accounts;
  }

  Future<void> saveAccounts(List<AccountConfig> accounts) async {
    await _prefs.setString(_accountsKey, jsonEncode(accounts.map((a) => a.toJson()).toList()));
    for (final a in accounts) {
      if (a.sourceType == SourceType.apiKey) {
        await _writeSecret(_secretKey(a.id), a.secret);
      }
    }
  }

  Future<void> deleteAccountSecret(String accountId) => _writeSecret(_secretKey(accountId), null);

  /// Last snapshots, so the UI shows data instantly on launch.
  List<UsageSnapshot> loadCachedSnapshots() {
    final raw = _prefs.getString(_snapshotsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => UsageSnapshot.fromJson((e as Map).cast<String, Object?>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCachedSnapshots(List<UsageSnapshot> snapshots) =>
      _prefs.setString(_snapshotsKey, jsonEncode(snapshots.map((s) => s.toJson()).toList()));

  Map<String, Object?> loadNotifyState() {
    final raw = _prefs.getString(_notifyStateKey);
    return raw == null ? {} : (jsonDecode(raw) as Map).cast<String, Object?>();
  }

  Future<void> saveNotifyState(Map<String, Object?> state) =>
      _prefs.setString(_notifyStateKey, jsonEncode(state));
}
