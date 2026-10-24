import 'dart:math';

import 'package:tokenbar_core/tokenbar_core.dart';

/// Build with `--dart-define=TOKENBAR_DEMO=true` to run on the fictional data
/// below. Nothing is read from or written to the real settings, accounts,
/// secure storage or history, so it is safe for screenshots and demos.
const bool kDemoMode = bool.fromEnvironment('TOKENBAR_DEMO');

/// Fictional accounts, usage snapshots and a month of hourly history.
///
/// The history is simulated with a working-hours rhythm and quota windows that
/// reset on their own cycles; each snapshot is the latest history sample, so
/// cards and charts agree. All names and e-mail addresses are made up
/// (`example.com` / `example.org`).
class DemoData {
  DemoData(DateTime now)
    : now = DateTime(now.year, now.month, now.day, now.hour),
      _fetchedAt = now.subtract(const Duration(minutes: 2)) {
    _build();
  }

  final DateTime now;
  final DateTime _fetchedAt;

  static const hours = 24 * 30;

  final List<AccountConfig> accounts = [];
  final Map<String, UsageSnapshot> snapshots = {};
  final List<UsagePoint> history = [];

  // ---------------------------------------------------------------- building

  void _build() {
    _claude();
    _codex();
    _cursor();
    _openRouter();
    _deepSeek();
    _zai();
  }

  DateTime _at(int i) => now.subtract(Duration(hours: hours - 1 - i));

  /// Relative hourly activity: busy on weekday daytime, quiet at night and on
  /// weekends.
  List<double> _activity(int seed, {double min = 0.4, double span = 1.2}) {
    final r = Random(seed);
    return List.generate(hours, (i) {
      final t = _at(i);
      var a = (t.hour >= 9 && t.hour < 23) ? 1.0 : 0.04;
      if (t.hour == 12 || t.hour == 18) a *= 0.4;
      if (t.weekday >= 6) a *= 0.35;
      return a * (min + r.nextDouble() * span);
    });
  }

  /// Cumulative values that restart every [cycleHours]. [phase] is how many
  /// hours of the current cycle have elapsed; the newest value is [target].
  /// Earlier cycles peak at a plausible, varying level.
  List<double> _cumulative({
    required List<double> activity,
    required int cycleHours,
    required int phase,
    required double target,
    required int seed,
    double ceiling = 100,
  }) {
    final r = Random(seed);
    final raw = List<double>.filled(hours, 0);
    final cycleOf = List<int>.filled(hours, 0);
    var cycle = 0;
    for (var i = 0; i < hours; i++) {
      final pos = ((phase - (hours - 1 - i)) % cycleHours + cycleHours) % cycleHours;
      if (pos == 0 && i > 0) cycle++;
      cycleOf[i] = cycle;
      raw[i] = (pos == 0 || i == 0 ? 0 : raw[i - 1]) + activity[i];
    }
    final lastCycle = cycleOf.last;
    final ends = <int, double>{};
    for (var i = 0; i < hours; i++) {
      ends[cycleOf[i]] = raw[i];
    }
    final scales = <int, double>{
      for (final e in ends.entries)
        e.key: e.value <= 0
            ? 0
            : (e.key == lastCycle
                      ? target
                      : min(ceiling * 0.95, ceiling * (0.45 + r.nextDouble() * 0.45))) /
                  e.value,
    };
    return [for (var i = 0; i < hours; i++) min(ceiling, raw[i] * scales[cycleOf[i]]!)];
  }

  void _addHistory(
    String accountId,
    Map<String, List<double>> used, [
    Map<String, List<double>> spend = const {},
  ]) {
    for (var i = 0; i < hours; i++) {
      history.add(
        UsagePoint(
          accountId: accountId,
          at: _at(i),
          used: {for (final e in used.entries) e.key: e.value[i]},
          spend: {for (final e in spend.entries) e.key: e.value[i]},
        ),
      );
    }
  }

  RateWindow _window(
    String id,
    String label,
    List<double> values,
    int cycleHours,
    int phase,
    int windowMinutes,
  ) => RateWindow(
    id: id,
    label: label,
    usedPercent: double.parse(values.last.toStringAsFixed(1)),
    resetsAt: now.add(Duration(hours: cycleHours - phase)),
    windowMinutes: windowMinutes,
  );

