import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';
import 'package:tokenbar_server/tokenbar_server.dart';

void main() {
  late Directory dir;
  late Handler handler;
  late SnapshotStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tokenbar_server');
    store = SnapshotStore(dir.path);
    handler = buildHandler(store, const ServerConfig(adminToken: 'admin', readToken: 'reader'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Response> call(String method, String path, {String? token, Object? body}) => Future.value(
    handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'authorization': ?(token == null ? null : 'Bearer $token')},
        body: body == null ? null : jsonEncode(body),
      ),
    ),
  );

  UsageSnapshot snap(String id, double used, {String? error}) => UsageSnapshot(
    accountId: id,
    providerId: 'codex',
    fetchedAt: DateTime.now().toUtc(),
    windows: error == null
        ? [RateWindow(id: 'session', label: '5-hour', usedPercent: used)]
        : const [],
    error: error,
  );

  test('auth is enforced', () async {
    expect((await call('GET', '/api/v1/snapshots')).statusCode, 401);
    expect((await call('GET', '/api/v1/snapshots', token: 'wrong')).statusCode, 401);
    expect((await call('GET', '/api/v1/snapshots', token: 'reader')).statusCode, 200);
    final push = await call('POST', '/api/v1/snapshots', token: 'reader', body: {'snapshots': []});
    expect(push.statusCode, 403);
  });

  test('push, latest, history and last-good retention', () async {
    var r = await call(
      'POST',
      '/api/v1/snapshots',
      token: 'admin',
      body: {
        'origin': 'laptop',
        'snapshots': [snap('a', 10).toJson(), snap('b', 50).toJson()],
      },
    );
    expect(r.statusCode, 200);

    r = await call(
      'POST',
      '/api/v1/snapshots',
      token: 'admin',
      body: {
        'snapshots': [snap('a', 0, error: 'network down').toJson()],
      },
    );
    expect(r.statusCode, 200);

    r = await call('GET', '/api/v1/snapshots', token: 'reader');
    final latest = (jsonDecode(await r.readAsString())['snapshots'] as List)
        .map((e) => UsageSnapshot.fromJson((e as Map).cast()))
        .toList();
    final a = latest.firstWhere((s) => s.accountId == 'a');
    expect(a.error, 'network down');
    expect(a.session!.usedPercent, 10, reason: 'last good data kept');
    expect(a.origin, 'laptop');

    r = await call('GET', '/api/v1/history?account=b', token: 'reader');
    final points = jsonDecode(await r.readAsString())['points'] as List;
    expect(points, hasLength(1));

    // Persisted across restarts.
    final reopened = SnapshotStore(dir.path);
    expect(reopened.latest().map((s) => s.accountId), ['a', 'b']);
  });

  test('api client talks to the handler shape', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    // Minimal adapter to avoid depending on shelf_io in the test.
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final res = await handler(
        Request(
          req.method,
          req.requestedUri,
          headers: {
            for (final h in ['authorization', 'content-type'])
              if (req.headers.value(h) != null) h: req.headers.value(h)!,
          },
          body: body,
        ),
      );
      req.response.statusCode = res.statusCode;
      req.response.write(await res.readAsString());
      await req.response.close();
    });
    final client = TokenBarApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'admin');
    await client.push([snap('x', 33)], origin: 'test');
    final latest = await client.latest();
    expect(latest.single.origin, 'test');
    final history = await client.history(accountId: 'x');
    expect(history.single.used['session'], 33);
    client.close();
    await server.close(force: true);
  });

  test('interval parsing', () {
    expect(parseInterval('5m'), const Duration(minutes: 5));
    expect(parseInterval('30s'), const Duration(seconds: 30));
    expect(parseInterval('2h'), const Duration(hours: 2));
    expect(parseInterval('10'), const Duration(minutes: 10));
  });
}
