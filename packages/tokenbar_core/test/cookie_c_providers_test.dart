import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/src/providers/api/cookie_c_providers.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

final _now = DateTime.utc(2026, 10, 20, 12);

DateTime _epoch(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// A canned reply with an explicit HTTP status. Plain strings are served as 200 JSON.
class _Reply {
  const _Reply(this.status, this.body);
  final int status;
  final String body;
}

typedef _Respond = http.Response Function(http.Request request);

/// Routes by URL path suffix (first match wins). Unknown paths get HTTP 404.
_Respond _routes(Map<String, Object> routes) => (r) {
  for (final e in routes.entries) {
    if (!r.url.path.endsWith(e.key)) continue;
    final v = e.value;
    const headers = {'content-type': 'application/json'};
    if (v is _Reply) return http.Response(v.body, v.status, headers: headers);
    return http.Response(v as String, 200, headers: headers);
  }
  return http.Response('not found', 404);
};

AccountConfig _account(
  String providerId, {
  String? secret,
  Map<String, String> options = const {},
}) => AccountConfig(
  id: 'a',
  providerId: providerId,
  label: providerId,
  sourceType: SourceType.apiKey,
  secret: secret,
  options: options,
);

Future<(UsageSnapshot, List<http.Request>)> _run(
  UsageProvider provider,
  _Respond respond, {
  String? secret,
  Map<String, String> options = const {},
  DateTime? now,
}) async {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    return respond(r);
  });
  final snapshot = await provider.fetchSafely(
    _account(provider.id, secret: secret, options: options),
    FetchContext(client: client, clock: () => now ?? _now),
  );
  return (snapshot, requests);
}

// ---- muse.ai: synthetic Next.js chunks that the discovery regexes understand.
const _museActionId = '40447f7d32b58c622904d92f8ac01a13f4798568bd';
const _museAppJs =
    'e.A(7).then(({default:Settings})),7,e=>{t.v(n=>Promise.all(["static/chunks/settings.js"]))';
const _museSettingsJs = '"$_museActionId","fetchSubscriptionAction"';

_Respond _museRespond(String flight) => (r) {
  if (r.method == 'POST') return http.Response(flight, 200);
  if (r.url.path.endsWith('app.js')) return http.Response(_museAppJs, 200);
  if (r.url.path.endsWith('settings.js')) return http.Response(_museSettingsJs, 200);
  return http.Response('<script src="/_next/static/chunks/app.js"></script>', 200);
};

/// ZoomMate history rows timestamped at [t] so they fall inside "today" and "30d".
String _zoomHistory(DateTime t) {
  final time = t.toIso8601String();
  return jsonEncode({
    'data': {
      'total': 4,
      'records': [
        {'cost': 2.5, 'time': time},
        {'cost': 1, 'time': time, 'is_running': true},
        {'cost': 999, 'time': time, 'is_deleted': true},
        {'cost': -1, 'time': time},
      ],
    },
  });
}

