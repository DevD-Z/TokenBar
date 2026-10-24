import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/services/desktop.dart';
import 'package:token_bar/services/history_store.dart';
import 'package:token_bar/services/home_widget_bridge.dart';
import 'package:token_bar/services/notifier.dart';
import 'package:token_bar/services/persistence.dart';
import 'package:token_bar/state/app_controller.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

/// Counts calls and returns a fixed series (or throws / returns null).
class _FakeProvider extends UsageProvider {
  _FakeProvider(this.id, {this.series, this.fail = false, this.sources});

  @override
  final String id;
  final ModelUsageSeries? series;
  final bool fail;
  final List<SourceType>? sources;
  final calls = <({String accountId, DateTime from, DateTime to})>[];

  @override
  String get displayName => id;

  @override
  int get brandColor => 0xFF000000;

  @override
  List<SourceType> get supportedSources => sources ?? const [SourceType.apiKey];

  @override
  String get setupHint => '';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) =>
      throw UnimplementedError();

  @override
  Future<ModelUsageSeries?> fetchModelUsage(
    AccountConfig account,
    FetchContext ctx, {
    required DateTime from,
    required DateTime to,
  }) async {
    calls.add((accountId: account.id, from: from, to: to));
    if (fail) throw StateError('boom');
    return series;
  }
}

ModelUsageSeries _series(DateTime from, DateTime to) => ModelUsageSeries(
  from: from,
  to: to,
  bucket: const Duration(hours: 1),
  source: 'fake',
  buckets: [
    ModelUsageBucket(
      start: DateTime(2026, 10, 24, 9),
      usage: const [ModelUsage(model: 'm1', tokens: 10, requests: 1)],
    ),
  ],
);

Future<AppController> _controller(
  Map<String, UsageProvider> providers, {
  required DateTime Function() clock,
}) async => AppController(
  persistence: await Persistence.openDemo(),
  historyStore: HistoryStore.demo(const []),
  desktop: DesktopIntegration(),
  notifier: Notifier(),
  homeWidget: HomeWidgetBridge(),
  providerLookup: (id) => providers[id],
  clock: clock,
);

void main() {
  late DateTime now;
  late _FakeProvider fake;
  late AppController controller;
  const keyed = AccountConfig(
    id: 'a1',
    providerId: 'fake',
    label: 'Fake',
    sourceType: SourceType.apiKey,
  );

  setUp(() async {
    now = DateTime(2026, 10, 24, 12, 30);
    fake = _FakeProvider('fake', series: _series(DateTime(2026, 10, 23), DateTime(2026, 10, 24)));
    controller = await _controller({'fake': fake}, clock: () => now);
    controller.accounts = [keyed];
  });

  tearDown(() => controller.dispose());

  test('local accounts ask the provider for [since, now]', () async {
    final since = now.subtract(const Duration(days: 7));
    final series = await controller.modelUsage('a1', since);
    expect(series, isNotNull);
    expect(series!.source, 'fake');
    expect(fake.calls, hasLength(1));
    expect(fake.calls.single.accountId, 'a1');
    expect(fake.calls.single.from, since);
    expect(fake.calls.single.to, now);
  });

  test('results are cached for two minutes per account and range', () async {
    final since = now.subtract(const Duration(days: 7));
    await controller.modelUsage('a1', since);
    // Same range a little later (the UI recomputes `since` from the clock) -> cached.
    now = now.add(const Duration(minutes: 1));
    await controller.modelUsage('a1', since.add(const Duration(minutes: 1)));
    expect(fake.calls, hasLength(1));
    // A different range is a different key.
    await controller.modelUsage('a1', now.subtract(const Duration(days: 30)));
    expect(fake.calls, hasLength(2));
    // After the TTL the provider is asked again.
    now = now.add(const Duration(minutes: 3));
    await controller.modelUsage('a1', since);
    expect(fake.calls, hasLength(3));
  });

  test('concurrent callers share one request', () async {
    final since = now.subtract(const Duration(hours: 24));
    final results = await Future.wait([
      controller.modelUsage('a1', since),
      controller.modelUsage('a1', since),
    ]);
    expect(results.every((r) => r != null), isTrue);
    expect(fake.calls, hasLength(1));
  });

  test('provider failures and null results become null and are not cached', () async {
    final failing = _FakeProvider('bad', fail: true);
    final empty = _FakeProvider('none');
    final c = await _controller({'bad': failing, 'none': empty}, clock: () => now);
    c.accounts = const [
      AccountConfig(id: 'b1', providerId: 'bad', label: 'Bad', sourceType: SourceType.apiKey),
      AccountConfig(id: 'n1', providerId: 'none', label: 'None', sourceType: SourceType.apiKey),
    ];
    final since = now.subtract(const Duration(days: 7));
    expect(await c.modelUsage('b1', since), isNull);
    expect(await c.modelUsage('b1', since), isNull);
    expect(failing.calls, hasLength(2), reason: 'a failure must not be cached');
    expect(await c.modelUsage('n1', since), isNull);
    expect(await c.modelUsage('n1', since), isNull);
    expect(empty.calls, hasLength(2));
    c.dispose();
  });

  test('unknown accounts and providers return null without calling anything', () async {
    final since = now.subtract(const Duration(days: 7));
    expect(await controller.modelUsage('missing', since), isNull);
    controller.accounts = const [
      AccountConfig(id: 'x1', providerId: 'ghost', label: 'Ghost', sourceType: SourceType.apiKey),
    ];
    expect(await controller.modelUsage('x1', since), isNull);
    expect(fake.calls, isEmpty);
  });

  test('accounts that only exist on the sync server have no per-model data', () async {
    // 'remote-1' is not one of this device's accounts (it came from the server snapshot list).
    expect(await controller.modelUsage('remote-1', now.subtract(const Duration(days: 7))), isNull);
    expect(fake.calls, isEmpty);
  });

  test('updating an account drops its cached series', () async {
    final since = now.subtract(const Duration(days: 7));
    await controller.modelUsage('a1', since);
    expect(fake.calls, hasLength(1));
    await controller.updateAccount(keyed.copyWith(label: 'Renamed'));
    await controller.modelUsage('a1', since);
    expect(fake.calls, hasLength(2));
  });

  group('local logins', () {
    final local = _FakeProvider(
      'loc',
      sources: const [SourceType.localCli],
      series: _series(DateTime(2026, 10, 23), DateTime(2026, 10, 24)),
    );
    const account = AccountConfig(id: 'l1', providerId: 'loc', label: 'Local');

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('are not read on mobile', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final c = await _controller({'loc': local}, clock: () => now);
      c.accounts = const [account];
      expect(await c.modelUsage('l1', now.subtract(const Duration(days: 7))), isNull);
      expect(local.calls, isEmpty);
      c.dispose();
    });

    test('are read on desktop', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final c = await _controller({'loc': local}, clock: () => now);
      c.accounts = const [account];
      expect(await c.modelUsage('l1', now.subtract(const Duration(days: 7))), isNotNull);
      expect(local.calls, hasLength(1));
      c.dispose();
    });
  });
}
