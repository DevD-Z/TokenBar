import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/src/providers/api/local_auth_b_providers.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

final _now = DateTime.utc(2026, 10, 20, 12);

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _respond(Object v) => switch (v) {
  int status => http.Response('{}', status),
  Uint8List bytes => http.Response.bytes(bytes, 200),
  String body => http.Response.bytes(
    utf8.encode(body),
    200,
    headers: {'content-type': 'application/json'},
  ),
  _ => throw ArgumentError('unsupported route value'),
};

/// Runs [provider] against canned responses keyed by URL substring.
Future<(UsageSnapshot, List<http.Request>)> _fetch(
  UsageProvider provider,
  AccountConfig account,
  Map<String, Object> routes,
) async {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    for (final e in routes.entries) {
      if (r.url.toString().contains(e.key)) return _respond(e.value);
    }
    return http.Response('not found', 404);
  });
  final s = await provider.fetchSafely(account, FetchContext(client: client, clock: () => _now));
  return (s, requests);
}

AccountConfig _account(
  String providerId, {
  SourceType source = SourceType.apiKey,
  String? secret,
  Map<String, String> options = const {},
}) => AccountConfig(
  id: 'a',
  providerId: providerId,
  label: providerId,
  sourceType: source,
  secret: secret,
  options: options,
);

RateWindow _window(UsageSnapshot s, String id) => s.windows.firstWhere((w) => w.id == id);

Credits _credit(UsageSnapshot s, String id) => s.credits.firstWhere((c) => c.id == id);

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _lenField(int field, List<int> payload) => [
  ..._varint((field << 3) | 2),
  ..._varint(payload.length),
  ...payload,
];

// Tags are varints too: field 17 (tag 136) needs two bytes.
List<int> _varintField(int field, int value) => [..._varint(field << 3), ..._varint(value)];

/// GetPlanStatus response: plan "Pro", daily 80% left, weekly 50% left.
Uint8List _planStatusResponse() {
  final planInfo = _lenField(2, utf8.encode('Pro'));
  final status = [
    ..._lenField(1, planInfo),
    ..._lenField(3, _varintField(1, 1790000000)),
    ..._varintField(14, 80),
    ..._varintField(15, 50),
    ..._varintField(17, 1790000000),
    ..._varintField(18, 1790500000),
  ];
  return Uint8List.fromList(_lenField(1, status));
}

