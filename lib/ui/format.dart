import 'package:tokenbar_core/tokenbar_core.dart';

/// Chinese labels for well-known window ids; falls back to the provider label.
String windowLabel(RateWindow w) {
  switch (w.id) {
    case RateWindow.sessionId:
      return '5 小时';
    case RateWindow.weeklyId:
      return '每周';
    case 'weekly_opus':
      return 'Opus 每周';
    case 'weekly_sonnet':
      return 'Sonnet 每周';
    case 'cursor-total':
      return '本月额度';
    case 'cursor-auto':
      return 'Auto / Composer';
    case 'cursor-api':
      return 'API 模型';
  }
  return w.label
      .replaceAll('Weekly', '每周')
      .replaceAll('5-hour', '5 小时')
      .replaceAllMapped(RegExp(r'(\d+)-hour'), (m) => '${m[1]} 小时')
      .replaceAllMapped(RegExp(r'(\d+)-day'), (m) => '${m[1]} 天');
}

String creditsLabel(Credits c) => switch (c.id) {
  'codex-credits' => 'Credits 余额',
  'codex-spend-limit' => '月度 Credits 上限',
  'claude-extra-usage' => '额外用量',
  'cursor-plan' => '本月用量',
  'cursor-on-demand' => '按需用量',
  'cursor-team-on-demand' => '团队按需用量',
  _ => c.label,
};

String countdownZh(Duration d) {
  if (d.inSeconds <= 0) return '即将重置';
  if (d.inMinutes < 1) return '不到 1 分钟';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  if (days > 0) return hours > 0 ? '$days天$hours小时' : '$days天';
  if (d.inHours > 0) return minutes > 0 ? '${d.inHours}小时$minutes分' : '${d.inHours}小时';
  return '$minutes分钟';
}

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String two(int v) => v.toString().padLeft(2, '0');

/// `14:30`, `明天 09:00`, `周五 14:30`, `11月3日 08:00`.
String resetTimeZh(DateTime at, DateTime now) {
  final local = at.toLocal();
  final n = now.toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = day.difference(today).inDays;
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (diffDays == 0) return time;
  if (diffDays == 1) return '明天 $time';
  if (diffDays > 1 && diffDays < 7) return '${_weekdays[local.weekday - 1]} $time';
  return '${local.month}月${local.day}日 $time';
}

String agoZh(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 45) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

String planLabel(String? plan) {
  if (plan == null || plan.isEmpty) return '';
  final p = plan.replaceAll('_', ' ');
  return p[0].toUpperCase() + p.substring(1);
}

String sourceLabel(String? source) => switch (source) {
  'oauth' => 'OAuth',
  'cli-rpc' => 'Codex CLI',
  'api-key' => 'API Key',
  'cursor-app' => 'Cursor 本机登录',
  'cursor-agent' => 'cursor-agent',
  'cookie' => 'Cookie',
  'remote' => '服务器',
  null => '',
  final other => other,
};

String sourceTypeLabel(String providerId, SourceType type) {
  final provider = ProviderRegistry.instance.byId(providerId);
  return switch (type) {
    SourceType.localCli => provider?.localSourceLabel ?? '本机登录',
    SourceType.apiKey => provider?.manualSourceLabel ?? 'API Key',
  };
}

String creditsValue(Credits c) {
  if (c.unlimited) return '无限';
  if (c.used != null && c.limit != null) {
    return '${formatMoney(c.used!, c.currency)} / ${formatMoney(c.limit!, c.currency)}';
  }
  if (c.balance != null) {
    return c.currency == null ? c.balance!.toStringAsFixed(2) : formatMoney(c.balance!, c.currency);
  }
  if (c.used != null) return formatMoney(c.used!, c.currency);
  return '—';
}
