import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, Object?>;

String _jwt(Map<String, Object?> claims) {
  String seg(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg(claims)}.sig';
}

void main() {
  group('usage-summary parser', () {
    test('enterprise member cap from individualUsage.overall', () {
      final u = parseCursorUsageSummary(_fixture('cursor_usage_enterprise.json'));
      expect(u.plan, 'enterprise');
      expect(u.windows, hasLength(1));
      final w = u.windows.single;
      expect(w.id, 'cursor-total');
      expect(w.usedPercent, closeTo(5.51, 0.01));
      expect(w.resetsAt, DateTime.utc(2026, 11, 1));
      expect(w.windowMinutes, 31 * 24 * 60);
      final plan = u.credits.singleWhere((c) => c.id == 'cursor-plan');
      expect(plan.used, closeTo(44.08, 1e-9));
      expect(plan.limit, 800);
      expect(plan.currency, 'USD');
      expect(
        u.credits.where((c) => c.id == 'cursor-team-on-demand'),
        isEmpty,
        reason: 'disabled and unused',
      );
    });

    test('pro plan prefers totalPercentUsed and exposes auto/api lanes', () {
      final u = parseCursorUsageSummary(_fixture('cursor_usage_pro.json'));
      expect(u.windows.map((w) => w.id), ['cursor-total', 'cursor-auto', 'cursor-api']);
      expect(u.windows[0].usedPercent, 62);
      expect(u.windows[1].usedPercent, 18.5);
      expect(u.windows[2].usedPercent, 72.25);
      final plan = u.credits.singleWhere((c) => c.id == 'cursor-plan');
      expect(plan.used, 12.4);
      expect(plan.limit, 20);
      final onDemand = u.credits.singleWhere((c) => c.id == 'cursor-on-demand');
      expect(onDemand.used, 3.5);
      expect(onDemand.limit, 50);
    });

    test('fractional percents are percent units, not ratios', () {
      final u = parseCursorUsageSummary({
        'individualUsage': {
          'plan': {'autoPercentUsed': 0.36},
        },
      });
      expect(u.windows.first.usedPercent, 0.36);
    });
  });

  group('session parsing', () {
    final token = _jwt({'sub': 'auth0|user_01ABC', 'exp': 1893456000, 'email': 'dev@example.com'});

    test('access token becomes WorkosCursorSessionToken cookie', () {
      final s = CursorSession.fromAccessToken(token, source: 'app')!;
      expect(s.cookieHeader, 'WorkosCursorSessionToken=user_01ABC%3A%3A$token');
      expect(s.email, 'dev@example.com');
      expect(s.expiresAt, DateTime.utc(2030, 1, 1));
    });

    test('manual input forms', () {
      expect(
        CursorSession.fromManual('Cookie: a=1; WorkosCursorSessionToken=x%3A%3Ay')!.cookieHeader,
        'a=1; WorkosCursorSessionToken=x%3A%3Ay',
      );
      expect(
        CursorSession.fromManual('user_01ABC::$token')!.cookieHeader,
        'WorkosCursorSessionToken=user_01ABC%3A%3A$token',
      );
      expect(
        CursorSession.fromManual('user_01ABC%3A%3A$token')!.cookieHeader,
        'WorkosCursorSessionToken=user_01ABC%3A%3A$token',
      );
      expect(
        CursorSession.fromManual(token)!.cookieHeader,
        'WorkosCursorSessionToken=user_01ABC%3A%3A$token',
      );
      expect(CursorSession.fromManual('foo=bar'), isNull);
      expect(CursorSession.fromManual('   '), isNull);
    });

    test('expiry check uses a 60 second margin', () {
      final s = CursorSession.fromAccessToken(_jwt({'sub': 'u', 'exp': 1000}), source: 'app')!;
      expect(s.isExpired(DateTime.fromMillisecondsSinceEpoch(941 * 1000, isUtc: true)), isTrue);
      expect(s.isExpired(DateTime.fromMillisecondsSinceEpoch(900 * 1000, isUtc: true)), isFalse);
    });
  });

  group('provider', () {
    final token = _jwt({'sub': 'auth0|user_01ABC', 'exp': 1893456000});
    final account = AccountConfig(
      id: 'cursor-1',
      providerId: 'cursor',
      label: 'Cursor',
      sourceType: SourceType.apiKey,
      secret: token,
    );

    test('manual cookie fetch sends cookie and parses usage + email', () async {
      final seen = <String>[];
      final client = MockClient((r) async {
        seen.add('${r.url.path} ${r.headers['Cookie']}');
        return switch (r.url.path) {
          '/api/usage-summary' => http.Response(
            File('test/fixtures/cursor_usage_pro.json').readAsStringSync(),
            200,
          ),
          '/api/auth/me' => http.Response(
            '{"email":"dev@example.com","sub":"auth0|user_01ABC"}',
            200,
          ),
          _ => http.Response('', 404),
        };
      });
      final s = await CursorProvider().fetch(
        account,
        FetchContext(client: client, clock: () => DateTime.utc(2026, 10, 20)),
      );
      expect(seen, everyElement(endsWith('WorkosCursorSessionToken=user_01ABC%3A%3A$token')));
      expect(s.plan, 'pro');
      expect(s.email, 'dev@example.com');
      expect(s.source, 'cookie');
      expect(s.tightestWindow!.id, 'cursor-api');
    });

    test('401 becomes an actionable error snapshot', () async {
      final s = await CursorProvider().fetchSafely(
        account,
        FetchContext(
          client: MockClient((_) async => http.Response('{}', 401)),
          clock: () => DateTime.utc(2026, 10, 20),
        ),
      );
      expect(s.hasError, isTrue);
      expect(s.error, contains('401'));
      expect(s.errorHint, contains('Cookie'));
    });

    test('missing secret is reported without a request', () async {
      final s = await CursorProvider().fetchSafely(
        account.copyWith(clearSecret: true),
        FetchContext(client: MockClient((_) async => fail('no request expected'))),
      );
      expect(s.error, contains('未填写'));
    });
  });
}
