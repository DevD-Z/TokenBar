import 'package:test/test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  test('rate window derived values', () {
    final w = RateWindow(
      id: 'session',
      label: '5-hour',
      usedPercent: 60,
      resetsAt: now.add(const Duration(hours: 3)),
      windowMinutes: 300,
    );
    expect(w.remainingPercent, 40);
    expect(w.timeUntilReset(now), const Duration(hours: 3));
    expect(w.elapsedFraction(now), closeTo(0.4, 1e-9));
    expect(w.paceDelta(now), closeTo(20, 1e-9));
    expect(w.projectedUsedAtReset(now), closeTo(150, 1e-9));
  });

  test('snapshot json roundtrip', () {
    final s = UsageSnapshot(
      accountId: 'a',
      providerId: 'codex',
      fetchedAt: now,
      plan: 'plus',
      windows: [
        RateWindow(
          id: 'session',
          label: '5-hour',
          usedPercent: 10,
          resetsAt: now,
          windowMinutes: 300,
        ),
        const RateWindow(id: 'weekly', label: 'Weekly', usedPercent: 80),
      ],
      credits: const [Credits(id: 'c', label: 'Credits', balance: 4)],
      extras: const {'k': 'v'},
    );
    final back = UsageSnapshot.fromJson(s.toJson());
    expect(back.plan, 'plus');
    expect(back.windows.length, 2);
    expect(back.tightestWindow!.id, 'weekly');
    expect(back.credits.single.balance, 4);
    expect(back.extras['k'], 'v');
  });

  test('OAuth credential roundtrip stays out of account json', () {
    final credential = OAuthCredential(
      accessToken: 'access',
      refreshToken: 'refresh',
      idToken: 'id',
      expiresAt: DateTime.utc(2030),
      email: 'user@example.com',
      accountId: 'acct',
      plan: 'plus',
    );
    final decoded = OAuthCredential.decode(credential.encode())!;
    expect(decoded.accessToken, 'access');
    expect(decoded.refreshToken, 'refresh');
    expect(decoded.accountId, 'acct');

    final account = AccountConfig(
      id: 'oauth',
      providerId: 'codex',
      label: 'OAuth',
      sourceType: SourceType.oauth,
      secret: credential.encode(),
    );
    expect(account.toJson()['sourceType'], 'oauth');
    expect(account.toJson().containsKey('secret'), isFalse);
    expect(account.toJson().toString(), isNot(contains('access')));
    expect(account.toJson().toString(), isNot(contains('refresh')));
  });

  test('account json never contains the secret', () {
    const a = AccountConfig(
      id: 'x',
      providerId: 'openrouter',
      label: 'OR',
      sourceType: SourceType.apiKey,
      secret: 'sk',
    );
    expect(a.toJson().containsKey('secret'), isFalse);
  });

  test('downsample keeps last point per bucket', () {
    final points = [
      for (var i = 0; i < 6; i++)
        UsagePoint(
          accountId: 'a',
          at: now.add(Duration(minutes: 20 * i)),
          used: {'session': i.toDouble()},
        ),
    ];
    final result = downsample(points, const Duration(hours: 1));
    expect(result.length, 2);
    expect(result.first.used['session'], 2);
  });

  test('format helpers', () {
    expect(formatCountdown(const Duration(days: 2, hours: 3)), '2d 3h');
    expect(formatCountdown(const Duration(hours: 1, minutes: 5)), '1h 5m');
    expect(formatCountdown(const Duration(seconds: 20)), '<1m');
    expect(formatPercent(42.0), '42%');
    expect(formatPercent(17.46), '17.5%');
  });
}
