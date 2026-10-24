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

CursorUsageEvent _ev(String model, int ts, {int tokens = 1, double? cents}) =>
    CursorUsageEvent(timestampMs: ts, model: model, tokens: tokens, chargedCents: cents);

List<CursorUsageEvent> _fixtureEvents() =>
    parseCursorUsageEventsPage(_fixture('cursor_usage_events.json'))!.events;

/// One events page with [count] identical-shape rows for [model].
String _page(int count, {required int total, String model = 'gpt-5'}) => jsonEncode({
  'totalUsageEventsCount': total,
  'usageEventsDisplay': [
    for (var i = 0; i < count; i++)
      {
        'timestamp': '${1700000000000 + i}',
        'model': model,
        'tokenUsage': {
          'inputTokens': 1,
          'outputTokens': 0,
          'cacheWriteTokens': 0,
          'cacheReadTokens': 0,
        },
        'chargedCents': 1,
      },
  ],
});

void main() {
  group('events page parsing', () {
    test('fixture rows keep model, token total and metered cents', () {
      final page = parseCursorUsageEventsPage(_fixture('cursor_usage_events.json'))!;
      expect(page.total, 3);
      expect(page.events, hasLength(3));
      final first = page.events.first;
      expect(first.model, 'claude-4.5-sonnet');
      expect(first.tokens, 150);
      expect(first.chargedCents, 4);
      expect(first.timestampMs, 1700000000000);
    });

    test('count-only and empty envelopes are confirmed empty pages', () {
      final empty = parseCursorUsageEventsPage({})!;
      expect(empty.total, 0);
      expect(empty.events, isEmpty);
      final countOnly = parseCursorUsageEventsPage({'totalUsageEventsCount': 2})!;
      expect(countOnly.total, 2);
      expect(countOnly.events, isEmpty);
    });

    test('error-like or malformed envelopes are rejected, never read as no usage', () {
      expect(
        parseCursorUsageEventsPage({'totalUsageEventsCount': 0, 'error': 'unavailable'}),
        isNull,
      );
      expect(parseCursorUsageEventsPage({'usageEventsDisplay': null}), isNull);
      expect(
        parseCursorUsageEventsPage({'totalUsageEventsCount': 0, 'usageEventsDisplay': {}}),
        isNull,
      );
      expect(
        parseCursorUsageEventsPage({'totalUsageEventsCount': -1, 'usageEventsDisplay': []}),
        isNull,
      );
      expect(parseCursorUsageEventsPage({'totalUsageEventsCount': null}), isNull);
      expect(
        parseCursorUsageEventsPage({
          'totalUsageEventsCount': 1,
          'usageEventsDisplay': ['x'],
        }),
        isNull,
      );
    });

    test('string counts are accepted and non-finite metered cents are dropped', () {
      final page = parseCursorUsageEventsPage({
        'totalUsageEventsCount': '2',
        'usageEventsDisplay': [
          {
            'timestamp': '1700000000000',
            'model': 'gpt-5',
            'tokenUsage': {'inputTokens': '7'},
            'chargedCents': 'Infinity',
          },
        ],
      })!;
      expect(page.total, 2);
      expect(page.events.single.tokens, 7);
      expect(page.events.single.chargedCents, isNull);
    });
  });

  group('pagination reconciliation', () {
    test('removes boundary duplicates only as far as the total proves', () {
      final a = _ev('a', 1);
      final b = _ev('b', 2);
      final c = _ev('c', 3);
      // Four raw rows against a total of three: the repeated `b` at the boundary goes.
      expect(
        reconcileCursorEventPages([
          [a, b],
          [b, c],
        ], 3),
        [a, b, c],
      );
      // Raw equals total: nothing is removed even though equal rows exist.
      expect(
        reconcileCursorEventPages([
          [a, b],
          [b, c],
        ], 4),
        [a, b, b, c],
      );
    });

    test('fails closed when pages cannot be reconciled with the total', () {
      expect(
        reconcileCursorEventPages([
          [_ev('a', 1)],
        ], 2),
        isNull,
      );
      expect(
        reconcileCursorEventPages([
          [_ev('a', 1), _ev('b', 2)],
          [_ev('c', 3)],
        ], 1),
        isNull,
      );
    });

    test('without a total every raw row is kept', () {
      final a = _ev('a', 1);
      expect(
        reconcileCursorEventPages([
          [a],
          [a],
        ], null),
        [a, a],
      );
    });
  });

  group('per-model summary', () {
    test('groups by model, sorted by metered spend, with exact totals', () {
      final rows = summarizeCursorModelUsage(_fixtureEvents());
      expect(rows.map((r) => r.model), ['gpt-5', 'claude-4.5-sonnet']);
      expect(rows[0].events, 2);
      expect(rows[0].tokens, 17);
      expect(rows[0].chargedUsd, closeTo(0.12, 1e-9));
      expect(rows[1].events, 1);
      expect(rows[1].tokens, 150);
      expect(rows[1].chargedUsd, closeTo(0.04, 1e-9));
    });

    test('a model with any missing metered amount reports no spend', () {
      final rows = summarizeCursorModelUsage([
        _ev('x', 1, tokens: 5, cents: 10),
        _ev('x', 2, tokens: 5),
      ]);
      expect(rows.single.events, 2);
      expect(rows.single.tokens, 10);
      expect(rows.single.chargedUsd, isNull);
    });

    test('events without a valid timestamp are ignored', () {
      final rows = summarizeCursorModelUsage([
        CursorUsageEvent(timestampMs: null, model: 'x', tokens: 9),
        _ev('x', 0, tokens: 9),
      ]);
      expect(rows, isEmpty);
    });
  });

  group('detail rows', () {
    test('show totals and per-model lines, never a per-model percentage', () {
      final extras = cursorModelExtras(summarizeCursorModelUsage(_fixtureEvents()));
      expect(extras['按模型用量'], '3 次请求 · 167 tokens · \$0.16');
      expect(extras['模型 gpt-5'], '2 次请求 · 17 tokens · \$0.12');
      expect(extras['模型 claude-4.5-sonnet'], '1 次请求 · 150 tokens · \$0.04');
      expect(extras.values.any((v) => v.contains('%')), isFalse);
    });

    test('unavailable and empty states are explicit', () {
      expect(cursorModelExtras(null), {'按模型用量': '暂不可用（事件数据未能完整获取）'});
      expect(cursorModelExtras(const []), {'按模型用量': '本计费周期暂无用量记录'});
    });

    test('rows beyond maxRows fold into one line', () {
      final models = [
        for (var i = 0; i < 12; i++)
          CursorModelUsage(model: 'm$i', events: 1, tokens: 1000, chargedUsd: 1.0),
      ];
      final extras = cursorModelExtras(models, maxRows: 10);
      expect(extras.containsKey('模型 m9'), isTrue);
      expect(extras.containsKey('模型 m10'), isFalse);
      expect(extras['其余 2 个模型'], '2 次请求');
    });
  });

  group('provider per-model extras', () {
    final token = _jwt({'sub': 'auth0|user_01ABC', 'exp': 1893456000});
    final account = AccountConfig(
      id: 'cursor-1',
      providerId: 'cursor',
      label: 'Cursor',
      sourceType: SourceType.apiKey,
      secret: token,
    );
    final now = DateTime.utc(2026, 10, 20);

    /// Routes the summary/auth endpoints to the pro fixture and events POSTs to [events].
    MockClient client(List<http.Request> seen, http.Response Function(int page) events) =>
        MockClient((r) async {
          seen.add(r);
          return switch (r.url.path) {
            '/api/usage-summary' => http.Response(
              File('test/fixtures/cursor_usage_pro.json').readAsStringSync(),
              200,
            ),
            '/api/auth/me' => http.Response('{"email":"dev@example.com"}', 200),
            '/api/dashboard/get-filtered-usage-events' => events(
              (jsonDecode(r.body) as Map<String, Object?>)['page'] as int,
            ),
            _ => http.Response('', 404),
          };
        });

    test('events POST sends cookie, origin and billing-cycle start; rows reach extras', () async {
      final seen = <http.Request>[];
      final s = await CursorProvider().fetch(
        account,
        FetchContext(
          client: client(
            seen,
            (_) => http.Response(
              File('test/fixtures/cursor_usage_events.json').readAsStringSync(),
              200,
            ),
          ),
          clock: () => now,
        ),
      );
      final req = seen.singleWhere((r) => r.url.path == '/api/dashboard/get-filtered-usage-events');
      expect(req.method, 'POST');
      expect(req.headers['Origin'], 'https://cursor.com');
      expect(req.headers['Cookie'], endsWith('WorkosCursorSessionToken=user_01ABC%3A%3A$token'));
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['page'], 1);
      expect(body['pageSize'], 1000);
      // cursor_usage_pro.json: billingCycleStart 2026-10-10T00:00:00Z
      expect(body['startDate'], '${DateTime.utc(2026, 10, 10).millisecondsSinceEpoch}');
      expect(body['endDate'], '${now.millisecondsSinceEpoch}');

      expect(s.extras['按模型用量'], '3 次请求 · 167 tokens · \$0.16');
      expect(s.extras['模型 gpt-5'], '2 次请求 · 17 tokens · \$0.12');
      expect(s.windows.map((w) => w.id), ['cursor-total', 'cursor-auto', 'cursor-api']);
    });

    test('full first page is followed by the next page until the total is reached', () async {
      final seen = <http.Request>[];
      final s = await CursorProvider().fetch(
        account,
        FetchContext(
          client: client(seen, (page) {
            if (page == 1) return http.Response(_page(1000, total: 1001), 200);
            return http.Response(_page(1, total: 1001, model: 'claude-4.5-sonnet'), 200);
          }),
          clock: () => now,
        ),
      );
      final pages = seen
          .where((r) => r.url.path == '/api/dashboard/get-filtered-usage-events')
          .map((r) => (jsonDecode(r.body) as Map<String, Object?>)['page'])
          .toList();
      expect(pages, [1, 2]);
      expect(s.extras['模型 gpt-5'], '1000 次请求 · 1.0K tokens · \$10.00');
      expect(s.extras['模型 claude-4.5-sonnet'], '1 次请求 · 1 tokens · \$0.01');
    });

    test('a changing total across pages is reported as unavailable, not summed', () async {
      final s = await CursorProvider().fetch(
        account,
        FetchContext(
          client: client([], (page) {
            if (page == 1) return http.Response(_page(1000, total: 1001), 200);
            return http.Response(_page(1, total: 1002), 200);
          }),
          clock: () => now,
        ),
      );
      expect(s.extras['按模型用量'], contains('暂不可用'));
      expect(s.extras.containsKey('模型 gpt-5'), isFalse);
      expect(s.windows, isNotEmpty);
    });

    test('events endpoint failure keeps quota windows and marks models unavailable', () async {
      final s = await CursorProvider().fetchSafely(
        account,
        FetchContext(client: client([], (_) => http.Response('{}', 500)), clock: () => now),
      );
      expect(s.hasError, isFalse);
      expect(s.windows, isNotEmpty);
      expect(s.extras['按模型用量'], contains('暂不可用'));
    });
  });
}
