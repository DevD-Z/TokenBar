import 'package:tokenbar_core/tokenbar_core.dart';

/// Plain-text rendering for the terminal.
String renderSnapshot(UsageSnapshot s, DateTime now) {
  final b = StringBuffer();
  final provider = ProviderRegistry.instance.byId(s.providerId)?.displayName ?? s.providerId;
  final meta = [s.plan, s.email, s.source].whereType<String>().join(' · ');
  b.writeln('== ${s.accountLabel ?? provider} [$provider]${meta.isEmpty ? '' : '  $meta'}');
  if (s.error != null) {
    b.writeln('   ! ${s.error}');
    if (s.errorHint != null) b.writeln('     ${s.errorHint}');
  }
  for (final w in s.windows) {
    final bar = _bar(w.remainingPercent);
    final reset = w.timeUntilReset(now);
    final pace = w.paceDelta(now);
    b.write('   ${w.label.padRight(22)} $bar ${formatPercent(w.remainingPercent).padLeft(6)} left');
    b.write('  (${formatPercent(w.usedClamped)} used)');
    if (reset != null) b.write('  resets in ${formatCountdown(reset)}');
    if (pace != null && pace.abs() >= 5) {
      b.write(pace > 0 ? '  ↑${pace.round()}% ahead of pace' : '  ↓${(-pace).round()}% under pace');
    }
    b.writeln();
  }
  for (final c in s.credits) {
    b.write('   ${c.label.padRight(22)} ');
    if (c.unlimited) {
      b.write('unlimited');
    } else if (c.used != null && c.limit != null) {
      b.write('${formatMoney(c.used!, c.currency)} / ${formatMoney(c.limit!, c.currency)}');
    } else if (c.balance != null) {
      b.write(
        c.currency == null ? c.balance!.toStringAsFixed(2) : formatMoney(c.balance!, c.currency),
      );
    }
    b.writeln();
  }
  return b.toString();
}

String _bar(double remaining, {int width = 20}) {
  final filled = (remaining / 100 * width).round().clamp(0, width);
  return '[${'█' * filled}${'░' * (width - filled)}]';
}
