import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/src/providers/api/cookie_b_providers.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

final _now = DateTime.utc(2026, 10, 13, 12);

http.Response _body(String text, [int status = 200]) => http.Response.bytes(
  utf8.encode(text),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _json(Object body, [int status = 200]) => _body(jsonEncode(body), status);

Future<UsageSnapshot> _run(
  UsageProvider provider,
  http.Response Function(http.Request) respond, {
  required String cookie,
  Map<String, String> options = const {},
  DateTime? now,
}) async {
  final client = MockClient((r) async => respond(r));
  final account = AccountConfig(
    id: 'a',
    providerId: provider.id,
    label: provider.id,
    sourceType: SourceType.apiKey,
    secret: cookie,
    options: options,
  );
  return provider.fetchSafely(account, FetchContext(client: client, clock: () => now ?? _now));
}

void main() {
  test('provider ids and cookie-only sources', () {
    final providers = <UsageProvider>[
      MiMoProvider(),
      SakanaProvider(),
      RaycastProvider(),
      ReplicateProvider(),
      TypeSafeProvider(),
      ClaudePlatformProvider(),
      AlibabaCodingPlanProvider(),
      AlibabaTokenPlanProvider(),
      QwenCloudProvider(),
      OpenCodeProvider(),
    ];
    expect(providers.map((p) => p.id).toList(), [
      'mimo',
      'sakana',
      'raycast',
      'replicate',
      'typesafe',
      'claudeplatform',
      'alibabacodingplan',
      'alibabatokenplan',
      'qwencloud',
      'opencode',
    ]);
    expect(MiMoProvider().cookieProblem('userId=1'), contains('api-platform_serviceToken'));
    expect(RaycastProvider().cookieProblem('csrf_token=x'), contains('__raycast_session'));
    expect(OpenCodeProvider().cookieProblem('foo=bar'), isNotNull);
    expect(OpenCodeProvider().cookieProblem('auth=abc'), isNull);
  });

  test('mimo: balance, token plan and usage', () async {
    final s = await _run(MiMoProvider(), (r) {
      if (r.url.path.endsWith('/balance')) {
        return _json({
          'code': 0,
          'data': {
            'balance': '11.97',
            'currency': 'USD',
            'cashBalance': '10',
            'giftBalance': '1.97',
          },
        });
      }
      if (r.url.path.endsWith('/tokenPlan/detail')) {
        return _json({
          'code': 0,
          'data': {
            'planCode': 'standard',
            'currentPeriodEnd': '2026-11-01 00:00:00',
            'expired': false,
          },
        });
      }
      return _json({
        'code': 0,
        'data': {
          'monthUsage': {
            'percent': 0.25,
            'items': [
              {'name': 'credits', 'used': 500, 'limit': 2000, 'percent': 0.25},
            ],
          },
        },
      });
    }, cookie: 'api-platform_serviceToken=tok; userId=42');
    expect(s.error, isNull);
    expect(s.plan, 'Standard');
    expect(s.window('mimo-plan')!.usedPercent, closeTo(25, 1e-9));
    expect(s.credits.single.balance, closeTo(11.97, 1e-9));
    expect(s.credits.single.currency, 'USD');
  });

  test('sakana: 5-hour and weekly windows from billing HTML', () async {
    final s = await _run(SakanaProvider(), (r) {
      if (r.url.queryParameters['tab'] == 'payAsYouGo') return _body('', 404);
      return _body(_fixture('sakana_billing_page.html'));
    }, cookie: 'session=abc');
    expect(s.error, isNull);
    expect(s.plan, 'Standard \$20/mo');
    expect(s.window(RateWindow.sessionId)!.usedPercent, 92);
    expect(s.window(RateWindow.weeklyId)!.usedPercent, 32);
    expect(s.window(RateWindow.sessionId)!.resetsAt, DateTime.utc(2026, 6, 23, 14, 53));
    expect(s.window(RateWindow.weeklyId)!.resetsAt, DateTime.utc(2026, 6, 29));
  });

  test('raycast: credits meter from string amounts', () async {
    final s = await _run(
      RaycastProvider(),
      (_) => _body(_fixture('raycast_credits.json')),
      cookie: '__raycast_session=s; csrf_token=c',
    );
    expect(s.error, isNull);
    expect(s.plan, 'Pro');
    expect(s.window('raycast-credits')!.usedPercent, closeTo(75, 1e-9));
    expect(s.extras['余额'], '125 / 500 credits left');
  });

  test('raycast: decimal balances keep two-decimal text', () async {
    final s = await _run(
      RaycastProvider(),
      (_) => _body(_fixture('raycast_website_decimal.json')),
      cookie: '__raycast_session=s',
    );
    expect(s.error, isNull);
    expect(s.extras['余额'], '337.38 / 500 credits left');
    expect(s.window('raycast-credits')!.usedPercent, closeTo((500 - 337.3751) / 500 * 100, 1e-9));
  });

  test('raycast: zero allowance shows plain credit rows', () async {
    final s = await _run(
      RaycastProvider(),
      (_) => _body(_fixture('raycast_zero_allowance.json')),
      cookie: '__raycast_session=s',
    );
    expect(s.error, isNull);
    expect(s.plan, 'Max');
    expect(s.windows, isEmpty);
    expect(s.credits.map((c) => c.label), containsAll(['剩余', '总额']));
  });

  test('replicate: monthly spend and unused credit', () async {
    final s = await _run(ReplicateProvider(), (r) {
      if (r.url.path.endsWith('/invoices')) return _body(_fixture('replicate_invoices.json'));
      if (r.url.path.endsWith('/unused-credit')) {
        return _body(_fixture('replicate_unused_credit.json'));
      }
      return _body(_fixture('replicate_billing_page.html'));
    }, cookie: 'sessionid=abc');
    expect(s.error, isNull);
    expect(s.credits.single.used, closeTo(12.4, 1e-9));
    expect(s.credits.single.balance, closeTo(80.0, 1e-9));
    expect(s.extras['账户'], 'demo-user');
  });

  test('typesafe: billing action response', () async {
    final s = await _run(TypeSafeProvider(), (r) {
      if (r.method == 'POST') return _body(_fixture('typesafe_billing_action.txt'));
      if (r.url.path.endsWith('.js')) return _body(_fixture('typesafe_chunk.txt'));
      return _body(_fixture('typesafe_billing_page.html'));
    }, cookie: 'session=abc');
    expect(s.error, isNull);
    expect(s.plan, 'Free');
    expect(s.credits.single.used, closeTo(0.01, 1e-9));
    expect(s.credits.single.balance, closeTo(4.98, 1e-9));
  });

  test('claudeplatform: prepaid grants and current spend', () async {
    final s = await _run(
      ClaudePlatformProvider(),
      (r) {
        final path = r.url.path;
        if (path == '/api/organizations') {
          return _body(_fixture('claudeplatform_organizations.json'));
        }
        if (path.endsWith('/prepaid/credits')) {
          return _body(_fixture('claudeplatform_prepaid_credits.json'));
        }
        if (path.endsWith('/current_spend')) {
          return _body(_fixture('claudeplatform_current_spend.json'));
        }
        return _body('', 404);
      },
      cookie: 'sessionKey=sk-ant-test',
      now: DateTime.utc(2026, 10, 13),
    );
    expect(s.error, isNull);
    expect(s.credits.single.balance, closeTo(187.25, 1e-9));
    expect(s.window('claudeplatform-api')!.usedPercent, closeTo(37.625, 1e-9));
    expect(s.window('claudeplatform-purchased')!.usedPercent, closeTo(37.5, 1e-9));
    expect(s.extras['本月花费 (UTC)'], '\$43.21');
  });

  group('alibaba coding plan', () {
    test('cookie path reads the quota instance', () async {
      final s = await _run(
        AlibabaCodingPlanProvider(),
        (r) {
          if (r.url.host == 'bailian-singapore-cs.alibabacloud.com') {
            return _body(_fixture('alibabacodingplan_quota.json'));
          }
          return _body('<html></html>');
        },
        cookie: 'login_aliyunid_ticket=t; sec_token=cookie-sec; cna=c1',
        now: DateTime.utc(2023, 11, 14, 22, 10),
      );
      expect(s.error, isNull);
      expect(s.plan, 'Alibaba Coding Plan Pro');
      expect(s.window('alibaba-5h')!.usedPercent, closeTo(5.2, 1e-9));
      expect(s.window('alibaba-weekly')!.usedPercent, closeTo(16, 1e-9));
      expect(s.window('alibaba-monthly')!.usedPercent, closeTo(6, 1e-9));
    });

    test('active instance wins over expired instance', () {
      final parsed = parseAlibabaCodingPlanBody(
        _fixture('alibabacodingplan_multi_instance.json'),
        DateTime.utc(2023, 11, 14, 22, 10),
        apiKey: false,
      );
      expect(parsed.plan, 'Active Pro');
      expect(parsed.windows.single.usedPercent, closeTo(5.2, 1e-9));
    });

    test('need-login payload raises a login error', () {
      expect(
        () => parseAlibabaCodingPlanBody(
          _fixture('alibabacodingplan_need_login.json'),
          _now,
          apiKey: false,
        ),
        throwsA(isA<ProviderException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });
  });

  test('alibaba token plan: team summary', () async {
    final s = await _run(
      AlibabaTokenPlanProvider(),
      (r) {
        if (r.url.path == '/data/api.json') {
          return _body(_fixture('alibabatokenplan_team_summary.json'));
        }
        return _body('', 404);
      },
      cookie: 'login_aliyunid_ticket=t; sec_token=s1',
      options: {'region': 'intl'},
    );
    expect(s.error, isNull);
    expect(s.plan, 'TOKEN PLAN');
    expect(s.window('alibaba-token-team')!.usedPercent, closeTo(12.5, 1e-9));
    expect(s.extras['剩余'], '875');
  });

  test('alibaba token plan: personal rolling windows', () async {
    final s = await _run(
      AlibabaTokenPlanProvider(),
      (r) {
        final api = r.url.queryParameters['api'] ?? '';
        if (api.endsWith('/usage')) return _body(_fixture('alibabatokenplan_personal_usage.json'));
        if (api.endsWith('/subscription')) {
          return _body(_fixture('alibabatokenplan_personal_subscription.json'));
        }
        if (api.endsWith('/quota-config')) {
          return _body(_fixture('alibabatokenplan_personal_quota_config.json'));
        }
        return _body('', 404);
      },
      cookie: 'login_aliyunid_ticket=t; sec_token=s1',
      options: {'region': 'intl-personal'},
    );
    expect(s.error, isNull);
    expect(s.plan, 'Pro');
    expect(s.window(RateWindow.sessionId)!.usedPercent, closeTo(0.09973083333, 1e-6));
    expect(s.window(RateWindow.weeklyId)!.usedPercent, closeTo(0.03014725, 1e-6));
  });

  test('qwencloud: individual fallback when team is not active', () async {
    final s = await _run(QwenCloudProvider(), (r) {
      if (r.url.host == 'cs-data.qwencloud.com') {
        final api = r.url.queryParameters['api'] ?? '';
        if (api.endsWith('/usage')) return _body(_fixture('qwencloud_personal_usage.json'));
        return _body('', 404);
      }
      if (r.url.path == '/tool/user/info.json') return _json({'data': <String, Object?>{}});
      return _body('', 404);
    }, cookie: 'sec_token=s1; cna=c; login_aliyunid_csrf=c');
    expect(s.error, isNull);
    expect(s.window(RateWindow.sessionId)!.usedPercent, closeTo(3, 1e-9));
    expect(s.window(RateWindow.weeklyId)!.usedPercent, closeTo(1, 1e-9));
  });

  test('qwencloud: login-required team error is surfaced when individual fails too', () async {
    final s = await _run(QwenCloudProvider(), (r) {
      if (r.url.path == '/tool/user/info.json') {
        return _body(_fixture('qwencloud_login_required.json'));
      }
      return _body('', 404);
    }, cookie: 'sec_token=s1');
    expect(s.error, contains('需要重新登录'));
    expect(s.error, contains('Qwen Cloud Team'));
  });

  group('opencode console', () {
    test('go subscription meters, fraction and percent encodings', () async {
      final s = await _run(OpenCodeProvider(), (r) {
        if (r.url.path == '/console/api/orgs') {
          return _json([
            {'id': 'wrk_123'},
          ]);
        }
        if (r.url.path == '/console/api/go/status') {
          expect(r.headers['x-org-id'], 'wrk_123');
          return _json({
            'access': {
              'endsAt': '2026-11-01T00:00:00Z',
              'meters': {
                'fiveHour': {'usagePercent': 40, 'resetInSec': 3600},
                'week': {'usagePercent': 0.2, 'resetInSec': 86400},
                'month': {'usagePercent': 10},
              },
            },
          });
        }
        return _body('', 404);
      }, cookie: 'auth=abc');
      expect(s.error, isNull);
      expect(s.window(RateWindow.sessionId)!.usedPercent, closeTo(40, 1e-9));
      expect(s.window(RateWindow.weeklyId)!.usedPercent, closeTo(20, 1e-9));
      expect(s.window('opencode-monthly')!.usedPercent, closeTo(10, 1e-9));
      expect(s.window('opencode-monthly')!.resetsAt, DateTime.utc(2026, 11, 1));
    });

    test('pay-as-you-go spend and prepaid balance', () async {
      final s = await _run(OpenCodeProvider(), (r) {
        final path = r.url.path;
        if (path == '/console/api/orgs') {
          return _json([
            {'id': 'org_9'},
          ]);
        }
        if (path == '/console/api/go/status') return _json({'access': null});
        if (path == '/console/api/orgs/current') return _json({'hasGoSubscription': false});
        if (path == '/console/api/billing/status') {
          return _json({
            'mode': 'pay-as-you-go',
            'billingMode': 'prepaid',
            'balanceMicroCents': '1250000000',
          });
        }
        if (path == '/console/api/usage/summary') {
          return _json({'totalCostMicroCents': '1500000000'});
        }
        return _body('', 404);
      }, cookie: 'auth=abc');
      expect(s.error, isNull);
      final c = s.credits.single;
      expect(c.used, closeTo(15, 1e-9));
      expect(c.balance, closeTo(12.5, 1e-9));
      expect(c.currency, 'USD');
    });
  });
}
