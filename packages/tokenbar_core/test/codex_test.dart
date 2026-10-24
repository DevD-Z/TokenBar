import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

String _jwt(Map<String, Object?> payload) {
  String seg(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'none'})}.${seg(payload)}.sig';
}

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, Object?>;

void main() {
  group('wham/usage parsing', () {
    test('maps session, weekly, credits and additional limits', () {
      final parsed = parseWhamUsage(_fixture('wham_usage_plus.json'));
      expect(parsed.plan, 'plus');
      expect(parsed.accountId, 'acct-123');
      final ids = parsed.windows.map((w) => w.id).toList();
      expect(ids, ['session', 'weekly', 'gpt-5-3-codex-spark', 'gpt-5-3-codex-spark-weekly']);
      final session = parsed.windows.first;
      expect(session.usedPercent, 42);
      expect(session.remainingPercent, 58);
      expect(session.windowMinutes, 300);
      expect(session.resetsAt, DateTime.fromMillisecondsSinceEpoch(1700003600 * 1000, isUtc: true));
      expect(parsed.windows[1].usedPercent, 17.5);
      expect(parsed.credits.single.balance, 12.5);
    });

    test('weekly-only primary window is not shown as 5-hour lane', () {
      final parsed = parseWhamUsage({
        'rate_limit': {
          'primary_window': {'used_percent': 9, 'reset_at': 1, 'limit_window_seconds': 604800},
        },
      });
      expect(parsed.windows.single.id, 'weekly');
    });

    test('swapped windows are normalized by duration', () {
      final parsed = parseWhamUsage({
        'rate_limit': {
          'primary_window': {'used_percent': 70, 'reset_at': 1, 'limit_window_seconds': 604800},
          'secondary_window': {'used_percent': 10, 'reset_at': 2, 'limit_window_seconds': 18000},
        },
      });
      expect(parsed.session?.usedPercent ?? parsed.windows.first.usedPercent, 10);
      expect(parsed.windows.first.id, 'session');
    });

    test('spend control individual limit becomes credits', () {
      final parsed = parseWhamUsage({
        'plan_type': 'business',
        'credits': {'has_credits': false, 'unlimited': false},
        'individual_limit': {'limit': 400, 'used': 300},
      });
      final cap = parsed.credits.single;
      expect(cap.usedPercent, 75);
    });
  });

  test('app-server rateLimits parsing', () {
    final parsed = parseRpcRateLimits(
      {
        'rateLimits': {
          'limitId': 'codex',
          'primary': {'usedPercent': 20.0, 'windowDurationMins': 300, 'resetsAt': 1700003600},
          'secondary': {'usedPercent': 50.0, 'windowDurationMins': 10080, 'resetsAt': 1700400000},
          'credits': {'hasCredits': true, 'unlimited': false, 'balance': '3.25'},
          'planType': 'pro',
        },
      },
      account: {
        'account': {'type': 'chatgpt', 'email': 'me@example.com', 'planType': 'pro'},
      },
    );
    expect(parsed.windows.map((w) => w.usedPercent), [20, 50]);
    expect(parsed.plan, 'pro');
    expect(parsed.email, 'me@example.com');
    expect(parsed.credits.single.balance, 3.25);
  });

  group('auth.json', () {
    test('extracts account id, email, plan and expiry from JWT claims', () {
      final access = _jwt({'exp': 4102444800});
      final idToken = _jwt({
        'email': 'dev@example.com',
        'https://api.openai.com/auth': {
          'chatgpt_account_id': 'from-jwt',
          'chatgpt_plan_type': 'pro',
        },
      });
      final creds = CodexCredentials.parse(
        jsonEncode({
          'tokens': {'access_token': access, 'refresh_token': 'r', 'id_token': idToken},
          'last_refresh': '2025-01-01T00:00:00Z',
        }),
      )!;
      expect(creds.accountId, 'from-jwt');
      expect(creds.email, 'dev@example.com');
      expect(creds.planFromToken, 'pro');
      expect(creds.isExpired(DateTime.utc(2030)), isFalse);
      expect(creds.isExpired(DateTime.utc(2101)), isTrue);
    });

    test('detects API key mode', () {
      final creds = CodexCredentials.parse('{"OPENAI_API_KEY": "sk-test"}')!;
      expect(creds.isApiKey, isTrue);
    });

    test('config.toml base url override', () {
      const toml = '''
# chatgpt_base_url = "https://ignored"
model = "gpt-5"
chatgpt_base_url = "https://proxy.example.com/" # trailing comment
''';
      final base = parseChatGptBaseUrl(toml);
      expect(base, 'https://proxy.example.com/');
      expect(codexUsageUri(base).toString(), 'https://proxy.example.com/api/codex/usage');
      expect(codexUsageUri(null).toString(), 'https://chatgpt.com/backend-api/wham/usage');
      expect(
        codexUsageUri('https://chatgpt.com').toString(),
        'https://chatgpt.com/backend-api/wham/usage',
      );
    });
  });

  group('CodexProvider end-to-end with mocked HTTP', () {
    late Directory home;
    setUp(() {
      home = Directory.systemTemp.createTempSync('tokenbar_codex');
    });
    tearDown(() => home.deleteSync(recursive: true));

    test('sends bearer + account header and builds snapshot', () async {
      File('${home.path}/auth.json').writeAsStringSync(
        jsonEncode({
          'tokens': {
            'access_token': _jwt({'exp': 4102444800}),
            'refresh_token': 'r',
            'account_id': 'acct-xyz',
          },
        }),
      );
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(File('test/fixtures/wham_usage_plus.json').readAsStringSync(), 200);
      });
      final snapshot = await CodexProvider().fetchSafely(
        AccountConfig(id: 'a1', providerId: 'codex', label: 'Work', homeDir: home.path),
        FetchContext(client: client, allowCliFallback: false),
      );
      expect(snapshot.error, isNull);
      expect(seen.url.toString(), 'https://chatgpt.com/backend-api/wham/usage');
      expect(seen.headers['ChatGPT-Account-Id'], 'acct-xyz');
      expect(seen.headers['Authorization'], startsWith('Bearer '));
      expect(snapshot.accountLabel, 'Work');
      expect(snapshot.session!.usedPercent, 42);
      expect(snapshot.source, 'oauth');
    });

    test('missing auth.json yields actionable error snapshot', () async {
      final snapshot = await CodexProvider().fetchSafely(
        AccountConfig(id: 'a1', providerId: 'codex', label: 'x', homeDir: home.path),
        FetchContext(
          client: MockClient((_) async => http.Response('', 500)),
          allowCliFallback: false,
        ),
      );
      expect(snapshot.hasError, isTrue);
      expect(snapshot.errorHint, contains('codex login'));
    });

    test('401 without CLI fallback surfaces auth error', () async {
      File('${home.path}/auth.json').writeAsStringSync(
        jsonEncode({
          'tokens': {
            'access_token': _jwt({'exp': 4102444800}),
            'refresh_token': 'r',
          },
        }),
      );
      final snapshot = await CodexProvider().fetchSafely(
        AccountConfig(id: 'a1', providerId: 'codex', label: 'x', homeDir: home.path),
        FetchContext(
          client: MockClient((_) async => http.Response('{}', 401)),
          allowCliFallback: false,
        ),
      );
      expect(snapshot.error, contains('401'));
    });
  });
}

extension on CodexParsedUsage {
  RateWindow? get session {
    for (final w in windows) {
      if (w.id == 'session') return w;
    }
    return null;
  }
}