void main() {
  group('TraeCnProvider', () {
    test('two-step entitlement lookup maps the pack usage', () async {
      final (s, req) = await _run(
        TraeCnProvider(),
        _routes({
          'GetUserToken': _fixture('traecn_user_token.json'),
          'user_current_entitlement_list': _fixture('traecn_entitlements.json'),
        }),
        secret: 'sessionid=fixture-session',
      );
      expect(s.error, isNull);
      final w = s.windows.single;
      expect(w.usedPercent, 20);
      expect(w.windowMinutes, isNull);
      expect(w.resetsAt, isNull);
      expect(req.last.headers['Authorization'], 'Cloud-IDE-JWT fixture-jwt');
    });

    test('session rejected code 1001 becomes an expired-login error', () async {
      final (s, _) = await _run(
        TraeCnProvider(),
        _routes({
          'GetUserToken': _fixture('traecn_user_token.json'),
          'user_current_entitlement_list': jsonEncode({'code': 1001}),
        }),
        secret: 'sessionid=fixture-session',
      );
      expect(s.error, contains('登录已失效'));
    });
  });

  group('WorkBuddyProvider', () {
    test('one credits package gives a 10% window and plan name', () async {
      final (s, _) = await _run(
        WorkBuddyProvider(),
        _routes({
          'get-user-resource-summary': _fixture('workbuddy_summary.json'),
          'get-user-resource-free-packages': _fixture('workbuddy_empty_packages.json'),
          'get-user-resource-paid-packages': _fixture('workbuddy_empty_packages.json'),
        }),
        secret: 'session=fixture-session; locale=zh',
        options: {'chromeMajor': '154'},
      );
      expect(s.error, isNull);
      final w = s.windows.single;
      expect(w.usedPercent, 10);
      expect(w.windowMinutes, isNull);
      expect(s.plan, '体验版');
    });

    test('free package account gives the cycle end as UTC+8 wall clock', () async {
      final (s, _) = await _run(
        WorkBuddyProvider(),
        _routes({
          'get-user-resource-summary': _fixture('workbuddy_summary.json'),
          'get-user-resource-free-packages': _fixture('workbuddy_free_packages.json'),
          'get-user-resource-paid-packages': _fixture('workbuddy_empty_packages.json'),
        }),
        secret: 'session=fixture-session; locale=zh',
        options: {'chromeMajor': '154'},
        now: DateTime.utc(2026, 10, 3),
      );
      expect(s.error, isNull);
      expect(s.windows.single.resetsAt, _epoch(1793462400));
    });

    test('summary 403 is reported as permission denied', () async {
      final (s, _) = await _run(
        WorkBuddyProvider(),
        _routes({'get-user-resource-summary': _Reply(403, '{}')}),
        secret: 'session=fixture-session',
        options: {'chromeMajor': '154'},
      );
      expect(s.error, contains('拒绝访问'));
    });

    test('non-zero API code is surfaced', () async {
      final (s, _) = await _run(
        WorkBuddyProvider(),
        _routes({
          'get-user-resource-summary': jsonEncode({'code': 10001, 'data': {}}),
        }),
        secret: 'session=fixture-session',
        options: {'chromeMajor': '154'},
      );
      expect(s.error, contains('10001'));
    });

    test('missing chrome version fails instead of sending a bare request', () async {
      final (s, _) = await _run(
        WorkBuddyProvider(),
        _routes({}),
        secret: 'session=fixture-session',
      );
      expect(s.error, isNotNull);
    });
  });

  group('LongCatProvider', () {
    test('token pack usage, fuel pack and organization name', () async {
      final (s, _) = await _run(
        LongCatProvider(),
        _routes({
          '/api/v1/user-current': _fixture('longcat_user_current.json'),
          '/token-packs/summary': _fixture('longcat_token_pack_summary.json'),
          '/pending-fuel-packages': _fixture('longcat_fuel_packages.json'),
        }),
        secret: 'session=fixture',
      );
      expect(s.error, isNull);
      expect(s.window('longcat-quota')!.usedPercent, closeTo(2.425152, 1e-6));
      final fuel = s.window('longcat-fuel')!;
      expect(fuel.usedPercent, 25);
      expect(fuel.resetsAt, _epoch(1750000000));
      expect(s.extras['账户'], 'Fixture Account');
    });

    test('legacy tokenUsage fallback when the pack summary is missing', () async {
      final (s, _) = await _run(
        LongCatProvider(),
        _routes({
          '/api/v1/user-current': _fixture('longcat_user_current.json'),
          '/api/lc-platform/v1/tokenUsage': jsonEncode({
            'data': {
              'usage': {'totalToken': 500000, 'usedToken': 120000, 'availableToken': 380000},
            },
          }),
        }),
        secret: 'session=fixture',
      );
      expect(s.error, isNull);
      expect(s.window('longcat-quota')!.usedPercent, closeTo(24, 1e-9));
    });

    test('envelope code 401 becomes an expired-login error', () async {
      final (s, _) = await _run(
        LongCatProvider(),
        _routes({
          '/api/v1/user-current': jsonEncode({'code': 401}),
        }),
        secret: 'session=fixture',
      );
      expect(s.error, contains('登录已失效'));
    });
  });

  group('HelmcodeProvider', () {
    test('cloud quota with prepaid balance in EUR', () async {
      final (s, _) = await _run(
        HelmcodeProvider(),
        _routes({
          '/api/usage/quota': _fixture('helmcode_quota.json'),
          '/api/billing/credits': _fixture('helmcode_credits.json'),
        }),
        secret: '__Host-session=fixture',
      );
      expect(s.error, isNull);
      expect(s.windows.first.usedPercent, closeTo(73854494 / 2000000000 * 100, 1e-9));
      expect(s.windows.first.resetsAt, DateTime.utc(2026, 10, 1));
      expect(s.windows, hasLength(4));
      expect(s.credits.single.balance, closeTo(12.5, 1e-9));
      expect(s.credits.single.currency, 'EUR');
    });

    test('premium subscription adds rolling tiers', () async {
      final (s, _) = await _run(
        HelmcodeProvider(),
        _routes({
          '/api/usage/quota': _fixture('helmcode_quota.json'),
          '/api/billing': _fixture('helmcode_billing_premium.json'),
        }),
        secret: '__Host-session=fixture',
      );
      expect(s.error, isNull);
      expect(s.windows, hasLength(6));
      final rolling = s.windows.firstWhere((w) => w.windowMinutes == 240);
      expect(rolling.resetsAt, DateTime.parse('2026-10-04T19:25:48Z'));
    });

    test('validateManual rejects a pasted cURL command but accepts a cookie', () {
      final p = HelmcodeProvider();
      expect(
        p.validateManual(
          FieldValues.of(
            p,
            _account(p.id, secret: "curl 'https://cloud.helmcode.com' -H 'cookie: a=b'"),
          ),
        ),
        isNotNull,
      );
      expect(
        p.validateManual(FieldValues.of(p, _account(p.id, secret: '__Host-session=fixture'))),
        isNull,
      );
    });
  });

  group('XApiProvider', () {
    test('credits balance sends the ct0 value as CSRF header', () async {
      final (s, req) = await _run(
        XApiProvider(),
        _routes({'/api/me': _fixture('xapi_me.json'), '/credits': _fixture('xapi_credits.json')}),
        secret: 'auth_token=fixture-auth; ct0=fixture-ct0',
      );
      expect(s.error, isNull);
      expect(s.credits.single.balance, closeTo(12.4, 1e-9));
      expect(s.credits.single.currency, 'USD');
      expect(s.extras['免费余额'], r'$2.00');
      expect(req.map((r) => r.url.path).toList(), [
        '/api/me',
        '/api/accounts/fixture-account/credits',
      ]);
      expect(req.last.headers['X-CSRF-Token'], 'fixture-ct0');
    });

    test('integer account id is accepted', () async {
      final (s, req) = await _run(
        XApiProvider(),
        _routes({
          '/api/me': jsonEncode({
            'account': {'id': 42},
          }),
          '/credits': _fixture('xapi_credits.json'),
        }),
        secret: 'auth_token=fixture-auth; ct0=fixture-ct0',
      );
      expect(s.error, isNull);
      expect(req.last.url.path, '/api/accounts/42/credits');
    });

    test('unsafe account id fails before requesting credits', () async {
      final (s, req) = await _run(
        XApiProvider(),
        _routes({
          '/api/me': jsonEncode({
            'account': {'id': '../other'},
          }),
        }),
        secret: 'auth_token=fixture-auth; ct0=fixture-ct0',
      );
      expect(s.error, isNotNull);
      expect(req, hasLength(1));
    });

    test('missing ct0 cookie fails without any request', () async {
      final (s, req) = await _run(XApiProvider(), _routes({}), secret: 'auth_token=fixture-auth');
      expect(s.error, contains('ct0'));
      expect(req, isEmpty);
    });

    test('legacy session error 215 with HTTP 400 is an expired login', () async {
      final (s, _) = await _run(
        XApiProvider(),
        _routes({'/api/me': _Reply(400, _fixture('xapi_session_error.json'))}),
        secret: 'auth_token=fixture-auth; ct0=fixture-ct0',
      );
      expect(s.error, contains('登录已过期'));
    });
  });

  group('LithosAiProvider', () {
    test('balance and UTC spend for the organization', () async {
      final (s, req) = await _run(
        LithosAiProvider(),
        _routes({
          '/api/me': _fixture('lithosai_me.json'),
          '/api/billing/spend': _fixture('lithosai_spend.json'),
          '/api/billing': _fixture('lithosai_billing.json'),
        }),
        secret: '__Host-console_session=fixture; __Host-console_csrf=fixture-csrf',
        now: DateTime.utc(2027, 1, 21, 12),
      );
      expect(s.error, isNull);
      expect(s.credits.single.balance, closeTo(4.70709986, 1e-9));
      expect(s.credits.single.currency, 'USD');
      expect(s.extras.values, containsAll([r'$0.36', r'$2.36']));
      expect(s.windows, isEmpty);
      final billing = req.firstWhere((r) => r.url.path.endsWith('/api/billing'));
      expect(billing.headers['X-Organization-Id'], 'org-fixture');
      final me = req.firstWhere((r) => r.url.path.endsWith('/api/me'));
      expect(me.headers.containsKey('X-Organization-Id'), isFalse);
    });

    test('missing csrf cookie fails without any request', () async {
      final (s, req) = await _run(
        LithosAiProvider(),
        _routes({}),
        secret: '__Host-console_session=fixture',
      );
      expect(s.error, isNotNull);
      expect(req, isEmpty);
    });
  });

  group('TinyApiProvider', () {
    test('available credits as a plain count (no currency)', () async {
      final (s, _) = await _run(
        TinyApiProvider(),
        _routes({'/api/user/credits': _fixture('tinyapi_credits.json')}),
        secret: 'session=fixture-session',
      );
      expect(s.error, isNull);
      expect(s.credits.single.balance, closeTo(125.25, 1e-9));
      expect(s.credits.single.currency, isNull);
      expect(s.windows, isEmpty);
    });

    test('401 is an expired login and the response body is not echoed', () async {
      final (s, _) = await _run(
        TinyApiProvider(),
        _routes({
          '/api/user/credits': _Reply(401, '{"success":false,"message":"SECRET-BODY-ECHO"}'),
        }),
        secret: 'session=fixture-session',
      );
      expect(s.error, isNotNull);
      expect(s.error, isNot(contains('SECRET-BODY-ECHO')));
    });
  });

  group('ParallelProvider', () {
    test('balance and pending debit in USD', () async {
      final (s, _) = await _run(
        ParallelProvider(),
        _routes({'/refresh-balance': _fixture('parallel_refresh_balance.json')}),
        secret: 'st=fixture-session; soid=fixture-org',
      );
      expect(s.error, isNull);
      expect(s.credits.single.balance, closeTo(123.45, 1e-9));
      expect(s.credits.single.currency, 'USD');
      expect(s.extras['待扣款'], contains('1.50'));
      expect(s.windows, isEmpty);
    });

    test('zero pending debit is omitted', () async {
      final (s, _) = await _run(
        ParallelProvider(),
        _routes({
          '/refresh-balance': jsonEncode({
            'kind': 'ok',
            'data': {'balance': 0, 'pendingDebitBalanceCents': 0},
          }),
        }),
        secret: 'st=fixture-session; soid=fixture-org',
      );
      expect(s.error, isNull);
      expect(s.credits.single.balance, 0);
      expect(s.extras.containsKey('待扣款'), isFalse);
    });
  });

  group('MuseAiProvider', () {
    test('discovers the server action, then parses the maximum plan', () async {
      final p = MuseAiProvider();
      final (s, req) = await _run(
        p,
        _museRespond(_fixture('museai_subscription_maximum.txt')),
        secret: 'hatch_sess=fixture',
      );
      expect(s.error, isNull);
      expect(req.where((r) => r.method == 'POST').single.headers['Next-Action'], _museActionId);
      final w = s.windows.single;
      expect(w.usedPercent, 3);
      expect(w.windowMinutes, 10080);
      expect(w.resetsAt, _epoch(1790634838));
      expect(s.plan, 'Maximum');
      expect(s.extras.values, containsAll(['2.8B tokens left', '1.5B tokens left']));
    });

    test('reuses the cached action id without fetching chunks again', () async {
      final p = MuseAiProvider();
      await _run(
        p,
        _museRespond(_fixture('museai_subscription_maximum.txt')),
        secret: 'hatch_sess=fixture',
      );
      final (s, req) = await _run(
        p,
        _museRespond(_fixture('museai_subscription_maximum.txt')),
        secret: 'hatch_sess=fixture',
      );
      expect(s.error, isNull);
      expect(req.where((r) => r.method == 'GET'), isEmpty);
    });

    test('free plan shows usage without reset or renewal', () async {
      final (s, _) = await _run(
        MuseAiProvider(),
        _museRespond(_fixture('museai_subscription_free.txt')),
        secret: 'hatch_sess=fixture',
      );
      expect(s.error, isNull);
      expect(s.windows.single.usedPercent, 28);
      expect(s.extras.containsKey('续费日期'), isFalse);
      expect(s.plan, 'Muse Free');
    });
  });

  group('StepFunProvider', () {
    test('5-hour and weekly rate windows', () async {
      final (s, _) = await _run(
        StepFunProvider(),
        _routes({
          'QueryStepPlanRateLimit': _fixture('stepfun_rate_window.json'),
          'GetStepPlanStatus': jsonEncode({
            'status': 1,
            'subscription': {'name': 'Plus'},
          }),
        }),
        secret: 'fixture-token',
      );
      expect(s.error, isNull);
      expect(s.session!.usedPercent, 0);
      expect(s.weekly!.usedPercent, allOf(greaterThan(0.2), lessThan(0.3)));
      expect(s.plan, 'Plus');
    });

    test('credit plan maps the credit fraction to one 30-day window', () async {
      final (s, _) = await _run(
        StepFunProvider(),
        _routes({'QueryStepPlanRateLimit': _fixture('stepfun_credit_plan.json')}),
        secret: 'fixture-token',
      );
      expect(s.error, isNull);
      expect(s.windows.single.usedPercent, allOf(greaterThan(3.5), lessThan(3.7)));
      expect(s.windows.single.windowMinutes, 43200);
      expect(s.weekly, isNull);
    });

    test('status != 1 surfaces the API message', () async {
      final (s, _) = await _run(
        StepFunProvider(),
        _routes({
          'QueryStepPlanRateLimit': jsonEncode({'status': 2, 'message': 'token expired'}),
        }),
        secret: 'fixture-token',
      );
      expect(s.error, contains('token expired'));
    });
  });

  group('ZoomMateProvider', () {
    test('cookie bootstrap, credit status and history summary', () async {
      // Cycle is 1799000000..1801000000 (s); 1800000000 is its midpoint, so usage 25% is 25% behind budget.
      final clock = _epoch(1800000000);
      final (s, req) = await _run(
        ZoomMateProvider(),
        _routes({
          'login/': _fixture('zoommate_login.json'),
          'credits/status': _fixture('zoommate_credit_status.json'),
          'credits/history': _zoomHistory(clock),
        }),
        secret: 'session=synthetic',
        now: clock,
      );
      expect(s.error, isNull);
      final w = s.windows.single;
      expect(w.usedPercent, 25);
      expect(w.resetsAt, _epoch(1801000000));
      expect(s.email, 'fixture@example.test');
      expect(s.extras['今日'], '3.5');
      expect(s.extras['近30天'], '3.5');
      expect(s.extras['节奏'], '落后 25%');
      expect(req.first.headers['Cookie'], 'session=synthetic');
    });

    test('manual bearer mode skips the login bootstrap', () async {
      final (s, req) = await _run(
        ZoomMateProvider(),
        _routes({
          'credits/status': _fixture('zoommate_credit_status.json'),
          'credits/history': _zoomHistory(_now),
        }),
        secret: 'Bearer opaque-fixture',
      );
      expect(s.error, isNull);
      expect(s.windows.single.usedPercent, 25);
      expect(req.any((r) => r.url.path.endsWith('login/')), isFalse);
      expect(req.first.headers['Authorization'], 'Bearer opaque-fixture');
    });

    test('history failure keeps the primary window', () async {
      final (s, _) = await _run(
        ZoomMateProvider(),
        _routes({
          'credits/status': _fixture('zoommate_credit_status.json'),
          'credits/history': _Reply(500, ''),
        }),
        secret: 'Bearer opaque-fixture',
      );
      expect(s.error, isNull);
      expect(s.windows.single.usedPercent, 25);
      expect(s.extras.containsKey('今日'), isFalse);
    });

    test('bootstrap parse failure is an error and does not fail over', () async {
      final (s, req) = await _run(
        ZoomMateProvider(),
        _routes({'login/': 'not json'}),
        secret: 'session=synthetic',
      );
      expect(s.error, isNotNull);
      expect(req, hasLength(1));
    });
  });
}
