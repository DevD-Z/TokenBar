import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/src/providers/api/cookie_a_providers.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

final _now = DateTime.utc(2026, 10, 20, 12);

Future<(UsageSnapshot, List<http.Request>)> _run(
  UsageProvider provider, {
  required http.Response Function(http.Request) respond,
  String? secret,
  Map<String, String> options = const {},
  DateTime? now,
}) async {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    return respond(r);
  });
  final account = AccountConfig(
    id: 'a',
    providerId: provider.id,
    label: provider.id,
    sourceType: SourceType.apiKey,
    secret: secret,
    options: options,
  );
  final s = await provider.fetchSafely(
    account,
    FetchContext(client: client, clock: () => now ?? _now),
  );
  return (s, requests);
}

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

RateWindow _window(UsageSnapshot s, String id) => s.window(id)!;

Credits _credit(UsageSnapshot s, String id) => s.credits.firstWhere((c) => c.id == id);

void main() {
  test('exports one provider per id', () {
    expect(cookieAProviders.map((p) => p.id).toList(), [
      'perplexity',
      'manus',
      'ollama',
      'mistral',
      't3chat',
      'qoder',
      'abacus',
      'commandcode',
      'devin',
      'notion',
    ]);
  });

  group('cookie helpers', () {
    test('perplexity bare token is tried under all four session names', () {
      expect(perplexityCookieCandidates('tok'), [
        '__Secure-authjs.session-token=tok',
        'authjs.session-token=tok',
        '__Secure-next-auth.session-token=tok',
        'next-auth.session-token=tok',
      ]);
    });

    test('perplexity header keeps only the matched session cookie, joining chunks', () {
      expect(perplexityCookieCandidates('Cookie: foo=1; authjs.session-token=abc; x=2'), [
        'authjs.session-token=abc',
      ]);
      expect(
        perplexityCookieCandidates(
          '__Secure-authjs.session-token.0=ab; __Secure-authjs.session-token.1=cd',
        ),
        ['__Secure-authjs.session-token=abcd'],
      );
      expect(perplexityCookieCandidates('__Secure-authjs.session-token.1=cd'), isEmpty);
    });

    test('manus reads session_id from a header or a bare value', () {
      expect(manusSessionToken('Session_ID = fixture; other=1'), 'fixture');
      expect(manusSessionToken('abc123'), 'abc123');
      expect(manusSessionToken('other=1'), isNull);
    });
  });

  group('Perplexity', () {
    final fullNow = DateTime.fromMillisecondsSinceEpoch(1740000000 * 1000, isUtc: true);

    test('full response maps recurring credits, bonus and purchased pools', () async {
      final (s, req) = await _run(
        PerplexityProvider(),
        secret: '__Secure-authjs.session-token=tok',
        now: fullNow,
        respond: (_) => http.Response(_fixture('perplexity_full.json'), 200),
      );
      expect(s.error, isNull);
      expect(_window(s, 'perplexity-credits').usedPercent, closeTo(27.5, 1e-9));
      // Reset time follows renewal_date_ts (1743000000), not the grant expiry.
      expect(
        _window(s, 'perplexity-credits').resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1743000000 * 1000, isUtc: true),
      );
      expect(s.extras['积分'], '2750/10000 credits');
      expect(s.plan, 'Max');
      expect(req.single.headers['Cookie'], '__Secure-authjs.session-token=tok');
    });

    test('waterfall attributes usage to recurring, purchased, then promo', () async {
      final (s, _) = await _run(
        PerplexityProvider(),
        secret: 'next-auth.session-token=tok',
        now: fullNow,
        respond: (_) => http.Response(_fixture('perplexity_waterfall.json'), 200),
      );
      expect(s.error, isNull);
      expect(_window(s, 'perplexity-credits').usedPercent, 100);
      expect(_window(s, 'perplexity-bonus').usedPercent, 25);
      expect(_window(s, 'perplexity-purchased').usedPercent, 100);
      expect(s.extras['赠送积分'], startsWith('1000/4000 bonus'));
      // CodexBar: recurring grant >= 5000 cents is "Max".
      expect(s.plan, 'Max');
    });

    test('bare token retries the next session name after 401', () async {
      final (s, req) = await _run(
        PerplexityProvider(),
        secret: 'tok',
        now: fullNow,
        respond: (r) => r.headers['Cookie'] == '__Secure-next-auth.session-token=tok'
            ? http.Response(_fixture('perplexity_full.json'), 200)
            : http.Response('no', 401),
      );
      expect(s.error, isNull);
      expect(req.length, 3);
    });

    test('all candidates rejected reports expired session', () async {
      final (s, _) = await _run(
        PerplexityProvider(),
        secret: 'tok',
        respond: (_) => http.Response('no', 401),
      );
      expect(s.error, contains('已失效'));
    });
  });

  group('Manus', () {
    test('numeric reset dates and string credits (legacy 2001 epoch)', () async {
      final (s, req) = await _run(
        ManusProvider(),
        secret: 'session_id=fixture',
        respond: (_) => http.Response(_fixture('manus_numeric_dates.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.method, 'POST');
      expect(req.single.body, '{}');
      expect(req.single.headers['Authorization'], 'Bearer fixture');
      expect(_window(s, 'manus-monthly').usedPercent, closeTo(70, 1e-9));
      expect(s.extras['月度积分'], 'Total 1,200 • Free 0');
      expect(_window(s, 'manus-daily').usedPercent, 100);
      expect(_window(s, 'manus-daily').resetsAt, DateTime.utc(2001, 1, 1));
      expect(s.extras['每日刷新'], 'Daily Refresh: 0 / 100');
    });

    test('sparse live payload keeps daily and monthly windows', () async {
      final (s, _) = await _run(
        ManusProvider(),
        secret: 'session_id=fixture',
        respond: (_) => http.Response(_fixture('manus_sparse_live.json'), 200),
      );
      expect(s.error, isNull);
      expect(_window(s, 'manus-monthly').usedPercent, closeTo(65.775, 1e-3));
      expect(s.extras['月度积分'], 'Total 2,869 • Free 1,500');
      expect(s.extras['每日刷新'], 'Daily: 0 / 300');
    });

    test('rejected payload is a parse failure', () async {
      final (s, _) = await _run(
        ManusProvider(),
        secret: 'tok',
        respond: (_) => _json({'error': 'unauthorized', 'message': 'session expired'}),
      );
      expect(s.error, contains('缺少积分字段'));
    });
  });

  group('Ollama', () {
    test('API key balance: monthly allowance and purchased credits', () async {
      final (s, req) = await _run(
        OllamaProvider(),
        secret: 'key-123',
        respond: (_) => http.Response(_fixture('ollama_api_balance.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.headers['Authorization'], 'Bearer key-123');
      final w = _window(s, 'ollama-monthly');
      expect(w.usedPercent, closeTo(12.5, 1e-9));
      expect(w.windowMinutes, 43200);
      expect(w.resetsAt, DateTime.utc(2026, 10, 30, 15, 14, 29));
      expect(_credit(s, 'ollama-balance').balance, 18.25);
      expect(_credit(s, 'ollama-included').used, 7.5);
      expect(s.plan, 'API Key');
    });

    test('cookie scrape of monthly dollar usage page', () async {
      final (s, req) = await _run(
        OllamaProvider(),
        secret: SecretBundle.encode({'cookie': 'session=abc'}),
        respond: (_) => http.Response(_fixture('ollama_settings_monthly.html'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.headers['Cookie'], 'session=abc');
      expect(s.plan, 'pro');
      expect(s.email, 'user@example.com');
      final w = _window(s, 'ollama-monthly');
      expect(w.usedPercent, closeTo(12.5, 1e-9));
      expect(w.resetsAt, DateTime.utc(2026, 9, 30, 15, 14, 29));
      expect(w.windowMinutes, 43200);
      expect(s.window(RateWindow.weeklyId), isNull);
    });

    test('cookie scrape of legacy session and weekly usage', () async {
      final (s, _) = await _run(
        OllamaProvider(),
        secret: SecretBundle.encode({'cookie': 'session=abc'}),
        respond: (_) => http.Response(_fixture('ollama_settings_legacy.html'), 200),
      );
      expect(s.error, isNull);
      expect(s.plan, 'free');
      final session = _window(s, RateWindow.sessionId);
      expect(session.usedPercent, closeTo(0.1, 1e-9));
      expect(session.windowMinutes, 300);
      expect(session.resetsAt, DateTime.utc(2026, 1, 30, 18));
      final weekly = _window(s, RateWindow.weeklyId);
      expect(weekly.usedPercent, closeTo(0.7, 1e-9));
      expect(weekly.windowMinutes, 10080);
      expect(weekly.resetsAt, DateTime.utc(2026, 2, 2));
    });

    test('credit wallet page yields balances without a percentage', () async {
      final (s, _) = await _run(
        OllamaProvider(),
        secret: SecretBundle.encode({'cookie': 'session=abc'}),
        respond: (_) => http.Response(_fixture('ollama_settings_credits.html'), 200),
      );
      expect(s.error, isNull);
      expect(s.plan, 'pro');
      expect(s.windows, isEmpty);
      expect(_credit(s, 'ollama-balance').balance, 18.25);
      expect(_credit(s, 'ollama-monthly-credits').used, 4.5);
      expect(s.extras['下次补充'], 'to \$30 in 3 weeks.');
    });

    test('cookie without a session cookie is rejected before any request', () async {
      final (s, req) = await _run(
        OllamaProvider(),
        secret: SecretBundle.encode({'cookie': 'theme=dark'}),
        respond: (_) => http.Response('', 200),
      );
      expect(s.error, contains('会话 Cookie'));
      expect(req, isEmpty);
    });
  });

  group('Mistral', () {
    test('billing totals use billed units x price table; credits add balance', () async {
      final (s, req) = await _run(
        MistralProvider(),
        secret: 'ory_session_abc=1; csrftoken=ct',
        respond: (r) => r.url.path.contains('/api/billing/credits')
            ? http.Response(_fixture('mistral_credits.json'), 200)
            : http.Response(_fixture('mistral_billing_usage_test.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.first.headers['X-CSRFTOKEN'], 'ct');
      final spend = _credit(s, 'mistral-month');
      expect(spend.used, closeTo(0.02536281, 1e-9));
      expect(spend.currency, 'EUR');
      expect(_credit(s, 'mistral-balance').balance, closeTo(13.25, 1e-9));
      expect(_credit(s, 'mistral-balance').currency, 'USD');
      expect(s.extras['输入 Token'], '11241');
      expect(s.extras['输出 Token'], '4097');
      expect(s.extras['模型数'], '2');
    });

    test('cookie without ory_session is rejected before any request', () async {
      final (s, req) = await _run(
        MistralProvider(),
        secret: 'csrftoken=ct',
        respond: (_) => http.Response('', 200),
      );
      expect(s.error, isNotNull);
      expect(req, isEmpty);
    });
  });

  group('T3 Chat', () {
    test('JSONL customer data maps base and overage windows', () async {
      final (s, req) = await _run(
        T3ChatProvider(),
        secret: 'wos-session=abc',
        respond: (_) => http.Response(_fixture('t3chat_customer_data_free.txt'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.headers['Cookie'], 'wos-session=abc');
      expect(req.single.headers['trpc-accept'], 'application/jsonl');
      expect(_window(s, 't3chat-base').usedPercent, 5);
      expect(_window(s, 't3chat-base').windowMinutes, 240);
      expect(_window(s, 't3chat-overage').usedPercent, 65);
      expect(s.plan, 'Free');
    });

    test('Vercel challenge gives actionable hint', () async {
      final (s, _) = await _run(
        T3ChatProvider(),
        secret: 'wos-session=abc',
        respond: (_) =>
            http.Response('challenge', 429, headers: {'x-vercel-mitigated': 'challenge'}),
      );
      expect(s.error, contains('Vercel'));
    });
  });

  group('Qoder', () {
    test('big model credits quota on qoder.com', () async {
      final (s, req) = await _run(
        QoderProvider(),
        secret: 'session=abc',
        respond: (_) => http.Response(_fixture('qoder_big_model_credits.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.url.host, 'qoder.com');
      expect(req.single.headers['Cookie'], 'session=abc');
      expect(_window(s, 'qoder-credits').usedPercent, 25);
      expect(_window(s, 'qoder-credits').resetsAt, DateTime.utc(2024, 9, 1));
      expect(s.extras['用量'], '125 / 500 credits');
    });

    test('site option selects the China domain', () async {
      final (s, req) = await _run(
        QoderProvider(),
        secret: 'session=abc',
        options: {'site': 'qoder.com.cn'},
        respond: (_) => http.Response(_fixture('qoder_big_model_credits.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.url.host, 'qoder.com.cn');
    });
  });

  group('Abacus AI', () {
    test('compute points with billing tier and monthly cycle length', () async {
      final (s, _) = await _run(
        AbacusProvider(),
        secret: 'session=abc',
        respond: (r) => r.url.path.endsWith('_getBillingInfo')
            ? http.Response(_fixture('abacus_billing_info.json'), 200)
            : http.Response(_fixture('abacus_compute_points.json'), 200),
      );
      expect(s.error, isNull);
      final w = _window(s, 'abacus-compute');
      expect(w.usedPercent, 25);
      expect(w.windowMinutes, 44640);
      expect(w.resetsAt, DateTime.utc(2024, 3, 31, 12, 30));
      expect(s.plan, 'Pro');
      expect(s.extras['用量'], '250 / 1,000 credits');
    });

    test('billing failure keeps credits with 30-day fallback window', () async {
      final (s, _) = await _run(
        AbacusProvider(),
        secret: 'session=abc',
        respond: (r) => r.url.path.endsWith('_getBillingInfo')
            ? http.Response('boom', 500)
            : http.Response(_fixture('abacus_compute_points.json'), 200),
      );
      expect(s.error, isNull);
      expect(_window(s, 'abacus-compute').usedPercent, 25);
      expect(_window(s, 'abacus-compute').windowMinutes, 43200);
      expect(s.plan, isNull);
    });
  });

  group('Command Code', () {
    final credits = {
      'credits': {'monthlyCredits': 3.2, 'purchasedCredits': 5, 'monthlyCreditsGranted': 20},
      'windowLimits': {
        'fiveHour': {'cap': 100, 'used': 25, 'resetAt': 1790000000},
      },
    };
    final subs = {
      'success': true,
      'data': {'planId': 'pro', 'status': 'active', 'currentPeriodEnd': '2026-11-20T00:00:00Z'},
    };

    test('API key uses the /alpha routes with bearer auth', () async {
      final (s, req) = await _run(
        CommandCodeProvider(),
        secret: 'user_key',
        respond: (r) => _json(r.url.path.endsWith('/billing/credits') ? credits : subs),
      );
      expect(s.error, isNull);
      expect(
        req.map((r) => r.url.path),
        containsAll(['/alpha/billing/credits', '/alpha/billing/subscriptions']),
      );
      expect(req.first.headers['Authorization'], 'Bearer user_key');
      expect(_window(s, RateWindow.sessionId).usedPercent, 25);
      expect(_window(s, RateWindow.sessionId).windowMinutes, 300);
      expect(_window(s, 'commandcode-monthly').usedPercent, closeTo(84, 1e-9));
      expect(s.plan, 'pro · \$16.80 of \$20.00 · + \$5.00 credits');
    });

    test(
      'cookie uses the /internal routes; failed subscription only drops the plan name',
      () async {
        final (s, req) = await _run(
          CommandCodeProvider(),
          options: const {},
          secret: SecretBundle.encode({'cookie': 'better-auth=abc'}),
          respond: (r) =>
              r.url.path.endsWith('/billing/credits') ? _json(credits) : http.Response('no', 500),
        );
        expect(s.error, isNull);
        expect(req.first.url.path, '/internal/billing/credits');
        expect(req.first.headers['Cookie'], 'better-auth=abc');
        expect(_window(s, 'commandcode-monthly').usedPercent, closeTo(84, 1e-9));
        expect(s.plan, '\$16.80 of \$20.00 · + \$5.00 credits');
        expect(s.extras.containsKey('订阅状态'), isFalse);
      },
    );
  });

  group('Devin', () {
    const quota = {
      'plan_name': 'pro',
      'daily_percentage': 0.12,
      'weekly_percentage': 42,
      'daily_reset_at': '2026-06-11T00:00:00-08:00',
      'weekly_reset_at': '2026-06-14T00:00:00-08:00',
      'hide_daily_quota': false,
      'overage_balance': 70.87,
    };

    test('bearer token with internal org id maps daily, weekly and overage', () async {
      final (s, req) = await _run(
        DevinProvider(),
        secret: 'auth1_token',
        options: {'organization': 'org_GQ6LhcfkW1TSinM6'},
        respond: (_) => _json(quota),
      );
      expect(s.error, isNull);
      expect(req.first.url.path, '/api/org_GQ6LhcfkW1TSinM6/billing/quota/usage');
      expect(req.first.headers['x-cog-org-id'], 'org_GQ6LhcfkW1TSinM6');
      expect(req.first.headers['Authorization'], 'Bearer auth1_token');
      expect(_window(s, 'devin-daily').usedPercent, 12);
      expect(_window(s, 'devin-daily').resetsAt, DateTime.utc(2026, 6, 11, 8));
      expect(_window(s, 'devin-weekly').usedPercent, 42);
      expect(_window(s, 'devin-weekly').resetsAt, DateTime.utc(2026, 6, 14, 8));
      expect(_credit(s, 'devin-overage').balance, 70.87);
      expect(s.plan, 'Pro');
    });

    test('hidden daily quota is omitted', () async {
      final (s, _) = await _run(
        DevinProvider(),
        secret: 'auth1_token',
        options: {'organization': 'org_GQ6LhcfkW1TSinM6'},
        respond: (_) => _json({...quota, 'hide_daily_quota': true}),
      );
      expect(s.error, isNull);
      expect(s.window('devin-daily'), isNull);
      expect(_window(s, 'devin-weekly').usedPercent, 42);
    });

    test('401 with missing organization detail asks for the org id', () async {
      final (s, _) = await _run(
        DevinProvider(),
        secret: 'auth1_token',
        options: {'organization': 'org_GQ6LhcfkW1TSinM6'},
        respond: (_) => _json({'detail': 'No organizations found for auth1 user'}, 401),
      );
      expect(s.error, contains('组织'));
    });
  });

  group('Notion AI', () {
    const workspace = '0123456789abcdef0123456789abcdef';

    test('pinned workspace reads rolling and billing-period allowances', () async {
      final (s, req) = await _run(
        NotionProvider(),
        secret: 'token_v2=abc',
        options: {'workspaceId': workspace},
        respond: (_) => http.Response(_fixture('notion_credit_rate_limit_status.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.length, 1);
      expect(req.single.url.path, '/api/v3/getCreditRateLimitStatus');
      expect(jsonDecode(req.single.body)['spaceId'], '01234567-89ab-cdef-0123-456789abcdef');
      expect(req.single.headers['Cookie'], 'token_v2=abc');
      final primary = _window(s, 'notion-rolling');
      expect(primary.usedPercent, 25);
      expect(primary.windowMinutes, 360);
      expect(primary.resetsAt, _now.add(const Duration(seconds: 3600)));
      final billing = _window(s, 'notion-billing');
      expect(billing.usedPercent, 18);
      expect(billing.windowMinutes, 43200);
      expect(billing.resetsAt, DateTime.fromMillisecondsSinceEpoch(1788000000000, isUtc: true));
    });

    test('bare token value is wrapped as token_v2', () async {
      final (s, req) = await _run(
        NotionProvider(),
        secret: 'rawvalue',
        options: {'workspaceId': workspace},
        respond: (_) => http.Response(_fixture('notion_credit_rate_limit_status.json'), 200),
      );
      expect(s.error, isNull);
      expect(req.single.headers['Cookie'], 'token_v2=rawvalue');
    });

    test('not_applicable workspace explains plan requirement', () async {
      final (s, _) = await _run(
        NotionProvider(),
        secret: 'token_v2=abc',
        options: {'workspaceId': workspace},
        respond: (_) =>
            _json({'status': 'not_applicable', 'window': null, 'billingPeriodWindow': null}),
      );
      expect(s.error, contains('不提供'));
    });
  });
}
