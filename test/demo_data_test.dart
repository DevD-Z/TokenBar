import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/demo/demo_data.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

void main() {
  final data = DemoData(DateTime(2026, 6, 15, 14, 30));

  test('demo accounts have a snapshot and only fictional e-mail addresses', () {
    expect(data.accounts, isNotEmpty);
    for (final a in data.accounts) {
      final s = data.snapshots[a.id]!;
      expect(ProviderRegistry.instance.byId(a.providerId), isNotNull);
      expect(s.hasData, isTrue);
      expect(s.hasError, isFalse);
      if (s.email != null) expect(s.email, matches(RegExp(r'@example\.(com|org)$')));
      expect(a.secret, isNull);
    }
  });

  test('windows are valid and match the newest history sample', () {
    for (final s in data.snapshots.values) {
      final last = data.history
          .where((p) => p.accountId == s.accountId)
          .fold<UsagePoint?>(null, (a, b) => a == null || b.at.isAfter(a.at) ? b : a);
      for (final w in s.windows) {
        expect(w.usedPercent, inInclusiveRange(0, 100));
        expect(w.resetsAt!.isAfter(DateTime(2026, 6, 15, 14, 30)), isTrue);
        expect(last!.used[w.id], closeTo(w.usedPercent, 0.06), reason: '${s.accountId}/${w.id}');
      }
    }
  });

  test('history spans a month of hourly samples', () {
    final claude = data.history.where((p) => p.accountId == 'demo-claude').toList();
    expect(claude.length, DemoData.hours);
    expect(claude.last.at.difference(claude.first.at), const Duration(hours: DemoData.hours - 1));
    expect(claude.last.spend['claude-extra-usage'], closeTo(12.4, 0.01));
  });
}
