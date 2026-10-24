import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../../state/app_controller.dart';
import '../format.dart';
import '../widgets/history_chart.dart';
import '../widgets/provider_badge.dart';
import '../widgets/quota_ring.dart';
import '../widgets/window_row.dart';

class AccountDetailPage extends StatefulWidget {
  const AccountDetailPage({super.key, required this.accountId});

  final String accountId;

  @override
  State<AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<AccountDetailPage> {
  static const _ranges = {
    '24 小时': Duration(hours: 24),
    '7 天': Duration(days: 7),
    '30 天': Duration(days: 30),
  };
  String _range = '7 天';
  Future<List<UsagePoint>>? _history;
  DateTime? _loadedFor;

  void _load(AppController c) {
    _loadedFor = c.lastRefresh;
    _history = c.history(widget.accountId, DateTime.now().subtract(_ranges[_range]!));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    if (_history == null || _loadedFor != c.lastRefresh) _load(c);
    final s =
        c.snapshots.where((x) => x.accountId == widget.accountId).firstOrNull ??
        c.snapshot(widget.accountId);
    final theme = Theme.of(context);

    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('账户不存在')),
      );
    }
    final provider = ProviderRegistry.instance.byId(s.providerId);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ProviderBadge(providerId: s.providerId, size: 28),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                s.accountLabel ?? provider?.displayName ?? s.providerId,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: c.refreshing ? null : c.refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: c.now,
        builder: (context, now, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (s.windows.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                          child: Wrap(
                            alignment: WrapAlignment.spaceEvenly,
                            spacing: 24,
                            runSpacing: 20,
                            children: [
                              for (final w in s.windows.take(4))
                                QuotaRing(
                                  remaining: w.remainingPercent,
                                  label: windowLabel(w),
                                  caption: w.resetsAt == null
                                      ? null
                                      : '${countdownZh(w.timeUntilReset(now)!)}后重置',
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    if (s.windows.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('全部额度', style: theme.textTheme.titleMedium),
                              const SizedBox(height: 12),
                              for (final w in s.windows) ...[
                                WindowRow(window: w, now: now),
                                _Projection(window: w, now: now),
                                const SizedBox(height: 14),
                              ],
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text('使用历史', style: theme.textTheme.titleMedium)),
                                SegmentedButton<String>(
                                  segments: [
                                    for (final r in _ranges.keys)
                                      ButtonSegment(value: r, label: Text(r)),
                                  ],
                                  selected: {_range},
                                  showSelectedIcon: false,
                                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                  onSelectionChanged: (v) => setState(() {
                                    _range = v.first;
                                    _load(c);
                                  }),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            FutureBuilder<List<UsagePoint>>(
                              future: _history,
                              builder: (context, snap) {
                                if (snap.connectionState != ConnectionState.done) {
                                  return const SizedBox(
                                    height: 220,
                                    child: Center(child: CircularProgressIndicator()),
                                  );
                                }
                                if (snap.hasError) {
                                  return SizedBox(
                                    height: 120,
                                    child: Center(child: Text('加载历史失败：${snap.error}')),
                                  );
                                }
                                return HistoryChart(
                                  points: snap.data ?? const [],
                                  range: _ranges[_range]!,
                                  windowLabels: {for (final w in s.windows) w.id: windowLabel(w)},
                                  credits: {for (final c in s.credits) c.id: c},
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Card(
                      child: Column(
                        children: [
                          _info(context, '服务', provider?.displayName ?? s.providerId),
                          if (s.plan != null) _info(context, '套餐', planLabel(s.plan)),
                          if (s.email != null) _info(context, '账户', s.email!),
                          if (s.source != null) _info(context, '数据来源', sourceLabel(s.source)),
                          if (s.origin != null) _info(context, '采集设备', s.origin!),
                          _info(
                            context,
                            '更新时间',
                            '${resetTimeZh(s.fetchedAt, now)}（${agoZh(s.fetchedAt, now)}）',
                          ),
                          for (final c in s.credits)
                            _info(context, creditsLabel(c), creditsValue(c)),
                          for (final e in s.extras.entries) _info(context, e.key, e.value),
                          if (s.error != null)
                            _info(
                              context,
                              '最近错误',
                              [s.error, s.errorHint].whereType<String>().join('\n'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(BuildContext context, String label, String value) => ListTile(
    dense: true,
    title: Text(label),
    trailing: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SelectableText(
        value,
        textAlign: TextAlign.right,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _Projection extends StatelessWidget {
  const _Projection({required this.window, required this.now});

  final RateWindow window;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final projected = window.projectedUsedAtReset(now);
    final elapsed = window.elapsedFraction(now);
    if (projected == null || elapsed == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    String text;
    if (projected >= 100 && window.usedClamped < 100) {
      // Time at which the window runs out at the current average rate.
      final total = Duration(minutes: window.windowMinutes!);
      final elapsedTime = total * elapsed;
      final rate = window.usedClamped / elapsedTime.inSeconds;
      final secondsLeft = ((100 - window.usedClamped) / rate).round();
      text = '按当前速度约 ${countdownZh(Duration(seconds: secondsLeft))}后用完（早于重置）';
    } else if (window.usedClamped >= 100) {
      text = '已用完，等待重置';
    } else {
      text = '按当前速度，重置时预计用掉 ${formatPercent(projected)}';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