void main() {
  group('Codebuff', () {
    test('API key: usage POST, credits window and balance', () async {
      final (s, req) = await _fetch(CodebuffProvider(), _account('codebuff', secret: 'cb-test'), {
        '/api/v1/usage': _fixture('codebuff_usage.json'),
      });
      expect(s.error, isNull);
      expect(req.single.method, 'POST');
      expect(req.single.headers['Authorization'], 'Bearer cb-test');
      expect(req.single.body, contains('codexbar-usage'));
      final credits = _window(s, 'codebuff-credits');
      expect(credits.usedPercent, closeTo(25, 1e-9));
      expect(credits.resetsAt, DateTime.utc(2026, 5, 1));
      expect(_credit(s, 'codebuff-remaining').balance, 3750);
      expect(s.source, 'api-key');
      expect(s.plan, isNull);
    });

    test('subscription: tier and weekly window', () {
      final sub = parseCodebuffSubscription(
        jsonDecode(_fixture('codebuff_subscription.json')) as Map<String, Object?>,
      );
      expect(sub.tier, 'pro');
      expect(sub.email, 'user@example.com');
      final weekly = codebuffWeeklyWindow(sub)!;
      expect(weekly.id, RateWindow.weeklyId);
      expect(weekly.usedPercent, closeTo(30, 1e-9));
      expect(weekly.windowMinutes, 10080);
      expect(weekly.resetsAt, DateTime.utc(2026, 5, 8));
    });

    test('auth token: nested default profile first, then top-level', () {
      expect(parseCodebuffAuthToken('{"default":{"authToken":"tok"}}'), 'tok');
      expect(parseCodebuffAuthToken('{"authToken":"top"}'), 'top');
      expect(parseCodebuffAuthToken('{}'), isNull);
    });

    test('expired key surfaces HTTP status', () async {
      final (s, _) = await _fetch(CodebuffProvider(), _account('codebuff', secret: 'cb-test'), {
        '/api/v1/usage': 401,
      });
      expect(s.error, contains('401'));
    });
  });

  group('ClinePass', () {
    test('API key: bearer header and three plan windows', () async {
      final (s, req) = await _fetch(
        ClinePassProvider(),
        _account('clinepass', secret: 'test-key'),
        {'/usage-limits': _fixture('clinepass_usage_limits.json')},
      );
      expect(s.error, isNull);
      expect(req.single.url.toString(), 'https://api.cline.bot/api/v1/users/me/plan/usage-limits');
      expect(req.single.headers['Authorization'], 'Bearer test-key');

      final session = _window(s, RateWindow.sessionId);
      expect(session.usedPercent, 12.5);
      expect(session.windowMinutes, 300);
      expect(session.resetsAt, DateTime.utc(2026, 7, 16, 10, 20, 30));

      final weekly = _window(s, RateWindow.weeklyId);
      expect(weekly.usedPercent, 34);
      expect(weekly.windowMinutes, 10080);

      final monthly = _window(s, 'clinepass-monthly');
      expect(monthly.usedPercent, 56.75);
      expect(monthly.windowMinutes, 43200);
      expect(monthly.resetsAt, DateTime.utc(2026, 8, 1));
    });

    test('unknown limit types are ignored and null resets stay null', () async {
      const body =
          '{"success":true,"data":{"limits":[{"type":"experimental_pool","percentUsed":99},'
          '{"type":"monthly","percentUsed":1,"resetsAt":null}]}}';
      final (s, _) = await _fetch(ClinePassProvider(), _account('clinepass', secret: 'k'), {
        '/usage-limits': body,
      });
      expect(s.error, isNull);
      expect(s.windows, hasLength(1));
      expect(s.windows.single.id, 'clinepass-monthly');
      expect(s.windows.single.resetsAt, isNull);
    });

    test('unsuccessful payload is a parse failure', () {
      expect(
        () => parseClinePassUsageLimits({'success': false, 'data': {}}),
        throwsA(isA<ProviderException>()),
      );
    });

    test('local Cline settings: OAuth token gets workos prefix, apiKey fallback', () {
      final oauth = parseClinePassSettings(
        '{"providers":{"cline":{"settings":{"auth":{"accessToken":"abc"}}}}}',
      )!;
      expect(oauth.token, 'workos:abc');
      expect(oauth.isOAuth, isTrue);

      final key = parseClinePassSettings('{"providers":{"cline":{"settings":{"apiKey":"k1"}}}}')!;
      expect(key.token, 'k1');
      expect(key.isOAuth, isFalse);

      final nested = parseClinePassSettings(
        '{"providers":{"cline":{"settings":{"auth":{"apiKey":"k2"}}}}}',
      )!;
      expect(nested.token, 'k2');

      expect(parseClinePassSettings('not json'), isNull);
    });
  });

  group('Augment', () {
    test('cookie: credits, billing cycle and plan from subscription', () async {
      final (s, req) = await _fetch(
        AugmentProvider(),
        _account('augment', secret: 'Cookie: session=abc; x=1'),
        {
          '/api/credits': _fixture('augment_credits.json'),
          '/api/subscription': '{"planName":"Indie","billingPeriodEnd":"2026-11-01T00:00:00Z","email":"u@example.com"}',
        },
      );
      expect(s.error, isNull);
      expect(req.first.headers['Cookie'], 'session=abc; x=1');
      final cycle = _window(s, 'augment-cycle');
      expect(cycle.usedPercent, closeTo(10, 1e-9));
      expect(cycle.resetsAt, DateTime.utc(2026, 11, 1));
      final spend = _credit(s, 'augment-credits');
      expect(spend.used, 10);
      expect(spend.limit, 100);
      expect(s.plan, 'Indie');
      expect(s.email, 'u@example.com');
    });

    test('limit falls back to remaining + consumed; subscription failure is ignored', () async {
      final (s, _) = await _fetch(AugmentProvider(), _account('augment', secret: 'session=abc'), {
        '/api/credits': '{"usageUnitsRemaining":15,"usageUnitsConsumedThisBillingCycle":10}',
        '/api/subscription': 403,
      });
      expect(s.error, isNull);
      expect(_window(s, 'augment-cycle').usedPercent, closeTo(40, 1e-9));
      expect(_credit(s, 'augment-credits').limit, 25);
    });
  });

  group('Factory', () {
    const authJson =
        '{"organization":{"name":"Acme","subscription":{"factoryTier":"enterprise",'
        '"orbSubscription":{"plan":{"name":"Team"}}}},"userProfile":{"id":"u1","email":"a@b.c"}}';

    test('API key: token-rate-limit billing windows win over legacy usage', () async {
      final (s, req) = await _fetch(FactoryProvider(), _account('factory', secret: 'fk-test'), {
        '/api/app/auth/me': authJson,
        '/api/billing/limits': _fixture('factory_billing_limits.json'),
        '/api/organization/subscription/usage': 500,
      });
      expect(s.error, isNull);
      expect(req.first.url.host, 'api.factory.ai');
      expect(req.first.headers['Authorization'], 'Bearer fk-test');
      expect(req.first.headers.containsKey('Cookie'), isFalse);
      expect(req, hasLength(2));

      final five = _window(s, RateWindow.sessionId);
      expect(five.usedPercent, 12);
      expect(five.windowMinutes, 300);
      expect(five.resetsAt, _now.add(const Duration(hours: 1)));
      expect(_window(s, RateWindow.weeklyId).usedPercent, 34);
      expect(_window(s, RateWindow.weeklyId).windowMinutes, 10080);
      expect(_window(s, 'factory-monthly').usedPercent, 56);
      expect(_window(s, 'factory-monthly').windowMinutes, isNull);

      expect(s.plan, 'Factory Enterprise · Team');
      expect(s.email, 'a@b.c');
      expect(s.source, 'api-key');
    });

    test('cookie: legacy usage ratio, premium pool skipped when it has no allowance', () async {
      const usage =
          '{"usage":{"startDate":1790000000000,"endDate":1792592000000,'
          '"standard":{"userTokens":250,"totalAllowance":1000,"usedRatio":0.25},'
          '"premium":{"userTokens":0,"totalAllowance":0}}}';
      final (s, req) = await _fetch(
        FactoryProvider(),
        _account('factory', secret: 'session=abc; other=1'),
        {
          '/api/app/auth/me': authJson,
          '/api/billing/limits': '{"usesTokenRateLimitsBilling":false}',
          '/api/organization/subscription/usage': usage,
        },
      );
      expect(s.error, isNull);
      expect(req.first.headers['Cookie'], 'session=abc; other=1');
      expect(req.first.headers.containsKey('Authorization'), isFalse);
      final usageReq = req.last;
      expect(usageReq.url.queryParameters, {'useCache': 'true', 'userId': 'u1'});

      expect(s.windows, hasLength(1));
      expect(s.windows.single.id, 'factory-standard');
      expect(s.windows.single.usedPercent, closeTo(25, 1e-9));
      expect(
        s.windows.single.resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1792592000000, isUtc: true),
      );
      expect(s.extras['标准 Tokens 已用'], '250 / 1000');
      expect(s.source, 'web');
    });

    test('dotenv key, cookie detection', () {
      expect(
        parseFactoryApiKeyFromDotEnv('# note\nexport FACTORY_API_KEY="fk-1"\nOTHER=1\n'),
        'fk-1',
      );
      expect(parseFactoryApiKeyFromDotEnv('OTHER=1'), isNull);
      expect(looksLikeFactoryCookie('fk-abc'), isFalse);
      expect(looksLikeFactoryCookie('session=abc; x=1'), isTrue);
      expect(looksLikeFactoryCookie('Cookie: a=1'), isTrue);
    });
  });

  group('OpenCode Go', () {
    test('API key: rolling, weekly and monthly meters', () async {
      const body =
          '{"usage":{"rolling":{"usagePercent":42.5,"resetInSec":3600},'
          '"weekly":{"usagePercent":10,"resetInSec":86400},'
          '"monthly":{"usagePercent":5,"resetInSec":2592000}}}';
      final (s, req) = await _fetch(
        OpenCodeGoProvider(),
        _account('opencodego', secret: 'oc-key'),
        {'/zen/go/v1/usage': body},
      );
      expect(s.error, isNull);
      expect(req.single.headers['Authorization'], 'Bearer oc-key');
      expect(_window(s, RateWindow.sessionId).usedPercent, 42.5);
      expect(_window(s, RateWindow.sessionId).resetsAt, _now.add(const Duration(hours: 1)));
      expect(_window(s, RateWindow.weeklyId).windowMinutes, 10080);
      expect(_window(s, 'opencodego-monthly').usedPercent, 5);
      expect(_window(s, 'opencodego-monthly').windowMinutes, 43200);
    });

    test('cookie console: workspace header and fractional console meter', () async {
      const console =
          '{"access":{"endsAt":"2026-11-01T00:00:00Z","meters":{'
          '"fiveHour":{"usagePercent":0.25,"resetsAt":"2026-10-20T15:00:00Z"},'
          '"week":{"usagePercent":30,"resetInSec":3600}}}}';
      final (s, req) = await _fetch(
        OpenCodeGoProvider(),
        _account(
          'opencodego',
          secret: SecretBundle.encode({'cookie': 'Cookie: sid=1'}),
          options: {'workspaceId': 'wrk_123'},
        ),
        {'/console/api/go/status': console},
      );
      expect(s.error, isNull);
      expect(req.single.headers['x-org-id'], 'wrk_123');
      expect(req.single.headers['Cookie'], 'sid=1');
      expect(_window(s, RateWindow.sessionId).usedPercent, closeTo(25, 1e-9));
      expect(_window(s, RateWindow.sessionId).resetsAt, DateTime.utc(2026, 10, 20, 15));
      expect(_window(s, RateWindow.weeklyId).usedPercent, 30);
      expect(s.windows.any((w) => w.id == 'opencodego-monthly'), isFalse);
      expect(s.source, 'web');
    });

    test('manual input needs an API key or a cookie; workspace id must be wrk_/org_', () {
      final provider = OpenCodeGoProvider();
      expect(provider.validateManual(FieldValues('OpenCode Go', provider.fields, {})), isNotNull);
      expect(
        provider.validateManual(
          FieldValues('OpenCode Go', provider.fields, {'secret': 'k', 'workspaceId': 'bad'}),
        ),
        isNotNull,
      );
      expect(
        provider.validateManual(FieldValues('OpenCode Go', provider.fields, {'secret': 'k'})),
        isNull,
      );
    });
  });

  group('Windsurf', () {
    test('request protobuf: auth_token field then include_top_up_status', () {
      expect(encodeWindsurfPlanStatusRequest('abc'), [0x0A, 0x03, 0x61, 0x62, 0x63, 0x10, 0x01]);
    });

    test('web session bundle: protobuf POST with devin headers and quota windows', () async {
      final secret = SecretBundle.encode({
        'devin_session_token': 'sess',
        'devin_auth1_token': 'auth1',
        'devin_account_id': 'acct',
        'devin_primary_org_id': 'org',
      });
      final (s, req) = await _fetch(WindsurfProvider(), _account('windsurf', secret: secret), {
        'GetPlanStatus': _planStatusResponse(),
      });
      expect(s.error, isNull);
      final sent = req.single;
      expect(sent.headers['x-auth-token'], 'sess');
      expect(sent.headers['x-devin-auth1-token'], 'auth1');
      expect(sent.headers['x-devin-account-id'], 'acct');
      expect(sent.headers['x-devin-primary-org-id'], 'org');
      expect(sent.headers['Content-Type'], 'application/proto');
      expect(sent.bodyBytes, encodeWindsurfPlanStatusRequest('sess'));

      expect(s.plan, 'Pro');
      expect(s.source, 'web');
      expect(_window(s, 'windsurf-daily').usedPercent, 20);
      expect(
        _window(s, 'windsurf-daily').resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000, isUtc: true),
      );
      expect(_window(s, 'windsurf-weekly').usedPercent, 50);
      expect(
        _window(s, 'windsurf-weekly').resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1790500000 * 1000, isUtc: true),
      );
    });

    test('missing session value names the field', () async {
      final secret = SecretBundle.encode({
        'devin_session_token': 'sess',
        'devin_auth1_token': 'auth1',
        'devin_account_id': 'acct',
      });
      final (s, req) = await _fetch(WindsurfProvider(), _account('windsurf', secret: secret), {});
      expect(s.error, contains('devin_primary_org_id'));
      expect(req, isEmpty);
    });

    test('expired session reports HTTP 401', () async {
      final secret = SecretBundle.encode({
        'devin_session_token': 'sess',
        'devin_auth1_token': 'auth1',
        'devin_account_id': 'acct',
        'devin_primary_org_id': 'org',
      });
      final (s, _) = await _fetch(WindsurfProvider(), _account('windsurf', secret: secret), {
        'GetPlanStatus': 401,
      });
      expect(s.error, contains('401'));
      expect(s.errorHint, contains('windsurf.com/profile'));
    });

    test('desktop cache: quota percentages and counter fallback', () {
      final quota = parseWindsurfCachedPlan({
        'quotaUsage': {
          'dailyRemainingPercent': 70,
          'weeklyRemainingPercent': 10,
          'dailyResetAtUnix': 1790000000,
          'weeklyResetAtUnix': 1790500000,
        },
      });
      expect(quota.map((w) => w.id), ['windsurf-daily', 'windsurf-weekly']);
      expect(quota[0].usedPercent, 30);
      expect(quota[1].usedPercent, 90);

      final counters = parseWindsurfCachedPlan({
        'usage': {
          'messages': 100,
          'usedMessages': 25,
          'flowActions': 50,
          'remainingFlowActions': 40,
        },
      });
      expect(counters.map((w) => w.id), ['windsurf-messages', 'windsurf-flow']);
      expect(counters[0].usedPercent, 25);
      expect(counters[1].usedPercent, 20);
    });
  });
}
