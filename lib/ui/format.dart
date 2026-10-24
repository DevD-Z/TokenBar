import 'package:tokenbar_core/tokenbar_core.dart';

import '../l10n/app_localizations.dart';

/// Label for a quota window. Known ids get fixed text; other labels come from
/// the provider and are translated only where they use a common term.
String windowLabel(AppLocalizations l, RateWindow w) {
  switch (w.id) {
    case RateWindow.sessionId:
      return l.labelFiveHour;
    case RateWindow.weeklyId:
      return l.labelWeekly;
    case 'weekly_opus':
      return l.windowOpusWeekly;
    case 'weekly_sonnet':
      return l.windowSonnetWeekly;
    case 'cursor-total':
      return l.cursorMonthlyQuota;
    case 'cursor-auto':
      return 'Auto / Composer';
    case 'cursor-api':
      return l.cursorApiModels;
  }
  return _coreLabel(l, w.label);
}

/// Provider-supplied labels (Chinese in core) with the common period words
/// translated. Labels with no known term are returned unchanged.
String _coreLabel(AppLocalizations l, String text) {
  final exact = switch (text) {
    'Weekly' || '每周' => l.labelWeekly,
    'Monthly' || '每月' => l.labelMonthly,
    'Daily' || '每日' => l.labelDaily,
    'Today' || '今日' => l.labelToday,
    'This month' || '本月' => l.labelThisMonth,
    '额度' => l.labelQuota,
    _ => null,
  };
  if (exact != null) return exact;
  var out = text
      .replaceAll('Weekly', l.labelWeekly)
      .replaceAll('每周', l.labelWeekly)
      .replaceAll('Monthly', l.labelMonthly)
      .replaceAll('每月', l.labelMonthly)
      .replaceAll('Daily', l.labelDaily)
      .replaceAll('每日', l.labelDaily)
      .replaceAll('5 小时', l.labelFiveHour);
  out = out.replaceAllMapped(RegExp(r'(\d+)-hour'), (m) => l.labelHours(int.parse(m[1]!)));
  out = out.replaceAllMapped(RegExp(r'(\d+)-day'), (m) => l.labelDays(int.parse(m[1]!)));
  return out;
}

String creditsLabel(AppLocalizations l, Credits c) => switch (c.id) {
  'codex-credits' => l.creditsBalance,
  'codex-spend-limit' => l.creditsSpendLimit,
  'claude-extra-usage' => l.extraUsage,
  'cursor-plan' => l.cursorPlanUsage,
  'cursor-on-demand' => l.cursorOnDemand,
  'cursor-team-on-demand' => l.cursorTeamOnDemand,
  _ => c.label,
};

/// `2d 3h`, `5h 4m`, `45m` (or the localized equivalents).
String countdownLabel(AppLocalizations l, Duration d) {
  if (d.inSeconds <= 0) return l.resetImminent;
  if (d.inMinutes < 1) return l.lessThanMinute;
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  if (days > 0) {
    return hours > 0 ? l.countdownDaysHours(days, hours) : l.countdownDays(days);
  }
  if (d.inHours > 0) {
    return minutes > 0 ? l.countdownHoursMinutes(d.inHours, minutes) : l.countdownHours(d.inHours);
  }
  return l.countdownMinutes(minutes);
}

/// "Resets in 2h 5m"; "Resetting soon" once the reset time has passed.
String resetsInLabel(AppLocalizations l, Duration d) =>
    d.inSeconds <= 0 ? l.resetImminent : l.resetsIn(countdownLabel(l, d));

String two(int v) => v.toString().padLeft(2, '0');

String _weekday(AppLocalizations l, int weekday) => switch (weekday) {
  DateTime.monday => l.weekdayMon,
  DateTime.tuesday => l.weekdayTue,
  DateTime.wednesday => l.weekdayWed,
  DateTime.thursday => l.weekdayThu,
  DateTime.friday => l.weekdayFri,
  DateTime.saturday => l.weekdaySat,
  _ => l.weekdaySun,
};

/// `14:30`, `明天 09:00`, `周五 14:30`, `11月3日 08:00`.
String resetTimeLabel(AppLocalizations l, DateTime at, DateTime now) {
  final local = at.toLocal();
  final n = now.toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = day.difference(today).inDays;
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (diffDays == 0) return time;
  if (diffDays == 1) return l.resetTomorrow(time);
  if (diffDays > 1 && diffDays < 7) return l.resetWeekday(_weekday(l, local.weekday), time);
  return l.resetDate(l.monthDay(local.month, local.day), time);
}

/// `刚刚`, `5 分钟前`, `3 小时前`, `2 天前` (or the English equivalents).
String agoLabel(AppLocalizations l, DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 45) return l.justNow;
  if (d.inMinutes < 60) return l.minutesAgo(d.inMinutes);
  if (d.inHours < 24) return l.hoursAgo(d.inHours);
  return l.daysAgo(d.inDays);
}

String planLabel(String? plan) {
  if (plan == null || plan.isEmpty) return '';
  final p = plan.replaceAll('_', ' ');
  return p[0].toUpperCase() + p.substring(1);
}

String sourceLabel(AppLocalizations l, String? source) => switch (source) {
  'oauth' => 'OAuth',
  'cli-rpc' => 'Codex CLI',
  'api-key' => 'API Key',
  'cursor-app' => l.sourceCursorLocal,
  'cursor-agent' => 'cursor-agent',
  'cookie' => 'Cookie',
  'remote' => l.sourceServer,
  null => '',
  final other => other,
};

String sourceTypeLabel(AppLocalizations l, String providerId, SourceType type) {
  final provider = ProviderRegistry.instance.byId(providerId);
  return switch (type) {
    SourceType.localCli => provider?.localSourceLabel ?? l.localLogin,
    SourceType.apiKey => provider?.manualSourceLabel ?? 'API Key',
  };
}

String creditsValue(AppLocalizations l, Credits c) {
  if (c.unlimited) return l.unlimited;
  if (c.used != null && c.limit != null) {
    return '${formatMoney(c.used!, c.currency)} / ${formatMoney(c.limit!, c.currency)}';
  }
  if (c.balance != null) {
    return c.currency == null ? c.balance!.toStringAsFixed(2) : formatMoney(c.balance!, c.currency);
  }
  if (c.used != null) return formatMoney(c.used!, c.currency);
  return '—';
}
