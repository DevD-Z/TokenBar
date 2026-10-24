import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/l10n/app_locale.dart';
import 'package:token_bar/l10n/app_localizations.dart';
import 'package:token_bar/state/settings.dart';
import 'package:token_bar/ui/format.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

Set<String> _messageKeys(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final k in json.keys)
      if (!k.startsWith('@')) k,
  };
}

void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));
  final en = lookupAppLocalizations(const Locale('en'));
  final now = DateTime(2026, 10, 23, 12);

  group('ARB files', () {
    test('zh template and en translation define the same messages', () {
      final zhKeys = _messageKeys('lib/l10n/app_zh.arb');
      final enKeys = _messageKeys('lib/l10n/app_en.arb');
      expect(enKeys.difference(zhKeys), isEmpty, reason: 'en keys missing from zh');
      expect(zhKeys.difference(enKeys), isEmpty, reason: 'zh keys missing from en');
    });

    test('english messages without placeholders keep single apostrophes', () {
      // 没有占位符的消息不经过 ICU 解析，ARB 里写成 '' 会原样输出两个单引号。
      expect(en.upToDate, "You're up to date");
      expect(en.cursorPlanUsage, "This month's usage");
    });
  });

  group('format.dart labels', () {
    test('quota windows translate common period words in English', () {
      expect(
        windowLabel(
          en,
          const RateWindow(id: RateWindow.sessionId, label: '5-hour', usedPercent: 1),
        ),
        '5-hour',
      );
      expect(
        windowLabel(
          zh,
          const RateWindow(id: RateWindow.sessionId, label: '5-hour', usedPercent: 1),
        ),
        '5 小时',
      );
      expect(
        windowLabel(en, const RateWindow(id: 'x', label: '每周 Credits', usedPercent: 1)),
        'Weekly Credits',
      );
      expect(windowLabel(en, const RateWindow(id: 'x', label: '每月', usedPercent: 1)), 'Monthly');
      expect(
        windowLabel(zh, const RateWindow(id: 'cursor-total', label: 'Monthly', usedPercent: 1)),
        '本月额度',
      );
      expect(
        windowLabel(en, const RateWindow(id: 'cursor-total', label: 'Monthly', usedPercent: 1)),
        'Monthly quota',
      );
      expect(windowLabel(en, const RateWindow(id: 'x', label: '7-day', usedPercent: 1)), '7-day');
      expect(windowLabel(zh, const RateWindow(id: 'x', label: '7-day', usedPercent: 1)), '7 天');
      // Labels with no known term are shown unchanged.
      expect(windowLabel(en, const RateWindow(id: 'x', label: '套餐积分', usedPercent: 1)), '套餐积分');
    });

    test('countdowns and reset text', () {
      expect(countdownLabel(zh, const Duration(days: 2, hours: 3)), '2天3小时');
      expect(countdownLabel(en, const Duration(days: 2, hours: 3)), '2d 3h');
      expect(countdownLabel(en, const Duration(minutes: 45)), '45m');
      expect(countdownLabel(zh, const Duration(minutes: 45)), '45分钟');
      expect(countdownLabel(en, const Duration(seconds: 30)), 'Less than 1 min');
      expect(resetsInLabel(en, const Duration(hours: 2, minutes: 5)), 'Resets in 2h 5m');
      expect(resetsInLabel(zh, const Duration(hours: 2, minutes: 5)), '2小时5分后重置');
      expect(resetsInLabel(en, Duration.zero), 'Resetting soon');
      expect(resetsInLabel(zh, Duration.zero), '即将重置');
    });

    test('reset clock times, relative days and dates', () {
      expect(resetTimeLabel(zh, DateTime(2026, 10, 23, 18, 5), now), '18:05');
      expect(resetTimeLabel(en, DateTime(2026, 10, 23, 18, 5), now), '18:05');
      expect(resetTimeLabel(zh, DateTime(2026, 10, 24, 9, 0), now), '明天 09:00');
      expect(resetTimeLabel(en, DateTime(2026, 10, 24, 9, 0), now), 'Tomorrow 09:00');
      // 2026-10-26 is a Monday.
      expect(resetTimeLabel(zh, DateTime(2026, 10, 26, 14, 30), now), '周一 14:30');
      expect(resetTimeLabel(en, DateTime(2026, 10, 26, 14, 30), now), 'Mon 14:30');
      expect(resetTimeLabel(zh, DateTime(2026, 11, 3, 8, 0), now), '11月3日 08:00');
      expect(resetTimeLabel(en, DateTime(2026, 11, 3, 8, 0), now), '11/3 08:00');
    });

    test('relative "ago" text, including plurals in English', () {
      expect(agoLabel(zh, now.subtract(const Duration(seconds: 10)), now), '刚刚');
      expect(agoLabel(en, now.subtract(const Duration(seconds: 10)), now), 'Just now');
      expect(agoLabel(zh, now.subtract(const Duration(minutes: 3)), now), '3 分钟前');
      expect(agoLabel(en, now.subtract(const Duration(minutes: 3)), now), '3 minutes ago');
      expect(agoLabel(en, now.subtract(const Duration(minutes: 1)), now), '1 minute ago');
      expect(agoLabel(en, now.subtract(const Duration(hours: 1)), now), '1 hour ago');
      expect(agoLabel(zh, now.subtract(const Duration(hours: 5)), now), '5 小时前');
      expect(agoLabel(en, now.subtract(const Duration(days: 2)), now), '2 days ago');
    });

    test('credits labels and unlimited values', () {
      const balance = Credits(id: 'codex-credits', label: 'Credits', balance: 12.5);
      expect(creditsLabel(zh, balance), 'Credits 余额');
      expect(creditsLabel(en, balance), 'Credits balance');
      const unlimited = Credits(id: 'x', label: 'x', unlimited: true);
      expect(creditsValue(zh, unlimited), '无限');
      expect(creditsValue(en, unlimited), 'Unlimited');
    });

    test('source labels', () {
      expect(sourceLabel(zh, 'remote'), '服务器');
      expect(sourceLabel(en, 'remote'), 'Server');
      expect(sourceLabel(zh, 'cursor-app'), 'Cursor 本机登录');
      expect(sourceLabel(en, 'cursor-app'), 'Cursor local login');
      expect(sourceLabel(en, 'oauth'), 'OAuth');
      expect(sourceLabel(en, null), '');
    });

    test('sync mode labels', () {
      expect(SyncMode.local.label(zh), '不使用');
      expect(SyncMode.local.label(en), 'Off');
      expect(SyncMode.localPush.label(en), 'Push this device');
    });
  });

  group('locale resolution', () {
    test('explicit choices ignore the device language', () {
      const device = [Locale('fr', 'FR')];
      expect(resolveAppLocale(AppLanguage.zh, device), const Locale('zh', 'CN'));
      expect(
        resolveAppLocale(AppLanguage.en, const [Locale('zh', 'CN')]),
        const Locale('en', 'US'),
      );
    });

    test('system follows Chinese devices and falls back to English', () {
      expect(
        resolveAppLocale(AppLanguage.system, const [Locale('zh', 'TW')]),
        const Locale('zh', 'CN'),
      );
      expect(
        resolveAppLocale(AppLanguage.system, const [Locale('fr', 'FR'), Locale('zh', 'CN')]),
        const Locale('en', 'US'),
      );
      expect(resolveAppLocale(AppLanguage.system, const [Locale('ja')]), const Locale('en', 'US'));
      expect(resolveAppLocale(AppLanguage.system, const []), const Locale('en', 'US'));
    });
  });

  group('language setting', () {
    test('defaults to following the system', () {
      expect(AppSettings.defaults().language, AppLanguage.system);
      expect(AppSettings.fromJson(const {}).language, AppLanguage.system);
    });

    test('round-trips through json', () {
      for (final lang in AppLanguage.values) {
        final json = AppSettings.defaults().copyWith(language: lang).toJson();
        expect(json['language'], lang.name);
        expect(AppSettings.fromJson(json).language, lang);
      }
    });

    test('unknown or malformed values fall back to system', () {
      expect(AppSettings.fromJson(const {'language': 'klingon'}).language, AppLanguage.system);
      expect(AppSettings.fromJson(const {'language': 42}).language, AppLanguage.system);
      // Older files keep working and gain the default.
      expect(AppSettings.fromJson(const {'themeMode': 'dark'}).language, AppLanguage.system);
    });
  });
}