  void _claude() {
    const id = 'demo-claude';
    const week = 24 * 7;
    final a = _activity(11);
    final session = _cumulative(activity: a, cycleHours: 5, phase: 3, target: 38, seed: 1);
    final weekly = _cumulative(activity: a, cycleHours: week, phase: 100, target: 52, seed: 2);
    final opus = _cumulative(
      activity: _activity(12, min: 0.1, span: 0.7),
      cycleHours: week,
      phase: 100,
      target: 21,
      seed: 3,
    );
    final sonnet = _cumulative(
      activity: _activity(13, min: 0.3, span: 1.0),
      cycleHours: week,
      phase: 100,
      target: 34,
      seed: 4,
    );
    final extra = _cumulative(
      activity: _activity(14, min: 0, span: 1.0),
      cycleHours: 720,
      phase: 400,
      target: 12.4,
      seed: 5,
      ceiling: 50,
    );
    accounts.add(const AccountConfig(id: id, providerId: 'claude', label: 'Claude'));
    _addHistory(
      id,
      {
        RateWindow.sessionId: session,
        RateWindow.weeklyId: weekly,
        'weekly_opus': opus,
        'weekly_sonnet': sonnet,
      },
      {'claude-extra-usage': extra},
    );
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'claude',
      fetchedAt: _fetchedAt,
      accountLabel: 'Claude',
      plan: 'max',
      email: 'demo.user@example.com',
      source: 'oauth',
      windows: [
        _window(RateWindow.sessionId, '5-hour', session, 5, 3, 300),
        _window(RateWindow.weeklyId, 'Weekly', weekly, week, 100, week * 60),
        _window('weekly_opus', 'Opus weekly', opus, week, 100, week * 60),
        _window('weekly_sonnet', 'Sonnet weekly', sonnet, week, 100, week * 60),
      ],
      credits: [
        Credits(
          id: 'claude-extra-usage',
          label: 'Extra usage',
          used: extra.last,
          limit: 50,
          currency: 'USD',
        ),
      ],
    );
  }

  void _codex() {
    const id = 'demo-codex';
    const week = 24 * 7;
    final a = _activity(21);
    final session = _cumulative(activity: a, cycleHours: 5, phase: 4, target: 63, seed: 6);
    final weekly = _cumulative(activity: a, cycleHours: week, phase: 120, target: 91, seed: 7);
    accounts.add(const AccountConfig(id: id, providerId: 'codex', label: 'Codex'));
    _addHistory(id, {RateWindow.sessionId: session, RateWindow.weeklyId: weekly});
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'codex',
      fetchedAt: _fetchedAt,
      accountLabel: 'Codex',
      plan: 'plus',
      email: 'alex.demo@example.com',
      source: 'oauth',
      windows: [
        _window(RateWindow.sessionId, '5-hour', session, 5, 4, 300),
        _window(RateWindow.weeklyId, 'Weekly', weekly, week, 120, week * 60),
      ],
      credits: const [Credits(id: 'codex-credits', label: 'Credits', balance: 120)],
    );
  }

  void _cursor() {
    const id = 'demo-cursor';
    const month = 720;
    final auto = _cumulative(
      activity: _activity(31, min: 0.2, span: 1.0),
      cycleHours: month,
      phase: 410,
      target: 41,
      seed: 8,
    );
    final api = _cumulative(
      activity: _activity(32, min: 0.1, span: 0.9),
      cycleHours: month,
      phase: 410,
      target: 77,
      seed: 9,
    );
    final total = [for (var i = 0; i < hours; i++) min(100.0, (auto[i] + api[i]) / 2 + 0.0)];
    accounts.add(const AccountConfig(id: id, providerId: 'cursor', label: 'Cursor'));
    _addHistory(id, {'cursor-total': total, 'cursor-auto': auto, 'cursor-api': api});
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'cursor',
      fetchedAt: _fetchedAt,
      accountLabel: 'Cursor',
      plan: 'pro',
      email: 'dev@example.org',
      source: 'cursor-app',
      windows: [
        _window('cursor-total', 'Monthly', total, month, 410, month * 60),
        _window('cursor-auto', 'Auto', auto, month, 410, month * 60),
        _window('cursor-api', 'API', api, month, 410, month * 60),
      ],
    );
  }

  void _openRouter() {
    const id = 'demo-openrouter';
    final spent = _cumulative(
      activity: _activity(41, min: 0.1, span: 1.4),
      cycleHours: 1 << 20,
      phase: hours * 4,
      target: 57.82,
      seed: 10,
      ceiling: 100,
    );
    accounts.add(
      const AccountConfig(
        id: id,
        providerId: 'openrouter',
        label: 'OpenRouter',
        sourceType: SourceType.apiKey,
      ),
    );
    _addHistory(id, const {}, {'openrouter-credits': spent});
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'openrouter',
      fetchedAt: _fetchedAt,
      accountLabel: 'OpenRouter',
      source: 'api-key',
      credits: const [
        Credits(
          id: 'openrouter-credits',
          label: 'Credits',
          balance: 42.18,
          used: 57.82,
          limit: 100,
          currency: 'USD',
        ),
      ],
    );
  }

  void _deepSeek() {
    const id = 'demo-deepseek';
    accounts.add(
      const AccountConfig(
        id: id,
        providerId: 'deepseek',
        label: 'DeepSeek',
        sourceType: SourceType.apiKey,
      ),
    );
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'deepseek',
      fetchedAt: _fetchedAt,
      accountLabel: 'DeepSeek',
      source: 'api-key',
      credits: const [
        Credits(id: 'deepseek-balance', label: 'Balance', balance: 86.4, currency: 'CNY'),
      ],
    );
  }

  void _zai() {
    const id = 'demo-zai';
    final session = _cumulative(
      activity: _activity(51, min: 0.2, span: 1.0),
      cycleHours: 5,
      phase: 1,
      target: 22,
      seed: 11,
    );
    final mcp = _cumulative(
      activity: _activity(52, min: 0.1, span: 0.6),
      cycleHours: 720,
      phase: 300,
      target: 14,
      seed: 12,
    );
    accounts.add(
      const AccountConfig(id: id, providerId: 'zai', label: 'Z.ai', sourceType: SourceType.apiKey),
    );
    _addHistory(id, {RateWindow.sessionId: session, 'zai-mcp': mcp});
    snapshots[id] = UsageSnapshot(
      accountId: id,
      providerId: 'zai',
      fetchedAt: _fetchedAt,
      accountLabel: 'Z.ai',
      plan: 'pro',
      source: 'api-key',
      windows: [
        _window(RateWindow.sessionId, '5-hour', session, 5, 1, 300),
        _window('zai-mcp', 'MCP', mcp, 720, 300, 720 * 60),
      ],
    );
  }
}
