import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/src/providers/api/plugin_misc_providers.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Routes keyed by exact URL path: a String is a 200 JSON body, an int a bare status.
Future<(UsageSnapshot, List<http.Request>)> _run(
  UsageProvider provider,
  Map<String, Object> routes, {
  String? secret,
  Map<String, String> options = const {},
}) async {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    final route = routes[r.url.path];
    if (route is int) return http.Response('{}', route);
    if (route is String) {
      return http.Response.bytes(
        utf8.encode(route),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not found', 404);
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
    FetchContext(client: client, clock: () => DateTime.utc(2026, 10, 20, 12)),
  );
  return (s, requests);
}

Credits _credit(UsageSnapshot s, String id) => s.credits.firstWhere((c) => c.id == id);

void main() {
  group('deepgram', () {
    test('configured project sums breakdown rows with token auth', () async {
      final (s, req) = await _run(
        DeepgramProvider(),
        {'/v1/projects/project-123/usage/breakdown': _fixture('deepgram_usage_breakdown.json')},
        secret: 'dg-test',
        options: {'projectId': 'project-123'},
      );
      expect(s.error, isNull);
      expect(req.single.headers['Authorization'], 'Token dg-test');
      expect(s.extras['请求数'], '373,400');
      expect(s.extras['音频时长'], '1,622.0 小时（计费 1,625.2 小时）');
      expect(s.extras['Agent 时长'], '41.3 小时');
      expect(s.extras['Token 数'], '1,540');
      expect(s.extras['TTS 字符'], '9,158,866');
      expect(s.extras['统计周期'], '2025-01-16 至 2025-01-23');
      expect(s.extras['项目'], 'project-123');
      expect(s.windows, isEmpty);
    });

    test('without a project ID every visible project is aggregated', () async {
      final (s, req) = await _run(DeepgramProvider(), {
        '/v1/projects': _fixture('deepgram_projects.json'),
        '/v1/projects/project-a/usage/breakdown': '{"start":"2025-01-16","end":"2025-01-23","results":[{"hours":1,"total_hours":2,"requests":3}]}',
        '/v1/projects/project-b/usage/breakdown': '{"start":"2025-01-17","end":"2025-01-24","results":[{"hours":4,"total_hours":5,"requests":6}]}',
      }, secret: 'dg-test');
      expect(s.error, isNull);
      expect(req.map((r) => r.url.path).toList(), [
        '/v1/projects',
        '/v1/projects/project-a/usage/breakdown',
        '/v1/projects/project-b/usage/breakdown',
      ]);
      expect(s.extras['请求数'], '9');
      expect(s.extras['音频时长'], '5 小时（计费 7 小时）');
      expect(s.extras['统计周期'], '2025-01-16 至 2025-01-24');
      expect(s.extras['项目'], 'Alpha、Beta');
    });

    test('HTTP 401 surfaces as a visible error', () async {
      final (s, _) = await _run(
        DeepgramProvider(),
        {'/v1/projects/project-123/usage/breakdown': 401},
        secret: 'dg-test',
        options: {'projectId': 'project-123'},
      );
      expect(s.error, contains('Deepgram'));
      expect(s.errorHint, isNotNull);
    });

    test('plain HTTP override is refused before any request', () async {
      final (s, req) = await _run(
        DeepgramProvider(),
        {},
        secret: 'dg-test',
        options: {'projectId': 'project-123', 'baseUrl': 'http://api.deepgram.com/v1'},
      );
      expect(s.error, isNotNull);
      expect(req, isEmpty);
    });
  });

  group('nous', () {
    test('subscription, top-up and total credits stay separate', () async {
      final (s, req) = await _run(NousProvider(), {
        '/api/oauth/account': _fixture('nous_account.json'),
      }, secret: 'fixture-token');
      expect(s.error, isNull);
      expect(req.single.url.toString(), 'https://portal.nousresearch.com/api/oauth/account');
      expect(req.single.headers['Authorization'], 'Bearer fixture-token');
      final monthly = s.window('nous-monthly');
      expect(monthly?.usedPercent, 75);
      expect(monthly?.resetsAt, DateTime.utc(2026, 10, 12, 4, 29));
      expect(s.plan, 'Ultra');
      expect(s.email, 'dev@example.com');
      expect(s.extras['组织'], 'Example account');
      expect(_credit(s, 'nous-subscription').balance, 55);
      expect(_credit(s, 'nous-topup').balance, 19.25);
      expect(_credit(s, 'nous-total').balance, 74.25);
      expect(s.credits.any((c) => c.id == 'nous-rollover'), isFalse);
    });

    test('decimal strings are accepted and exhausted balances stay visible', () async {
      final (s, _) = await _run(NousProvider(), {
        '/api/oauth/account':
            '{"subscription":{"monthly_credits":"22","credits_remaining":"0","rollover_credits":"1.5"},'
            '"purchased_credits_remaining":"3.25"}',
      }, secret: 'fixture-token');
      expect(s.error, isNull);
      expect(s.window('nous-monthly')?.usedPercent, 100);
      expect(_credit(s, 'nous-rollover').balance, 1.5);
      expect(_credit(s, 'nous-topup').balance, 3.25);
    });

    test('expired token asks the user to sign in to Hermes again', () async {
      final (s, _) = await _run(NousProvider(), {
        '/api/oauth/account': 401,
      }, secret: 'fixture-token');
      expect(s.error, contains('登录已过期'));
      expect(s.errorHint, contains('hermes'));
    });

    test('malformed or empty account responses fail instead of showing zero', () async {
      for (final body in [
        '{"purchased_credits_remaining":"NaN"}',
        '{"purchased_credits_remaining":true}',
        '{"purchased_credits_remaining":""}',
        '{"purchased_credits_remaining":[]}',
        '{"subscription":{}}',
        '{}',
        'null',
        '[]',
      ]) {
        final (s, _) = await _run(NousProvider(), {
          '/api/oauth/account': body,
        }, secret: 'fixture-token');
        expect(s.error, isNotNull, reason: body);
        expect(s.windows, isEmpty, reason: body);
      }
    });
  });

  group('llmman', () {
    test('loaded weights fill the memory bar and summarize the daemon', () async {
      final (s, req) = await _run(
        LlmmanProvider(),
        {
          '/llmman/node': _fixture('llmman_node.json'),
          '/api/version': _fixture('llmman_version.json'),
        },
        secret: 'fixture-key',
        options: {'baseUrl': 'http://127.0.0.1:17434'},
      );
      expect(s.error, isNull);
      expect(req.first.headers['Authorization'], 'Bearer fixture-key');
      expect(s.window('llmman-memory')?.usedPercent, 25);
      expect(s.plan, 'API Key');
      expect(s.extras['已加载'], '2 个 · 10.0 GB');
      expect(s.extras['已存储'], '3 个 · 10.5 GB');
      expect(s.extras['内存'], '10.0 GB / 40.0 GB');
      expect(s.extras['版本'], '0.9.0');
      expect(s.extras['加载中的模型'], 'fixture/large:Q4_K_M 8.0 GB、fixture/small:Q4_K_M 2.0 GB');
    });

    test('open daemon needs no key and an idle daemon is still displayable', () async {
      final (s, req) = await _run(LlmmanProvider(), {
        '/llmman/node': '{"memory":0,"loaded":{},"stored":{}}',
      });
      expect(s.error, isNull);
      expect(req.first.headers.containsKey('Authorization'), isFalse);
      expect(s.windows, isEmpty);
      expect(s.plan, '本机守护进程');
      expect(s.extras['已加载'], '0 个 · 0 B');
    });

    test('malformed node responses are parse failures', () async {
      for (final body in [
        'not json',
        '[]',
        '{"memory":-1,"loaded":{},"stored":{}}',
        '{"memory":1,"loaded":[],"stored":{}}',
        '{"memory":1,"loaded":{"a":"1"},"stored":{}}',
        '{"memory":1,"loaded":{}}',
      ]) {
        final (s, _) = await _run(LlmmanProvider(), {'/llmman/node': body});
        expect(s.error, isNotNull, reason: body);
      }
    });

    test('401 without a key asks for one; with a key it is rejected', () async {
      final (noKey, _) = await _run(LlmmanProvider(), {'/llmman/node': 401});
      expect(noKey.error, contains('需要 API Key'));
      final (withKey, _) = await _run(LlmmanProvider(), {'/llmman/node': 401}, secret: 'bad-key');
      expect(withKey.error, contains('拒绝了 API Key'));
    });

    test('unreachable daemon names the address', () async {
      final client = MockClient((_) async => throw http.ClientException('connection refused'));
      final s = await LlmmanProvider().fetchSafely(
        AccountConfig(
          id: 'a',
          providerId: 'llmman',
          label: 'llmman',
          sourceType: SourceType.apiKey,
        ),
        FetchContext(client: client, clock: () => DateTime.utc(2026, 10, 20, 12)),
      );
      expect(s.error, 'llmman 无法连接: http://127.0.0.1:17434');
      expect(s.errorHint, contains('llmman serve'));
    });

    test('daemon addresses normalize and unsafe ones are rejected', () {
      expect(llmmanBaseUrl('127.0.0.1:18000'), 'http://127.0.0.1:18000');
      expect(llmmanBaseUrl('localhost'), 'http://localhost:17434');
      expect(llmmanBaseUrl('http://127.0.0.1:17434/v1/'), 'http://127.0.0.1:17434');
      expect(llmmanBaseUrl('0.0.0.0:18000'), 'http://127.0.0.1:18000');
      expect(llmmanBaseUrl('https://llmman.example.com'), 'https://llmman.example.com');
      expect(llmmanBaseUrl('http://192.168.1.10:17434'), 'http://192.168.1.10:17434');
      for (final bad in [
        'http://llmman.example.com',
        'http://u:p@127.0.0.1:17434',
        'http://127.0.0.1:17434?probe=1',
        'http://127.0.0.1:17434#x',
      ]) {
        expect(() => llmmanBaseUrl(bad), throwsA(isA<ProviderException>()), reason: bad);
      }
    });
  });

  group('langdock', () {
    String langdockBody(String plan) =>
        '[{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":$plan}}}}]';

    test('personal limits map session and weekly windows from the pasted cookie', () async {
      final (s, req) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage': _fixture('langdock_personal_usage.json'),
      }, secret: 'synthetic-account-a');
      expect(s.error, isNull);
      final request = req.single;
      expect(request.headers['Cookie'], 'auth_token=synthetic-account-a');
      expect(request.url.queryParameters['batch'], '1');
      expect(
        request.url.queryParameters['input'],
        '{"0":{"json":null,"meta":{"values":["undefined"],"v":1}}}',
      );
      expect(s.session?.usedPercent, 12.5);
      expect(s.session?.windowMinutes, 300);
      expect(s.session?.resetsAt, DateTime.utc(2026, 9, 25, 12, 0, 0, 123));
      expect(s.weekly?.usedPercent, 104.2);
      expect(s.weekly?.windowMinutes, 10080);
      expect(s.weekly?.resetsAt, DateTime.utc(2026, 9, 28, 12));
    });

    test('a full Cookie header is sent as-is', () async {
      final (s, req) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage': _fixture('langdock_personal_usage.json'),
      }, secret: 'Cookie: other=1; auth_token=synthetic-account-a');
      expect(s.error, isNull);
      expect(req.single.headers['Cookie'], 'other=1; auth_token=synthetic-account-a');
    });

    test('a response without included limits is a result, not an error', () async {
      final (s, _) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage':
            '[{"result":{"data":{"json":{"hasIncludedUsageLimits":false}}}}]',
      }, secret: 'synthetic-account-a');
      expect(s.error, isNull);
      expect(s.windows, isEmpty);
      expect(s.extras['包含额度'], '暂无可用的包含用量限制');
    });

    test('weekly-only plans keep the weekly window and omit the session window', () async {
      final (s, _) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage': langdockBody(
          '{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}',
        ),
      }, secret: 'synthetic-account-a');
      expect(s.error, isNull);
      expect(s.session, isNull);
      expect(s.weekly?.usedPercent, 0);
      expect(s.weekly?.resetsAt, isNull);
    });

    test('expired sessions and tRPC error codes are classified', () async {
      final (expired, _) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage': 401,
      }, secret: 'synthetic-account-a');
      expect(expired.error, contains('登录已失效'));
      final (forbidden, _) = await _run(LangdockProvider(), {
        '/api/trpc/usageSettings.getPersonalUsage':
            '[{"error":{"json":{"data":{"code":"FORBIDDEN"}}}}]',
      }, secret: 'synthetic-account-a');
      expect(forbidden.error, contains('拒绝访问'));
    });

    test('malformed envelopes, percentages and dates fail instead of fabricating zero', () async {
      for (final body in [
        '[]',
        '[{},{}]',
        '[{"result":{"data":null}}]',
        '[{"error":{}}]',
        '[{"error":{"json":{"data":{"code":403}}}}]',
        langdockBody('{"sessionUsageLimitsEnabled":true,"weeklyUsagePercent":4}'),
        langdockBody(
          '{"sessionUsageLimitsEnabled":true,"sessionUsagePercent":"5","weeklyUsagePercent":4}',
        ),
        langdockBody('{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":"4"}'),
        langdockBody(
          '{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":4,"weeklyResetsAt":"tomorrow"}',
        ),
      ]) {
        final (s, _) = await _run(LangdockProvider(), {
          '/api/trpc/usageSettings.getPersonalUsage': body,
        }, secret: 'synthetic-account-a');
        expect(s.error, isNotNull, reason: body);
        expect(s.windows, isEmpty, reason: body);
      }
    });
  });

  group('zed', () {
    test('browser billing maps spend, spend cap and edit predictions', () async {
      final (s, req) = await _run(ZedProvider(), {
        '/frontend/billing/usage': _fixture('zed_billing_pro.json'),
      }, secret: 'fixture-session');
      expect(s.error, isNull);
      expect(req.single.url.toString(), 'https://cloud.zed.dev/frontend/billing/usage');
      expect(req.single.headers['Cookie'], 'zed.session=fixture-session');
      expect(_credit(s, 'zed-spend').used, 2.5);
      expect(_credit(s, 'zed-spend').limit, 10);
      expect(_credit(s, 'zed-spend').currency, 'USD');
      expect(s.window('zed-predictions')?.usedPercent, 12);
      expect(s.extras['编辑预测'], '12 / 100');
      expect(s.plan, 'Zed Pro');
    });

    test('unlimited predictions and a missing spend cap do not invent limits', () async {
      final fixture = _fixture('zed_billing_pro.json')
          .replaceAll(',"limit_in_cents":1000', '')
          .replaceAll('"limit":100', '"limit":null');
      final (s, _) = await _run(ZedProvider(), {
        '/frontend/billing/usage': fixture,
      }, secret: 'fixture-session');
      expect(s.error, isNull);
      expect(s.windows, isEmpty);
      expect(s.extras['编辑预测'], '不限量');
      expect(_credit(s, 'zed-spend').used, 2.5);
      expect(_credit(s, 'zed-spend').limit, isNull);
    });

    test('expired sessions are reported as expired', () async {
      final (s, _) = await _run(ZedProvider(), {
        '/frontend/billing/usage': 403,
      }, secret: 'fixture-session');
      expect(s.error, contains('会话已过期'));
    });

    test('a cookie without zed.session is rejected before any request', () async {
      final (s, req) = await _run(ZedProvider(), {}, secret: 'other=1');
      expect(s.error, contains('zed.session'));
      expect(req, isEmpty);
    });

    test('drifted or unsafe billing values fail without publishing totals', () async {
      final billing = _fixture('zed_billing_pro.json');
      for (final body in [
        '{}',
        '[]',
        '<html>login</html>',
        billing.replaceFirst('250', '-1'),
        billing.replaceFirst('250', 'true'),
        billing.replaceFirst('250', '9007199254740992'),
        billing.replaceFirst('1000', '-1'),
        billing.replaceFirst('"plan":"zed_pro"', '"plan":{}'),
      ]) {
        final (s, _) = await _run(ZedProvider(), {
          '/frontend/billing/usage': body,
        }, secret: 'fixture-session');
        expect(s.error, isNotNull, reason: body);
        expect(s.credits, isEmpty, reason: body);
      }
    });
  });
}
