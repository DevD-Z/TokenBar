import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:token_bar/l10n/app_localizations.dart';
import 'package:token_bar/services/update/app_version.dart';
import 'package:token_bar/services/update/update_service.dart';
import 'package:token_bar/state/settings.dart';
import 'package:token_bar/state/update_controller.dart';
import 'package:token_bar/ui/update_dialog.dart';

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String body = 'Notes',
  String? htmlUrl,
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'html_url': htmlUrl ?? 'https://github.com/lwh0630/TokenBar/releases/tag/$tag',
};

UpdateService _service(Object body, {int status = 200}) =>
    UpdateService(client: MockClient((_) async => http.Response(jsonEncode(body), status)));

void main() {
  group('AppVersion', () {
    test('parses with and without v prefix and build metadata', () {
      expect(AppVersion.tryParse('v1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2.3+7'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse(null), isNull);
    });

    test('orders by SemVer precedence', () {
      AppVersion v(String s) => AppVersion.tryParse(s)!;
      expect(v('1.10.0') > v('1.9.9'), isTrue);
      expect(v('1.0.0') > v('1.0.0-rc.1'), isTrue);
      expect(v('1.0.0-rc.2') > v('1.0.0-rc.1'), isTrue);
      expect(v('1.0.0-rc.1') > v('1.0.0-beta.9'), isTrue);
      expect(v('1.0.0+5') == v('1.0.0'), isTrue);
    });
  });

  group('UpdateService.parseRelease', () {
    test('reads tag, notes and page', () {
      final r = UpdateService.parseRelease(_release('v1.2.0', body: '  hello  '))!;
      expect(r.version, const AppVersion(1, 2, 0));
      expect(r.notes, 'hello');
      expect(r.pageUrl.host, 'github.com');
    });

    test('ignores drafts, pre-releases and odd tags', () {
      expect(UpdateService.parseRelease(_release('v1.2.0', draft: true)), isNull);
      expect(UpdateService.parseRelease(_release('v1.2.0', prerelease: true)), isNull);
      expect(UpdateService.parseRelease(_release('v1.2.0-beta.1')), isNull);
      expect(UpdateService.parseRelease(_release('nightly')), isNull);
      expect(UpdateService.parseRelease('nope'), isNull);
    });

    test('replaces an untrusted page URL with the release page', () {
      final r = UpdateService.parseRelease(_release('v1.2.0', htmlUrl: 'https://evil.example/x'))!;
      expect(r.pageUrl.toString(), 'https://github.com/lwh0630/TokenBar/releases/tag/v1.2.0');
      expect(isTrustedReleaseUrl(Uri.parse('http://github.com/x')), isFalse);
      expect(isTrustedReleaseUrl(Uri.parse('https://github.com.evil.io/x')), isFalse);
    });
  });

  group('UpdateService.fetchLatest', () {
    test('maps HTTP failures to codes', () async {
      expect(await _service({}, status: 404).fetchLatest(currentVersion: '1.0.0'), isNull);
      for (final (status, code) in [
        (403, 'rate_limit'),
        (429, 'rate_limit'),
        (500, 'bad_response'),
      ]) {
        await expectLater(
          _service({}, status: status).fetchLatest(currentVersion: '1.0.0'),
          throwsA(isA<UpdateException>().having((e) => e.code, 'code', code)),
        );
      }
      final broken = UpdateService(client: MockClient((_) async => http.Response('<html>', 200)));
      await expectLater(
        broken.fetchLatest(currentVersion: '1.0.0'),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', 'bad_response')),
      );
      final offline = UpdateService(
        client: MockClient((_) async => throw http.ClientException('x')),
      );
      await expectLater(
        offline.fetchLatest(currentVersion: '1.0.0'),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', 'network')),
      );
    });

    test('identifies the app and only asks for the latest release', () async {
      late http.Request seen;
      final service = UpdateService(
        client: MockClient((req) async {
          seen = req;
          return http.Response(jsonEncode(_release('v1.0.1')), 200);
        }),
      );
      await service.fetchLatest(currentVersion: '1.0.0');
      expect(seen.url.toString(), 'https://api.github.com/repos/lwh0630/TokenBar/releases/latest');
      expect(seen.headers['User-Agent'], 'TokenBar/1.0.0');
      expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    });
  });

  group('UpdateController', () {
    late AppSettings settings;

    UpdateController make(Object body, {String version = '1.0.0', int status = 200}) =>
        UpdateController(
          readSettings: () => settings,
          saveSettings: (s) async => settings = s,
          service: _service(body, status: status),
          versionLoader: () async => version,
        );

    setUp(() => settings = AppSettings.defaults());

    test('offers a newer release once', () async {
      final u = make(_release('v1.1.0'));
      await u.init();
      expect(u.status, UpdateStatus.available);
      expect(u.takePrompt()?.tag, 'v1.1.0');
      expect(u.takePrompt(), isNull);
    });

    test('is quiet when up to date or ahead', () async {
      for (final installed in ['1.1.0', '2.0.0']) {
        final u = make(_release('v1.1.0'), version: installed);
        await u.init();
        expect(u.status, UpdateStatus.upToDate);
        expect(u.takePrompt(), isNull);
      }
    });

    test('automatic check can be turned off', () async {
      settings = settings.copyWith(autoCheckUpdates: false);
      final u = make(_release('v9.0.0'));
      await u.init();
      expect(u.status, UpdateStatus.idle);
      expect(u.currentVersion, '1.0.0');
    });

    test(
      'skipped version is not prompted automatically, but manual checks still show it',
      () async {
        final u = make(_release('v1.1.0'));
        await u.init();
        await u.skip(u.release!);
        expect(settings.skippedVersion, 'v1.1.0');

        final again = make(_release('v1.1.0'));
        await again.init();
        expect(again.status, UpdateStatus.available);
        expect(again.takePrompt(), isNull);
        await again.check(manual: true);
        expect(again.takePrompt()?.tag, 'v1.1.0');

        final newer = make(_release('v1.2.0'));
        await newer.init();
        expect(newer.takePrompt()?.tag, 'v1.2.0');
      },
    );

    test('reports errors', () async {
      final u = make({}, status: 403);
      await u.check(manual: true);
      expect(u.status, UpdateStatus.error);
      expect(u.errorCode, 'rate_limit');
    });
  });

  testWidgets('update dialog shows the notes and can skip a version', (tester) async {
    var settings = AppSettings.defaults();
    final updates = UpdateController(
      readSettings: () => settings,
      saveSettings: (s) async => settings = s,
      service: _service(_release('v1.1.0', body: 'Faster refresh\nNew tray panel')),
      versionLoader: () async => '1.0.0',
    );
    await tester.runAsync(updates.init);
    final release = updates.takePrompt()!;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showUpdateDialog(context, updates, release),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v1.1.0'), findsOneWidget);
    expect(find.text('当前版本 1.0.0'), findsOneWidget);
    expect(find.textContaining('New tray panel'), findsOneWidget);
    expect(find.text('前往下载'), findsOneWidget);

    await tester.tap(find.text('忽略此版本'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v1.1.0'), findsNothing);
    expect(settings.skippedVersion, 'v1.1.0');
  });
  test('settings round-trip the update fields', () {
    final s = AppSettings.defaults().copyWith(autoCheckUpdates: false, skippedVersion: 'v2.0.0');
    final back = AppSettings.fromJson(s.toJson());
    expect(back.autoCheckUpdates, isFalse);
    expect(back.skippedVersion, 'v2.0.0');
    expect(AppSettings.fromJson(const {}).autoCheckUpdates, isTrue);
  });
}
