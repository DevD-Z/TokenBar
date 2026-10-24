import 'dart:convert';
import 'dart:math' as math;

import '../../models/account.dart';
import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

// ------------------------------------------------------------------ helpers

Never _fail(String message, {String? hint}) => throw ProviderException(message, hint: hint);

double? _finite(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final d = double.tryParse(v.trim());
    return d != null && d.isFinite ? d : null;
  }
  return null;
}

DateTime _epochSeconds(double s) =>
    DateTime.fromMillisecondsSinceEpoch((s * 1000).round(), isUtc: true);

DateTime _epochAuto(double v) =>
    v > 1e10 ? DateTime.fromMillisecondsSinceEpoch(v.round(), isUtc: true) : _epochSeconds(v);

DateTime _addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  return DateTime.utc(year, month, math.min(d.day, lastDay), d.hour, d.minute, d.second);
}

String _group(String digits) {
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// en-US style number with up to [maxDigits] decimals, trailing zeros dropped.
String _fmt(double v, [int maxDigits = 0]) {
  var text = v.abs().toStringAsFixed(maxDigits);
  var frac = '';
  final dot = text.indexOf('.');
  if (dot >= 0) {
    frac = text.substring(dot).replaceFirst(RegExp(r'0+$'), '');
    if (frac == '.') frac = '';
    text = text.substring(0, dot);
  }
  final sign = v < 0 && (text != '0' || frac.isNotEmpty) ? '-' : '';
  return '$sign${_group(text)}$frac';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _monthDay(DateTime d) {
  final u = d.toUtc();
  return '${_months[u.month - 1]} ${u.day}';
}

String _titleCase(String s) =>
    s.toLowerCase().replaceAllMapped(RegExp(r'\b[a-z]'), (m) => m[0]!.toUpperCase());

String _capitalizeWords(String s, Pattern separator) => s
    .split(separator)
    .where((p) => p.isNotEmpty)
    .map((p) => p[0].toUpperCase() + p.substring(1))
    .join(' ');

/// Abstract base for providers that take a pasted browser Cookie.
abstract class _CookieProvider extends UsageProvider {
  String get cookieLabel;
  String get cookieHint;
  List<String> get cookieEnv => const [];

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  List<ProviderField> get fields => [
    ProviderField.cookie(label: cookieLabel, hint: cookieHint, envVars: cookieEnv),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  String cookieOf(AccountConfig account) =>
      normalizeCookieHeader(FieldValues.of(this, account).secret);
}

// --------------------------------------------------------------- Perplexity

const _pplxCookieNames = [
  '__Secure-authjs.session-token',
  'authjs.session-token',
  '__Secure-next-auth.session-token',
  'next-auth.session-token',
];

/// Cookie headers to try, in CodexBar's priority order. A bare token is tried
/// under every session cookie name; a header yields only its matched cookie
/// (chunked `name.0`, `name.1`, ... cookies are joined in order).
List<String> perplexityCookieCandidates(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  if (!text.contains('=') && !text.contains(';')) {
    return [for (final name in _pplxCookieNames) '$name=$text'];
  }
  final pairs = <String, ({String name, String value})>{};
  final header = text.replaceFirst(RegExp(r'^cookie:\s*', caseSensitive: false), '');
  for (final part in header.split(';')) {
    final i = part.indexOf('=');
    if (i < 1) continue;
    final name = part.substring(0, i).trim();
    final value = part.substring(i + 1).trim();
    if (value.isNotEmpty) pairs[name.toLowerCase()] = (name: name, value: value);
  }
  for (final expected in _pplxCookieNames) {
    final direct = pairs[expected.toLowerCase()];
    if (direct != null) return ['${direct.name}=${direct.value}'];
    final prefix = '${expected.toLowerCase()}.';
    final chunks = <int, ({String name, String value})>{};
    for (final e in pairs.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final suffix = e.key.substring(prefix.length);
      if (!RegExp(r'^[+-]?\d+$').hasMatch(suffix)) continue;
      final index = int.tryParse(suffix);
      if (index != null && index >= 0) chunks[index] = e.value;
    }
    final order = chunks.keys.toList()..sort();
    if (order.isNotEmpty && order.indexed.every((p) => p.$1 == p.$2)) {
      final first = chunks[0]!.name;
      final base = first.substring(0, first.lastIndexOf('.'));
      return ['$base=${order.map((i) => chunks[i]!.value).join()}'];
    }
  }
  return const [];
}

String _desc(double used, double total, String unit) => '${used.round()}/${total.truncate()} $unit';

({List<RateWindow> windows, Map<String, String> extras, String? plan}) parsePerplexityCredits(
  Map<String, Object?> data,
  DateTime now,
) {
  Never fail() => _fail('Perplexity 用量数据解析失败: 额度字段无效');
  double required(String snake, String camel) {
    final v = data[snake] ?? data[camel];
    return v is num && v.isFinite ? v.toDouble() : fail();
  }

  required('balance_cents', 'balanceCents');
  final renewal = required('renewal_date_ts', 'renewalDateTs');
  final purchasedField = required('current_period_purchased_cents', 'currentPeriodPurchasedCents');
  var remaining = required('total_usage_cents', 'totalUsageCents');
  final rawGrants = asList(data['credit_grants'] ?? data['creditGrants']) ?? fail();
  final grants = <({String type, double amount, double? expiry})>[];
  for (final raw in rawGrants) {
    final g = asMap(raw) ?? fail();
    final type = g['type'] is String ? g['type']! as String : fail();
    final amountRaw = g['amount_cents'] ?? g['amountCents'];
    if (amountRaw is! num || !amountRaw.isFinite) fail();
    final expiryRaw = g['expires_at_ts'] ?? g['expiresAtTs'];
    final double? expiry = expiryRaw == null
        ? null
        : (expiryRaw is num && expiryRaw.isFinite ? expiryRaw.toDouble() : fail());
    grants.add((type: type, amount: amountRaw.toDouble(), expiry: expiry));
  }

  double total(Iterable<({String type, double amount, double? expiry})> gs) =>
      math.max<double>(0, gs.fold<double>(0, (t, g) => t + g.amount));

  final nowSeconds = now.millisecondsSinceEpoch / 1000;
  final recurring = total(grants.where((g) => g.type == 'recurring'));
  final promoGrants = grants
      .where((g) => g.type == 'promotional' && (g.expiry ?? double.infinity) > nowSeconds)
      .toList();
  final promo = total(promoGrants);
  final purchased = math.max<double>(
    total(grants.where((g) => g.type == 'purchased')),
    math.max(purchasedField, 0),
  );
  final recurringUsed = math.min(remaining, recurring);
  remaining -= recurringUsed;
  final purchasedUsed = math.min(remaining, purchased);
  remaining -= purchasedUsed;
  final promoUsed = math.min(remaining, promo);
  final expiries = promoGrants.map((g) => g.expiry).whereType<double>();
  final promoExpiry = expiries.isEmpty ? null : expiries.reduce(math.min);

  final renewalDate = _epochSeconds(renewal);
  final windows = <RateWindow>[];
  final extras = <String, String>{};
  if (recurring > 0) {
    windows.add(
      quotaWindow(
        'perplexity-credits',
        '积分',
        usedPercent: pct(recurringUsed, recurring),
        resetsAt: renewalDate,
      ),
    );
    extras['积分'] = _desc(recurringUsed, recurring, 'credits');
  } else if (promo <= 0 && purchased <= 0) {
    windows.add(quotaWindow('perplexity-credits', '积分', usedPercent: 100, resetsAt: renewalDate));
    extras['积分'] = '0/0 credits';
  }
  final bonus = _desc(promoUsed, promo, 'bonus');
  windows.add(quotaWindow('perplexity-bonus', '赠送积分', usedPercent: pct(promoUsed, promo)));
  extras['赠送积分'] = promoExpiry == null
      ? bonus
      : '$bonus · exp. ${_monthDay(_epochSeconds(promoExpiry))}';
  windows.add(
    quotaWindow('perplexity-purchased', '购买积分', usedPercent: pct(purchasedUsed, purchased)),
  );
  extras['购买积分'] = _desc(purchasedUsed, purchased, 'credits');
  final plan = recurring <= 0 ? null : (recurring < 5000 ? 'Pro' : 'Max');
  return (windows: windows, extras: extras, plan: plan);
}

class PerplexityProvider extends _CookieProvider {
  @override
  String get id => 'perplexity';
  @override
  String get displayName => 'Perplexity';
  @override
  int get brandColor => 0xFF20B2AA;
  @override
  String get cookieLabel => 'perplexity.ai Cookie';
  @override
  String get cookieHint => '__Secure-authjs.session-token=... 或只粘贴 token 值';
  @override
  List<String> get cookieEnv => const ['PERPLEXITY_COOKIE', 'PERPLEXITY_SESSION_TOKEN'];
  @override
  String get setupHint =>
      '登录 perplexity.ai 后，在开发者工具的网络请求里复制 Cookie 请求头（含 __Secure-authjs.session-token），或只粘贴该 token 的值。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final candidates = perplexityCookieCandidates(FieldValues.of(this, account).secret);
    if (candidates.isEmpty) {
      _fail('Perplexity 会话 Token 缺失或无效', hint: '请登录 perplexity.ai 后粘贴 Cookie');
    }
    var rejected = false;
    for (final cookie in candidates) {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default'),
        headers: {
          'Cookie': cookie,
          'Origin': 'https://www.perplexity.ai',
          'Referer': 'https://www.perplexity.ai/account/usage',
          'User-Agent': browserUserAgent,
        },
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 401 || r.statusCode == 403) {
        rejected = true;
        continue;
      }
      if (!r.ok) {
        throw ProviderException(
          'Perplexity API 错误: HTTP ${r.statusCode}',
          statusCode: r.statusCode,
        );
      }
      final data = asMap(r.json) ?? _fail('Perplexity 用量数据解析失败: 返回的不是有效 JSON');
      final parsed = parsePerplexityCredits(data, ctx.now());
      return snapshot(
        account,
        ctx,
        plan: parsed.plan,
        source: 'web',
        windows: parsed.windows,
        extras: parsed.extras,
      );
    }
    if (rejected) {
      _fail('Perplexity 会话已失效', hint: '重新登录 perplexity.ai 后复制新的 Cookie');
    }
    _fail('Perplexity 会话 Token 缺失或无效', hint: '请登录 perplexity.ai 后粘贴 Cookie');
  }
}

// ------------------------------------------------------------------- Manus

/// `session_id` value from a Cookie header, or a bare token; null when absent.
String? manusSessionToken(String raw) {
  final header = raw.trim();
  final match = RegExp(
    r'(?:^|;)\s*session_id\s*=\s*([^;]+)',
    caseSensitive: false,
  ).firstMatch(header);
  if (match != null) return match.group(1)!.trim();
  if (header.isNotEmpty && !header.contains('=') && !header.contains(';')) return header;
  return null;
}

({List<RateWindow> windows, Map<String, String> extras, String? plan}) parseManusCredits(
  Map<String, Object?> root,
) {
  Never fail() => _fail('Manus 返回数据缺少积分字段', hint: '稍后重试，或重新登录 manus.im');
  final data =
      asMap(
        root['data'] ?? root['result'] ?? root['response'] ?? root['availableCredits'] ?? root,
      ) ??
      fail();
  const creditKeys = [
    'totalCredits',
    'freeCredits',
    'periodicCredits',
    'addonCredits',
    'refreshCredits',
    'maxRefreshCredits',
    'proMonthlyCredits',
    'eventCredits',
  ];
  if (!creditKeys.any(data.containsKey)) fail();

  double number(String key) {
    final v = data[key];
    final n = v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);
    return n != null && n.isFinite ? n : 0;
  }

  final total = number('totalCredits');
  final free = number('freeCredits');
  final monthly = number('proMonthlyCredits');
  final periodic = number('periodicCredits');
  final refresh = number('refreshCredits');
  final maxRefresh = number('maxRefreshCredits');

  final reset = data['nextRefreshTime'];
  DateTime? resetAt;
  if (reset is num) {
    resetAt = _epochSeconds(reset.toDouble() + 978307200);
  } else if (reset is String && RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(reset)) {
    resetAt = DateTime.tryParse(reset)?.toUtc();
  }

  final windows = <RateWindow>[];
  final extras = <String, String>{};
  if (monthly > 0) {
    windows.add(
      quotaWindow('manus-monthly', '月度积分', usedPercent: pct(monthly - periodic, monthly)),
    );
    extras['月度积分'] = 'Total ${_fmt(total)} • Free ${_fmt(free)}';
  }
  if (maxRefresh > 0) {
    final interval = asString(data['refreshInterval']);
    windows.add(
      quotaWindow(
        'manus-daily',
        '每日刷新',
        usedPercent: pct(maxRefresh - refresh, maxRefresh),
        resetsAt: resetAt,
      ),
    );
    final head = interval == null ? '' : '${_titleCase(interval)}: ';
    extras['每日刷新'] = '$head${_fmt(refresh)} / ${_fmt(maxRefresh)}';
  }
  return (windows: windows, extras: extras, plan: '余额 ${_fmt(total)} credits');
}

class ManusProvider extends _CookieProvider {
  @override
  String get id => 'manus';
  @override
  String get displayName => 'Manus';
  @override
  int get brandColor => 0xFF34322D;
  @override
  String get cookieLabel => 'manus.im Cookie';
  @override
  String get cookieHint => 'session_id=... 或只粘贴 session_id 的值';
  @override
  List<String> get cookieEnv => const ['MANUS_SESSION_TOKEN', 'MANUS_SESSION_ID', 'MANUS_COOKIE'];
  @override
  String get setupHint => '登录 manus.im 后，复制任一请求的 Cookie 请求头（含 session_id），或只粘贴 session_id 的值。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final token = manusSessionToken(FieldValues.of(this, account).secret);
    if (token == null) _fail('Manus session Cookie 无效', hint: '粘贴包含 session_id 的 Cookie');
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://api.manus.im/user.v1.UserService/GetAvailableCredits'),
      method: 'POST',
      headers: {
        'Authorization': 'Bearer $token',
        'Origin': 'https://manus.im',
        'Referer': 'https://manus.im/',
        'Connect-Protocol-Version': '1',
        'User-Agent': browserUserAgent,
      },
      body: const <String, Object>{},
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      _fail('Manus session token 无效或已过期', hint: '重新登录 manus.im 后复制新的 session_id');
    }
    if (!r.ok) {
      throw ProviderException('Manus API 错误: HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    final root = asMap(r.json) ?? _fail('Manus 响应不是有效 JSON');
    final parsed = parseManusCredits(root);
    return snapshot(
      account,
      ctx,
      plan: parsed.plan,
      source: 'web',
      windows: parsed.windows,
      extras: parsed.extras,
    );
  }
}

// ------------------------------------------------------------------ Ollama

const _ollamaSessionNames = {
  'session',
  '__Secure-session',
  'ollama_session',
  '__Host-ollama_session',
  'wos-session',
  '__Secure-next-auth.session-token',
  'next-auth.session-token',
};

bool _hasOllamaSession(String cookie) {
  for (final part in cookie.split(';')) {
    final name = part.split('=').first.trim();
    if (_ollamaSessionNames.contains(name) ||
        name.startsWith('__Secure-next-auth.session-token.') ||
        name.startsWith('next-auth.session-token.')) {
      return true;
    }
  }
  return false;
}

/// Parses `/api/balance` (USD amounts, optional calendar reset).
({RateWindow? primary, List<Credits> credits, Map<String, String> extras}) parseOllamaBalance(
  Map<String, Object?> data,
) {
  Never fail() => _fail('Ollama 返回了无法识别的余额数据');
  double amount(Object? value) {
    var v = value;
    if (v is String && RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(v.trim())) v = double.parse(v.trim());
    if (v is! num || !v.isFinite) fail();
    return v.toDouble();
  }

  final purchased = data['purchased'];
  final included = data['included'];
  if (purchased == null && included == null) fail();
  final credits = <Credits>[];
  final extras = <String, String>{};
  if (purchased != null) {
    final balance = amount((asMap(purchased) ?? fail())['balance_usd']);
    credits.add(balanceRow('ollama-balance', balance, label: 'Credit 余额'));
    extras['Credit 余额'] = moneyText(balance, 'USD');
  }
  RateWindow? primary;
  if (included != null) {
    final inc = asMap(included) ?? fail();
    final allowance = amount(inc['allowance_usd']);
    final balance = amount(inc['balance_usd']);
    if (allowance < 0) fail();
    final used = math.max(0, allowance - balance).toDouble();
    credits.add(spendRow('ollama-included', used, limit: allowance, label: '月度额度'));
    extras['月度已用'] = moneyText(used, 'USD');
    DateTime? resetsAt;
    final period = inc['period'];
    if (period != null) {
      final until = (asMap(period) ?? fail())['until'];
      if (until != null) {
        final text = until is String ? until : fail();
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$')
            .hasMatch(text)) {
          fail();
        }
        final parsed = DateTime.tryParse(text) ?? fail();
        final day = int.parse(text.substring(8, 10));
        if (day > DateTime.utc(parsed.year, parsed.month + 1, 0).day) fail();
        resetsAt = parsed.toUtc();
      }
    }
    if (allowance > 0) {
      primary = quotaWindow(
        'ollama-monthly',
        '每月',
        usedPercent: pct(used, allowance),
        resetsAt: resetsAt,
        windowMinutes: 43200,
      );
    }
  }
  return (primary: primary, credits: credits, extras: extras);
}

String? _firstGroup(String html, String pattern) =>
    RegExp(pattern, dotAll: true, caseSensitive: false).firstMatch(html)?.group(1)?.trim();

const _amountPattern = r'((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)';

String? _ollamaBlock(String html, String label) {
  final start = RegExp('>\\s*${RegExp.escape(label)}\\s*<', caseSensitive: false).firstMatch(html);
  if (start == null) return null;
  final tail = html.substring(start.end);
  var end = tail.length;
  for (final other in const [
    'Monthly usage',
    'Free usage',
    'Session usage',
    'Hourly usage',
    'Weekly usage',
  ]) {
    if (other == label) continue;
    final m = RegExp('>\\s*${RegExp.escape(other)}\\s*<', caseSensitive: false).firstMatch(tail);
    if (m != null && m.start < end) end = m.start;
  }
  return tail.substring(0, math.min(end, 4000));
}

double? _ollamaPercent(String block) {
  final used = RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*%\s*used', caseSensitive: false).firstMatch(block);
  if (used != null) return double.tryParse(used.group(1)!);
  final dollars = RegExp(
    '\\\$$_amountPattern\\s+of\\s+\\\$$_amountPattern\\s+used',
    caseSensitive: false,
  ).firstMatch(block);
  if (dollars != null) {
    final u = double.tryParse(dollars.group(1)!.replaceAll(',', ''));
    final l = double.tryParse(dollars.group(2)!.replaceAll(',', ''));
    if (u != null && l != null && l > 0) return u / l * 100;
  }
  final width = RegExp(r'width:\s*([0-9]+(?:\.[0-9]+)?)%').firstMatch(block);
  return width == null ? null : double.tryParse(width.group(1)!);
}

({double percent, DateTime? resetsAt, int? windowMinutes})? _ollamaUsage(
  String html,
  String label,
  int? windowMinutes,
) {
  final block = _ollamaBlock(html, label);
  if (block == null) return null;
  final percent = _ollamaPercent(block);
  if (percent == null) return null;
  final dataTime = RegExp(r'data-time="([^"]+)"').firstMatch(block)?.group(1);
  return (
    percent: percent.clamp(0, 100).toDouble(),
    resetsAt: dataTime == null ? null : DateTime.tryParse(dataTime)?.toUtc(),
    windowMinutes: windowMinutes,
  );
}

String _stripScripts(String html) => html
    .replaceAll(RegExp(r'<script[\s\S]*?</script\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<style[\s\S]*?</style\s*>', caseSensitive: false), '')
    .replaceAll('&nbsp;', ' ');

List<Credits> _ollamaWallet(String html, Map<String, String> extras) {
  final page = _stripScripts(html);
  final heading = RegExp(
    r'<h[1-6][^>]*>\s*Usage credits(?:\s*<span[^>]*>[^<]*</span\s*>)?\s*</h[1-6]\s*>',
    caseSensitive: false,
  ).firstMatch(page);
  if (heading == null) return const [];
  var wallet = page.substring(heading.end);
  for (final stop in [
    RegExp('</section\\s*>', caseSensitive: false),
    RegExp(r'<h[1-6]\b', caseSensitive: false),
  ]) {
    final m = stop.firstMatch(wallet);
    if (m != null) wallet = wallet.substring(0, m.start);
  }
  double? dollars(String pattern) {
    final raw = RegExp(pattern, caseSensitive: false, dotAll: true).firstMatch(wallet)?.group(1);
    return raw == null ? null : double.tryParse(raw.replaceAll(RegExp(r'[$,]'), ''));
  }

  final balance = dollars(
    '^\\s*(?:<div[^>]*>\\s*)*<span[^>]*>\\s*\\\$$_amountPattern\\s*</span\\s*>',
  );
  final used = dollars(
    '<span[^>]*>\\s*Monthly credits used\\s*</span\\s*>\\s*<span[^>]*>\\s*\\\$$_amountPattern\\s*</span\\s*>',
  );
  final credits = <Credits>[];
  if (balance != null) credits.add(balanceRow('ollama-balance', balance, label: 'Credit 余额'));
  if (used != null) credits.add(spendRow('ollama-monthly-credits', used, label: '月度 Credits 已用'));
  if (credits.isEmpty) return const [];
  final refill = _firstGroup(wallet, r'<p[^>]*>\s*Refills\s+(to\s+\$[^<]{1,160}?)\s*</p\s*>');
  if (refill != null) extras['下次补充'] = refill;
  return credits;
}

({
  String? plan,
  String? email,
  RateWindow? primary,
  RateWindow? weekly,
  List<Credits> credits,
  Map<String, String> extras,
  bool signedOut,
  bool hasUsage,
})
parseOllamaSettings(String html) {
  final plan =
      _firstGroup(html, r'Included usage\s*</span>\s*<span[^>]*>([^<]+)</span') ??
      _firstGroup(html, r'Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>') ??
      _firstGroup(html, r'<h[1-6][^>]*>\s*Usage credits\s*<span[^>]*>\s*([^<]+)</span');
  final email = _firstGroup(html, r'id="header-email"[^>]*>([^<]+)<');
  final monthly =
      _ollamaUsage(html, 'Monthly usage', 43200) ?? _ollamaUsage(html, 'Free usage', 43200);
  final session =
      _ollamaUsage(html, 'Session usage', 300) ?? _ollamaUsage(html, 'Hourly usage', null);
  final weekly = _ollamaUsage(html, 'Weekly usage', 10080);
  final extras = <String, String>{};
  final credits = _ollamaWallet(html, extras);
  final lower = html.toLowerCase();
  final signedOut =
      lower.contains('<form') &&
      (lower.contains('sign in to ollama') ||
          lower.contains('log in to ollama') ||
          lower.contains('/api/auth/signin') ||
          lower.contains('/auth/signin') ||
          lower.contains('action="/login"') ||
          lower.contains('href="/login"'));
  final primaryUsage = monthly ?? session;
  final primary = primaryUsage == null
      ? null
      : quotaWindow(
          primaryUsage.windowMinutes == 43200 ? 'ollama-monthly' : RateWindow.sessionId,
          primaryUsage.windowMinutes == 43200 ? '每月' : '会话',
          usedPercent: primaryUsage.percent,
          resetsAt: primaryUsage.resetsAt,
          windowMinutes: primaryUsage.windowMinutes,
        );
  final weeklyWindow = weekly == null
      ? null
      : quotaWindow(
          RateWindow.weeklyId,
          '每周',
          usedPercent: weekly.percent,
          resetsAt: weekly.resetsAt,
          windowMinutes: weekly.windowMinutes,
        );
  return (
    plan: plan,
    email: email != null && email.contains('@') ? email : null,
    primary: primary,
    weekly: weeklyWindow,
    credits: credits,
    extras: extras,
    signedOut: signedOut,
    hasUsage: primary != null || weeklyWindow != null || credits.isNotEmpty,
  );
}

class OllamaProvider extends UsageProvider {
  static const _host = 'https://ollama.com';

  @override
  String get id => 'ollama';
  @override
  String get displayName => 'Ollama';
  @override
  int get brandColor => 0xFF888888;
  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];
  @override
  String get setupHint =>
      'Ollama API Key（到 ollama.com/settings/keys 创建，推荐）；或登录 ollama.com 后粘贴 Cookie 请求头（含 session / wos-session 等）。两者都填时优先用 API Key。';

  @override
  List<ProviderField> get fields => [
    ProviderField.apiKey(
      label: 'Ollama API Key',
      required: false,
      envVars: const ['OLLAMA_API_KEY', 'OLLAMA_KEY'],
      help: '在 https://ollama.com/settings/keys 创建；与下方 Cookie 二选一',
    ),
    const ProviderField(
      key: 'cookie',
      label: 'ollama.com Cookie',
      multiline: true,
      required: false,
      help: '浏览器登录 ollama.com → 开发者工具 → 网络 → 任一请求的 Cookie 请求头',
    ),
  ];

  @override
  String get manualSourceLabel => '手动输入 API Key / Cookie';

  @override
  String? validateManual(FieldValues values) =>
      values[ProviderField.secretKey] == null && values['cookie'] == null
      ? '请填写 API Key 或 Cookie'
      : null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final apiKey = v[ProviderField.secretKey];
    if (apiKey != null) return _fetchApi(account, ctx, bareToken(apiKey));
    final cookie = v['cookie'];
    if (cookie != null) return _fetchCookie(account, ctx, cookie);
    _fail('未填写 Ollama 的 API Key 或 Cookie', hint: '在账户设置中填写');
  }

  Future<UsageSnapshot> _fetchApi(AccountConfig account, FetchContext ctx, String key) async {
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$_host/api/balance'),
      headers: {'Authorization': 'Bearer $key'},
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      _fail('Ollama API Key 无效或已过期', hint: '到 ollama.com/settings/keys 重新创建');
    }
    if (r.statusCode == 429) {
      throw ProviderException('Ollama 请求过于频繁 (HTTP 429)', hint: '稍后再试', statusCode: 429);
    }
    if (r.statusCode >= 500) {
      throw ProviderException('Ollama 服务暂不可用 (HTTP ${r.statusCode})', statusCode: r.statusCode);
    }
    if (!r.ok) throw ProviderException('Ollama 返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
    final data = asMap(r.json) ?? _fail('Ollama 返回了无法识别的余额数据');
    final parsed = parseOllamaBalance(data);
    return snapshot(
      account,
      ctx,
      plan: 'API Key',
      source: 'api-key',
      windows: [?parsed.primary],
      credits: parsed.credits,
      extras: parsed.extras,
    );
  }

  Future<UsageSnapshot> _fetchCookie(AccountConfig account, FetchContext ctx, String raw) async {
    final cookie = cookieHeaderFor(raw, '__Secure-session');
    if (!_hasOllamaSession(cookie)) {
      _fail(
        'Ollama Cookie 中没有会话 Cookie',
        hint: '需要包含 session、wos-session 或 __Secure-session 等 Cookie',
      );
    }
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$_host/settings'),
      headers: {
        'Cookie': cookie,
        'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'user-agent': browserUserAgent,
        'accept-language': 'en-US,en;q=0.9',
        'origin': _host,
        'referer': '$_host/settings',
      },
      timeout: const Duration(seconds: 20),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      _fail('Ollama 会话 Cookie 已过期', hint: '到 ollama.com/signin 重新登录后复制 Cookie');
    }
    if (!r.ok) {
      throw ProviderException('Ollama 设置页返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    final parsed = parseOllamaSettings(r.body);
    if (!parsed.hasUsage) {
      if (parsed.signedOut) {
        _fail('Ollama 会话 Cookie 已过期', hint: '到 ollama.com/signin 重新登录后复制 Cookie');
      }
      _fail('Ollama 页面中没有用量数据', hint: '确认 Cookie 来自已登录的 ollama.com/settings');
    }
    return snapshot(
      account,
      ctx,
      plan: parsed.plan,
      email: parsed.email,
      source: 'web',
      windows: [?parsed.primary, ?parsed.weekly],
      credits: parsed.credits,
      extras: parsed.extras,
    );
  }
}

// ----------------------------------------------------------------- Mistral

typedef MistralBillingTotals = ({
  double cost,
  String currency,
  String symbol,
  int input,
  int output,
  int cached,
  int models,
});

String _priceKey(String? event, String metric, String group, String? zone, String? tier) =>
    [event ?? '', metric, group, zone ?? '', tier ?? ''].join('|');

Map<String, Object?> _mistralAt(Map<String, Object?> root, List<String> path) {
  Object? cur = root;
  for (final key in path) {
    cur = asMap(cur)?[key];
  }
  return asMap(cur) ?? const {};
}

/// Totals of `/api/billing/v2/usage` for the month: cost = billed units x
/// price table, tokens = consumed units (completion-style categories only).
MistralBillingTotals parseMistralBilling(Map<String, Object?> root) {
  final prices = <String, double>{};
  for (final raw in asList(root['prices']) ?? const []) {
    final p = asMap(raw);
    final metric = asString(p?['billing_metric']);
    final group = asString(p?['billing_group']);
    final price = _finite(p?['price']);
    if (p == null || metric == null || group == null || price == null) continue;
    prices[_priceKey(
          asString(p['event_type']),
          metric,
          group,
          asString(p['api_zone']),
          asString(p['service_tier']),
        )] =
        price;
  }
  double entryCost(Map<String, Object?> e) {
    final metric = asString(e['billing_metric']);
    final group = asString(e['billing_group']);
    if (metric == null || group == null) return 0;
    final event = asString(e['event_type']);
    final units = _finite(e['value_paid']) ?? _finite(e['value']) ?? 0;
    final price =
        prices[_priceKey(
          event,
          metric,
          group,
          asString(e['api_zone']),
          asString(e['service_tier']),
        )] ??
        prices[_priceKey(event, metric, group, null, null)] ??
        0;
    final cost = units * price;
    return cost.isFinite ? cost : 0;
  }

  const categories = <(List<String>, bool)>[
    (['completion', 'models'], true),
    (['chat', 'models'], true),
    (['vibe_code', 'completion', 'models'], true),
    (['ocr', 'models'], false),
    (['connectors', 'models'], false),
    (['audio', 'models'], false),
    (['libraries_api', 'pages', 'models'], false),
    (['libraries_api', 'tokens', 'models'], false),
    (['fine_tuning', 'training'], false),
    (['fine_tuning', 'storage'], false),
  ];
  var cost = 0.0;
  var input = 0;
  var output = 0;
  var cached = 0;
  var models = 0;
  for (final (path, countsTokens) in categories) {
    for (final model in _mistralAt(root, path).values) {
      final data = asMap(model) ?? const {};
      if (countsTokens) models++;
      for (final lane in ['input', 'output', 'cached']) {
        for (final raw in asList(data[lane]) ?? const []) {
          final e = asMap(raw);
          if (e == null) continue;
          cost += entryCost(e);
          if (!countsTokens) continue;
          final tokens = (_finite(e['value']) ?? _finite(e['value_paid']) ?? 0).round();
          if (lane == 'input') {
            input += tokens;
          } else if (lane == 'output') {
            output += tokens;
          } else {
            cached += tokens;
          }
        }
      }
    }
  }
  final rawCurrency = (asString(root['currency']) ?? '').toUpperCase();
  final currency = rawCurrency.isEmpty ? 'XXX' : rawCurrency;
  final symbol =
      asString(root['currency_symbol']) ??
      (currency == 'EUR' ? '€' : (currency == 'XXX' ? '¤' : currency));
  return (
    cost: cost,
    currency: currency,
    symbol: symbol,
    input: input,
    output: output,
    cached: cached,
    models: models,
  );
}

({double available, String currency}) parseMistralCredits(Map<String, Object?> root) {
  final wallet = _finite(root['wallet_amount']) ?? _fail('Mistral 余额数据无效');
  final notes = _finite(root['credit_notes_amount']) ?? 0;
  final ongoing = _finite(root['ongoing_usage_balance']) ?? 0;
  final currency = asString(root['currency']) ?? 'USD';
  return (available: wallet + notes - ongoing, currency: currency.toUpperCase());
}

class MistralProvider extends _CookieProvider {
  @override
  String get id => 'mistral';
  @override
  String get displayName => 'Mistral AI';
  @override
  int get brandColor => 0xFFFF5229;
  @override
  String get cookieLabel => 'admin.mistral.ai Cookie';
  @override
  String get cookieHint => 'ory_session_...=...; csrftoken=...';
  @override
  String get setupHint =>
      '登录 admin.mistral.ai 后，复制任一请求的 Cookie 请求头（需要包含 ory_session_* 的 Cookie，可含 csrftoken）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    if (!RegExp(r'(?:^|;\s*)ory_session_[^=\s]+=').hasMatch(cookie)) {
      _fail('Mistral Cookie 无效', hint: '需要包含 ory_session_* 的 Cookie（在 admin.mistral.ai 的请求头中复制）');
    }
    final csrf = cookieValue(cookie, 'csrftoken');
    final headers = {
      'Cookie': cookie,
      'Accept': '*/*',
      'Referer': 'https://admin.mistral.ai/organization/usage',
      'Origin': 'https://admin.mistral.ai',
      if (csrf != null && csrf.isNotEmpty) 'X-CSRFTOKEN': csrf,
    };
    final now = ctx.now().toUtc();
    final usage = await fetchJsonObject(
      ctx,
      displayName,
      Uri.https('admin.mistral.ai', '/api/billing/v2/usage', {
        'month': '${now.month}',
        'year': '${now.year}',
      }),
      headers: headers,
      authHint: 'Cookie 已过期，重新登录 admin.mistral.ai 后复制',
      timeout: const Duration(seconds: 15),
    );
    final totals = parseMistralBilling(usage);

    ({double available, String currency})? credits;
    try {
      final json = await fetchJsonObject(
        ctx,
        displayName,
        Uri.https('admin.mistral.ai', '/api/billing/credits'),
        headers: {...headers, 'Referer': 'https://admin.mistral.ai/organization/billing'},
        timeout: const Duration(seconds: 4),
      );
      credits = parseMistralCredits(json);
    } on ProviderException {
      credits = null;
    }
    final currency = totals.currency == 'XXX' ? null : totals.currency;
    return snapshot(
      account,
      ctx,
      plan: 'API 按量计费',
      source: 'web',
      credits: [
        spendRow('mistral-month', totals.cost, label: '本月花费', currency: currency),
        if (credits != null)
          balanceRow(
            'mistral-balance',
            credits.available,
            label: '可用余额',
            currency: credits.currency,
          ),
      ],
      extras: {
        '输入 Token': '${totals.input}',
        '输出 Token': '${totals.output}',
        '缓存 Token': '${totals.cached}',
        '模型数': '${totals.models}',
      },
    );
  }
}

// ------------------------------------------------------------------- T3 Chat

Map<String, Object?>? _t3Find(Object? value) {
  if (value is Map) {
    if (value.containsKey('usageFourHourPercentage') ||
        value.containsKey('usageMonthPercentage') ||
        (value.containsKey('subscription') && value.containsKey('usageBand'))) {
      return value.cast<String, Object?>();
    }
    for (final child in value.values) {
      final found = _t3Find(child);
      if (found != null) return found;
    }
  } else if (value is List) {
    for (final child in value) {
      final found = _t3Find(child);
      if (found != null) return found;
    }
  }
  return null;
}

/// First JSON line of a tRPC JSONL body that carries usage fields.
Map<String, Object?>? parseT3ChatBody(String body) {
  for (final line in body.split(RegExp(r'\r?\n'))) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    final found = _t3Find(decoded);
    if (found != null) return found;
  }
  return null;
}

DateTime? _t3Date(Object? v) {
  final n = _finite(v);
  if (n == null || n <= 0) return null;
  return n > 1e10 ? DateTime.fromMillisecondsSinceEpoch(n.round(), isUtc: true) : _epochSeconds(n);
}

({List<RateWindow> windows, Map<String, String> extras, String? plan}) buildT3ChatUsage(
  Map<String, Object?> data,
) {
  Never invalid() => _fail('无法解析 T3 Chat 用量: 客户数据格式无效');
  for (final key in [
    'usageFourHourPercentage',
    'usageMonthPercentage',
    'usagePeriodPercentage',
    'usageFourHourNextResetAt',
    'usageWindowNextResetAt',
    'billingNextResetAt',
    'lifetimeBalance',
  ]) {
    final v = data[key];
    if (v != null && (v is! num || !v.isFinite)) invalid();
  }
  for (final key in ['subTier', 'usageBand']) {
    if (data[key] != null && data[key] is! String) invalid();
  }
  final sub = data['subscription'];
  if (sub != null) {
    final s = asMap(sub) ?? invalid();
    for (final key in ['productId', 'productName', 'status']) {
      if (s[key] != null && s[key] is! String) invalid();
    }
    for (final key in ['currentPeriodStart', 'currentPeriodEnd', 'canceledAt', 'trialEndsAt']) {
      if (s[key] != null && s[key] is! num) invalid();
    }
  }
  double clampPercent(Object? v) => (_finite(v) ?? 0).clamp(0, 100).toDouble();

  final subscription = asMap(sub);
  final band = asString(data['usageBand']);
  final rawPlan = asString(subscription?['productName']) ?? asString(data['subTier']);
  final plan = rawPlan == null ? null : _capitalizeWords(rawPlan, '-');
  final windows = [
    quotaWindow(
      't3chat-base',
      '基础额度',
      usedPercent: clampPercent(data['usageFourHourPercentage']),
      windowMinutes: 240,
      resetsAt:
          _t3Date(data['usageFourHourNextResetAt']) ?? _t3Date(data['usageWindowNextResetAt']),
    ),
    quotaWindow(
      't3chat-overage',
      '超额用量',
      usedPercent: clampPercent(data['usageMonthPercentage'] ?? data['usagePeriodPercentage']),
      resetsAt: _t3Date(subscription?['currentPeriodEnd']),
    ),
  ];
  return (windows: windows, extras: {'基础额度说明': band == null ? 'Base' : 'Base - $band'}, plan: plan);
}

class T3ChatProvider extends _CookieProvider {
  @override
  String get id => 't3chat';
  @override
  String get displayName => 'T3 Chat';
  @override
  int get brandColor => 0xFFF56647;
  @override
  String get cookieLabel => 't3.chat Cookie';
  @override
  String get cookieHint => 'Cookie 请求头，或浏览器复制的完整 cURL';
  @override
  String get setupHint =>
      '登录 t3.chat 后打开 settings/customization，在网络面板复制 getCustomerData 请求的 Cookie 请求头（或 Copy as cURL 后整体粘贴）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final input = jsonEncode({
      '0': {
        'json': {'sessionId': null},
        'meta': {
          'values': {
            'sessionId': ['undefined'],
          },
        },
      },
    });
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.https('t3.chat', '/api/trpc/getCustomerData', {'batch': '1', 'input': input}),
      headers: {
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent': browserUserAgent,
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-origin',
        'Priority': 'u=4',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Referer': 'https://t3.chat/settings/customization',
        'trpc-accept': 'application/jsonl',
        'x-trpc-source': 'web-client',
        'x-trpc-batch': 'true',
        'Cookie': cookie,
        'Origin': 'https://t3.chat',
      },
      timeout: const Duration(seconds: 60),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      _fail('T3 Chat 会话 Cookie 无效或已过期', hint: '重新登录 t3.chat 后复制 Cookie');
    }
    final mitigated = r.headers.entries
        .where((e) => e.key.toLowerCase() == 'x-vercel-mitigated')
        .map((e) => e.value)
        .firstOrNull;
    if (r.statusCode == 429 && mitigated == 'challenge') {
      _fail('T3 Chat 返回了 Vercel 安全验证', hint: '粘贴完整的浏览器 cURL 请求，而不只是 Cookie');
    }
    if (!r.ok) {
      throw ProviderException('T3 Chat 接口错误 HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    final data = parseT3ChatBody(r.body) ?? _fail('无法解析 T3 Chat 用量: 客户数据格式无效');
    final built = buildT3ChatUsage(data);
    return snapshot(
      account,
      ctx,
      plan: built.plan,
      source: 'web',
      windows: built.windows,
      extras: built.extras,
    );
  }
}

// ---------------------------------------------------------------------- Qoder

({RateWindow window, String? resetText, String used}) parseQoderQuota(
  Map<String, Object?> root,
  DateTime now,
) {
  Never fail(String message) => _fail('Qoder 用量解析失败: $message');
  ({double used, double total, double remaining, double? provided}) quota(Object? raw) {
    final summary = asMap(raw) ?? fail('quota object');
    if (summary['unit'] != null && summary['unit'] is! String) fail('quota unit');
    double number(Object? v) => _finite(v) ?? fail('quota number');
    final used = number(summary['usedValue'] ?? summary['used_value']);
    final total = number(summary['limitValue'] ?? summary['limit_value']);
    final remainingRaw = summary['remainingValue'] ?? summary['remaining_value'];
    final remaining = remainingRaw == null
        ? math.max(0, total - used).toDouble()
        : number(remainingRaw);
    final providedRaw = summary['usagePercentage'] ?? summary['usage_percentage'];
    final provided = providedRaw == null ? null : number(providedRaw);
    if (used < 0 || total < 0 || remaining < 0) fail('quota values must be nonnegative');
    return (used: used, total: total, remaining: remaining, provided: provided);
  }

  final container = asMap(root['totalQuota'] ?? root['total_quota']);
  final base = quota(container?['quotaSummary'] ?? container?['quota_summary']);
  final sharedRaw = root['sharedQuota'] ?? root['shared_quota'];
  final sharedContainer = sharedRaw == null ? null : (asMap(sharedRaw) ?? fail('shared quota'));
  final sharedSummary = sharedContainer?['quotaSummary'] ?? sharedContainer?['quota_summary'];
  final shared = sharedSummary == null ? null : quota(sharedSummary);
  final used = base.used + (shared?.used ?? 0);
  final total = base.total + (shared?.total ?? 0);
  final remaining = base.remaining + (shared?.remaining ?? 0);
  if (total == 0 && (used != 0 || remaining != 0)) {
    fail('zero total quota must have zero usage and remaining');
  }
  final provided = shared != null ? null : base.provided;
  final percent = provided ?? (total > 0 ? used / total * 100 : 100);

  final reset = root['nextResetAt'] ?? root['next_reset_at'];
  DateTime? resetsAt;
  if (reset is num) {
    resetsAt = reset > 1e10
        ? DateTime.fromMillisecondsSinceEpoch(reset.round(), isUtc: true)
        : _epochSeconds(reset.toDouble());
  } else if (reset is String) {
    resetsAt = DateTime.tryParse(reset)?.toUtc();
  }
  final usedText = _fmt(used, used == used.roundToDouble() ? 0 : 2);
  final totalText = _fmt(total, total == total.roundToDouble() ? 0 : 2);
  return (
    window: quotaWindow(
      'qoder-credits',
      '积分',
      usedPercent: percent.clamp(0, 100).toDouble(),
      resetsAt: resetsAt,
    ),
    resetText: '$usedText / $totalText credits',
    used: usedText,
  );
}

class QoderProvider extends _CookieProvider {
  @override
  String get id => 'qoder';
  @override
  String get displayName => 'Qoder';
  @override
  int get brandColor => 0xFF10B981;
  @override
  String get cookieLabel => 'qoder.com Cookie';
  @override
  String get cookieHint => 'Cookie 请求头，或浏览器复制的 cURL';
  @override
  String get setupHint => '登录 qoder.com（国内站选 qoder.com.cn）后，在开发者工具任一请求中复制 Cookie 请求头并粘贴。';

  @override
  List<ProviderField> get fields => [
    ...super.fields,
    const ProviderField(
      key: 'site',
      label: '站点',
      kind: FieldKind.choice,
      required: false,
      defaultValue: 'qoder.com',
      choices: [
        FieldChoice('qoder.com', '国际站 qoder.com'),
        FieldChoice('qoder.com.cn', '国内站 qoder.com.cn'),
      ],
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final site = v['site'] == 'qoder.com.cn' ? 'qoder.com.cn' : 'qoder.com';
    final origin = 'https://$site';
    final cookie = normalizeCookieHeader(v.secret);
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$origin/api/v2/me/usages/big_model_credits'),
      headers: {
        'Cookie': cookie,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent': browserUserAgent,
        'Origin': origin,
        'Referer': '$origin/account/usage',
        'X-Requested-With': 'XMLHttpRequest',
        'Bx-V': '2.5.35',
      },
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      _fail('Qoder 会话无效或已过期', hint: '在 $site 重新登录后复制新的 Cookie');
    }
    if (!r.ok) {
      throw ProviderException('Qoder API 返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    final root = asMap(r.json) ?? _fail('Qoder 用量解析失败: invalid JSON');
    final parsed = parseQoderQuota(root, ctx.now());
    return snapshot(
      account,
      ctx,
      plan: site == 'qoder.com.cn' ? '国内站 (qoder.com.cn)' : '国际站 (qoder.com)',
      source: 'web',
      windows: [parsed.window],
      extras: {'用量': parsed.resetText!},
    );
  }
}

// --------------------------------------------------------------------- Abacus

const _abacusAuthWords = [
  'expired',
  'session',
  'login',
  'authenticate',
  'unauthorized',
  'unauthenticated',
  'forbidden',
];

/// `result` of an Abacus `{success, result}` envelope; throws on failure.
Map<String, Object?> _abacusResult(HttpResult r) {
  if (r.statusCode == 401 || r.statusCode == 403) {
    _fail('Unauthorized. 请重新登录 Abacus AI', hint: '在 apps.abacus.ai 重新登录后复制 Cookie');
  }
  if (!r.ok) {
    throw ProviderException('Abacus AI API 错误: HTTP ${r.statusCode}', statusCode: r.statusCode);
  }
  final root = asMap(r.json) ?? _fail('Could not parse Abacus AI usage: invalid JSON');
  final result = asMap(root['result']);
  if (root['success'] != true || result == null) {
    final message = (asString(root['error']) ?? 'unknown error').toLowerCase();
    if (_abacusAuthWords.any(message.contains)) {
      _fail('Unauthorized. 请重新登录 Abacus AI', hint: '在 apps.abacus.ai 重新登录后复制 Cookie');
    }
    _fail('Could not parse Abacus AI usage: $message');
  }
  return result;
}

class AbacusProvider extends _CookieProvider {
  @override
  String get id => 'abacus';
  @override
  String get displayName => 'Abacus AI';
  @override
  int get brandColor => 0xFF814EE8;
  @override
  String get cookieLabel => 'apps.abacus.ai Cookie';
  @override
  String get cookieHint => 'Cookie 请求头';
  @override
  String get setupHint => '登录 apps.abacus.ai 后，复制任一请求的 Cookie 请求头粘贴到这里。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final headers = {
      'Cookie': cookie,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final pointsFuture = sendRequest(
      ctx,
      displayName,
      Uri.parse('https://apps.abacus.ai/api/_getOrganizationComputePoints'),
      headers: headers,
      timeout: const Duration(seconds: 15),
    );
    final billingFuture = sendRequest(
      ctx,
      displayName,
      Uri.parse('https://apps.abacus.ai/api/_getBillingInfo'),
      method: 'POST',
      headers: headers,
      body: const <String, Object>{},
      timeout: const Duration(seconds: 5),
    ).then<HttpResult?>((r) => r, onError: (Object _) => null);
    final points = _abacusResult(await pointsFuture);
    final billingRaw = await billingFuture;
    Map<String, Object?> billing = const {};
    if (billingRaw != null) {
      try {
        billing = _abacusResult(billingRaw);
      } on ProviderException {
        billing = const {};
      }
    }

    final total = points['totalComputePoints'];
    final left = points['computePointsLeft'];
    if (total is! num || !total.isFinite || left is! num || !left.isFinite) {
      _fail('Could not parse Abacus AI usage: Missing credit fields in compute points response');
    }
    final used = total - left;
    final next = asString(billing['nextBillingDate']);
    final resetsAt = next != null && RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(next)
        ? DateTime.tryParse(next)?.toUtc()
        : null;
    final windowMinutes = resetsAt == null
        ? 30 * 24 * 60
        : math.max(1, resetsAt.difference(_addMonths(resetsAt, -1)).inMinutes);
    String credits(double v) => _fmt(v, v >= 1000 ? 0 : 1);
    return snapshot(
      account,
      ctx,
      plan: asString(billing['currentTier']),
      source: 'web',
      windows: [
        quotaWindow(
          'abacus-compute',
          '计算点数',
          usedPercent: total > 0 ? pct(used, total) : 0,
          resetsAt: resetsAt,
          windowMinutes: windowMinutes,
        ),
      ],
      extras: {'用量': '${credits(used.toDouble())} / ${credits(total.toDouble())} credits'},
    );
  }
}

// ------------------------------------------------------------------ CommandCode

({RateWindow? window}) _ccWindow(Object? raw, int minutes, String id, String label) {
  final limit = asMap(raw);
  final cap = _finite(limit?['cap']);
  if (limit == null || cap == null || cap <= 0) return (window: null);
  final used = _finite(limit['used']) ?? 0;
  return (
    window: quotaWindow(
      id,
      label,
      usedPercent: pct(used, cap),
      resetsAt: _ccDate(limit['resetAt']),
      windowMinutes: minutes,
    ),
  );
}

DateTime? _ccDate(Object? v) {
  final n = _finite(v);
  if (n != null) return n > 0 ? _epochAuto(n) : null;
  final s = asString(v);
  return s == null ? null : DateTime.tryParse(s)?.toUtc();
}

class CommandCodeProvider extends UsageProvider {
  static const _alpha = '/alpha';
  static const _internal = '/internal';

  @override
  String get id => 'commandcode';
  @override
  String get displayName => 'Command Code';
  @override
  int get brandColor => 0xFF8C4EDD;
  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];
  @override
  String get setupHint =>
      '填写 Command Code API Key（推荐），或登录 commandcode.ai 后粘贴 Cookie 请求头。两者都填时优先用 API Key。';

  @override
  List<ProviderField> get fields => [
    ProviderField.apiKey(
      label: 'API Key',
      required: false,
      envVars: const ['COMMAND_CODE_API_KEY'],
      help: '留空则使用下方 Cookie',
    ),
    const ProviderField(
      key: 'cookie',
      label: 'commandcode.ai Cookie',
      multiline: true,
      required: false,
      help: '浏览器登录 commandcode.ai → 开发者工具 → 网络 → 任一请求的 Cookie 请求头',
    ),
  ];

  @override
  String get manualSourceLabel => '手动输入 API Key / Cookie';

  @override
  String? validateManual(FieldValues values) =>
      values[ProviderField.secretKey] == null && values['cookie'] == null
      ? '请填写 API Key 或 Cookie'
      : null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final apiKey = v[ProviderField.secretKey] == null
        ? null
        : bareToken(v[ProviderField.secretKey]!);
    final cookie = v['cookie'] == null ? null : normalizeCookieHeader(v['cookie']!);
    final useKey = apiKey != null && apiKey.isNotEmpty;
    if (!useKey && (cookie == null || cookie.isEmpty)) {
      _fail('未填写 Command Code 的 API Key 或 Cookie', hint: '在账户设置中填写');
    }
    final prefix = useKey ? _alpha : _internal;
    final headers = useKey
        ? {'Authorization': 'Bearer $apiKey', 'Accept': 'application/json'}
        : {
            'Cookie': cookie!,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'en-US,en;q=0.9',
            'User-Agent': browserUserAgent,
            'Origin': 'https://commandcode.ai',
            'Referer': 'https://commandcode.ai/',
          };
    Future<Map<String, Object?>> get(String path) async {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://api.commandcode.ai$prefix$path'),
        headers: headers,
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 401 || r.statusCode == 403) {
        _fail(
          useKey ? 'Command Code API Key 无效或已过期' : 'Command Code 会话无效或已过期',
          hint: useKey ? '在 Command Code 重新生成 API Key' : '重新登录 commandcode.ai 后复制 Cookie',
        );
      }
      if (!r.ok) {
        throw ProviderException(
          'Command Code API 返回 HTTP ${r.statusCode}',
          statusCode: r.statusCode,
        );
      }
      return asMap(r.json) ?? _fail('Could not parse Command Code response: invalid JSON');
    }

    final results = await Future.wait<Object?>(<Future<Object?>>[
      get('/billing/credits'),
      get('/billing/subscriptions').then<Object?>((j) => j, onError: (Object _) => null),
    ]);
    final credits = asMap(results[0]) ?? _fail('Could not parse Command Code response');
    final body =
        asMap(credits['credits']) ??
        _fail('Could not parse Command Code response: missing credits');
    final monthly =
        _finite(body['monthlyCredits']) ??
        _fail('Could not parse Command Code response: missing monthlyCredits');
    final purchased = _finite(body['purchasedCredits']) ?? 0;
    final granted = _finite(body['monthlyCreditsGranted']);
    final windowLimits = asMap(credits['windowLimits']) ?? asMap(body['windowLimits']);

    // Subscription lookup is optional: a failure just hides the plan.
    final subs = asMap(results[1]);
    final subsOk = subs?['success'] == true;
    final subscriptionUnavailable = !subsOk;
    final subData = asMap(subs?['data']);
    final planId = asString(subData?['planId']);
    final periodEnd = _ccDate(subData?['currentPeriodEnd']);
    final plan = planId;

    final total = granted != null && granted > 0 ? granted : null;
    final windows = <RateWindow>[
      ?_ccWindow(windowLimits?['fiveHour'], 300, RateWindow.sessionId, '5 小时').window,
      ?_ccWindow(windowLimits?['weekly'], 10080, RateWindow.weeklyId, '每周').window,
    ];
    if (total != null) {
      final used = math.max(0, math.min(total, total - monthly)).toDouble();
      windows.add(
        quotaWindow(
          'commandcode-monthly',
          '每月额度',
          usedPercent: pct(used, total),
          resetsAt: periodEnd,
          windowMinutes: 43200,
        ),
      );
    } else if (plan == null && !subscriptionUnavailable && (monthly > 0 || purchased > 0)) {
      windows.add(
        quotaWindow(
          'commandcode-monthly',
          '每月额度',
          usedPercent: 0,
          resetsAt: periodEnd,
          windowMinutes: 43200,
        ),
      );
    }

    final parts = <String>[
      ?planId,
      if (total != null)
        '${moneyText(math.max(0, total - monthly).toDouble(), 'USD')} of ${moneyText(total, 'USD')}'
      else if (plan != null || monthly > 0)
        '${moneyText(monthly, 'USD')} remaining',
      if (purchased > 0) '+ ${moneyText(purchased, 'USD')} credits',
    ];
    return snapshot(
      account,
      ctx,
      plan: parts.isEmpty ? null : parts.join(' · '),
      source: useKey ? 'api-key' : 'web',
      windows: windows,
      extras: {if (subsOk && subData?['status'] != null) '订阅状态': '${subData!['status']}'},
    );
  }
}

// ----------------------------------------------------------------------- Devin

String _devinToken(String raw) => raw
    .trim()
    .replaceFirst(RegExp(r'^(?:authorization:\s*)?(?:bearer\s+)?', caseSensitive: false), '')
    .trim();

String _devinOrganization(String raw) {
  var value = raw.trim();
  final uri = Uri.tryParse(value);
  if (uri != null && uri.host.isNotEmpty) {
    final host = uri.host.toLowerCase();
    if (host == 'devin.ai' || host.endsWith('.devin.ai')) {
      final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length >= 2 && (parts[0] == 'org' || parts[0] == 'organizations')) {
        value = '${parts[0]}/${parts[1]}';
      }
    }
  }
  value = value.replaceAll(RegExp(r'^/+|/+$'), '');
  if (value.startsWith('org/') || value.startsWith('organizations/')) return value;
  if (value.startsWith('org-') || value.startsWith('org_')) return 'organizations/$value';
  return 'org/$value';
}

List<String> _devinCandidatePaths(String organization, String? internal) {
  final paths = <String>[
    if (internal != null) '$internal/billing/quota/usage',
    '$organization/billing/quota/usage',
    if (organization.startsWith('org/')) '${organization.substring(4)}/billing/quota/usage',
    if (!organization.startsWith('org/') && !organization.startsWith('organizations/'))
      'org/$organization/billing/quota/usage',
    if (internal != null) 'organizations/$internal/billing/quota/usage',
  ];
  return paths.toSet().toList();
}

double? _devinNumber(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

DateTime? _devinDate(Object? value) {
  if (value is String) {
    final iso = DateTime.tryParse(value.trim());
    if (iso != null) return iso.toUtc();
    final n = double.tryParse(value.trim());
    return n == null ? null : _devinDate(n);
  }
  final n = _devinNumber(value);
  if (n == null || n <= 0) return null;
  return n > 1e10 ? DateTime.fromMillisecondsSinceEpoch(n.round(), isUtc: true) : _epochSeconds(n);
}

double? _devinPercentOf(Map<String, Object?> m) {
  for (final key in [
    'used_percent',
    'usedPercent',
    'usage_percent',
    'usagePercent',
    'percent_used',
    'percentUsed',
    'percent',
  ]) {
    final v = _devinNumber(m[key]);
    if (v != null) return v <= 1 ? v * 100 : v;
  }
  for (final key in [
    'remaining_percent',
    'remainingPercent',
    'percent_remaining',
    'percentRemaining',
  ]) {
    final v = _devinNumber(m[key]);
    if (v != null) return 100 - (v <= 1 ? v * 100 : v);
  }
  double? first(List<String> keys) {
    for (final key in keys) {
      final v = _devinNumber(m[key]);
      if (v != null) return v;
    }
    return null;
  }

  final used = first(['used', 'usage', 'used_count', 'usedCount', 'consumed']);
  final limit = first(['limit', 'quota', 'total', 'max', 'available']);
  if (used != null && limit != null && limit > 0) return used / limit * 100;
  final remaining = first(['remaining', 'left', 'available']);
  if (remaining != null && limit != null && limit > 0) return (limit - remaining) / limit * 100;
  return null;
}

({double used, DateTime? resetsAt})? _devinWindowOf(Object? v) {
  final n = _devinNumber(v);
  if (n != null) return (used: n <= 1 ? n * 100 : n, resetsAt: null);
  if (v is! Map) return null;
  final m = v.cast<String, Object?>();
  final percent = _devinPercentOf(m);
  if (percent != null) {
    final reset = m.entries
        .where((e) => e.key.toLowerCase().contains('reset'))
        .map((e) => _devinDate(e.value))
        .firstOrNull;
    return (used: percent, resetsAt: reset);
  }
  for (final child in m.values) {
    final found = _devinWindowOf(child);
    if (found != null) return found;
  }
  return null;
}

({double used, DateTime? resetsAt})? _devinFind(Object? node, bool Function(String key) matches) {
  if (node is Map) {
    for (final e in node.entries) {
      if (!matches(e.key)) continue;
      final found = _devinWindowOf(e.value);
      if (found != null) return found;
    }
    for (final child in node.values) {
      final found = _devinFind(child, matches);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final child in node) {
      final found = _devinFind(child, matches);
      if (found != null) return found;
    }
  }
  return null;
}

String? _devinPlan(Object? node) {
  if (node is Map) {
    for (final key in [
      'plan_name',
      'planName',
      'plan',
      'tier',
      'subscription_tier',
      'subscriptionTier',
    ]) {
      final v = asString(node[key]);
      if (v != null) return _capitalizeWords(v, RegExp(r'[_-]'));
    }
    for (final child in node.values) {
      final found = _devinPlan(child);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final child in node) {
      final found = _devinPlan(child);
      if (found != null) return found;
    }
  }
  return null;
}

({RateWindow? daily, RateWindow? weekly, double? overage, String? plan}) parseDevinUsage(
  Map<String, Object?> root,
) {
  final hideDaily = root['hide_daily_quota'] == true;
  ({double used, DateTime? resetsAt})? current(String prefix) {
    final p = _devinNumber(root['${prefix}_percentage']);
    if (p == null) return null;
    return (used: p < 1 ? p * 100 : p, resetsAt: _devinDate(root['${prefix}_reset_at']));
  }

  bool isDaily(String k) {
    final key = k.toLowerCase();
    return !key.contains('hide') && (key.contains('daily') || key.contains('day'));
  }

  bool isWeekly(String k) {
    final key = k.toLowerCase();
    return !key.contains('hide') && (key.contains('weekly') || key.contains('week'));
  }

  final daily = hideDaily ? null : (current('daily') ?? _devinFind(root, isDaily));
  final weekly = current('weekly') ?? _devinFind(root, isWeekly);
  if (daily == null && weekly == null) _fail('Devin 返回中缺少额度窗口', hint: '稍后重试');
  final overageRaw = _devinNumber(root['overage_balance']);
  final centsRaw = _devinNumber(root['overage_balance_cents']);
  final overage = overageRaw != null && overageRaw >= 0
      ? overageRaw
      : (centsRaw != null && centsRaw >= 0 ? centsRaw / 100 : null);
  return (
    daily: daily == null
        ? null
        : quotaWindow(
            'devin-daily',
            '每日',
            usedPercent: daily.used,
            resetsAt: daily.resetsAt,
            windowMinutes: 1440,
          ),
    weekly: weekly == null
        ? null
        : quotaWindow(
            'devin-weekly',
            '每周',
            usedPercent: weekly.used,
            resetsAt: weekly.resetsAt,
            windowMinutes: 10080,
          ),
    overage: overage,
    plan: _devinPlan(root),
  );
}

class DevinProvider extends UsageProvider {
  @override
  String get id => 'devin';
  @override
  String get displayName => 'Devin';
  @override
  int get brandColor => 0xFF317CFF;
  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];
  @override
  String get manualSourceLabel => '手动输入 Token';
  @override
  String get setupHint =>
      '从 app.devin.ai 的一次成功 billing/quota/usage 请求复制 Authorization 的 Bearer Token，以及 x-cog-org-id（org- 或 org_ 开头）作为组织 ID。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: 'Bearer Token',
      hint: 'auth1_... 或 eyJ...',
      envVars: ['DEVIN_BEARER_TOKEN', 'DEVIN_AUTHORIZATION'],
    ),
    ProviderField(
      key: 'organization',
      label: '组织 ID',
      kind: FieldKind.text,
      hint: 'org-... 或 org_...',
      help: '从 billing/quota/usage 请求的 x-cog-org-id 请求头复制',
      envVars: ['DEVIN_ORGANIZATION', 'DEVIN_ORG'],
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final token = _devinToken(v.secret);
    if (token.isEmpty) _fail('未填写 Devin Bearer Token', hint: '在账户设置中粘贴 Token');
    final organization = _devinOrganization(v.require('organization'));
    final internal = organization.startsWith('organizations/') ? organization.substring(14) : null;
    ProviderException? lastError;
    for (final path in _devinCandidatePaths(organization, internal)) {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://app.devin.ai/api/$path'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept-Language': 'en-US,en;q=0.9',
          'User-Agent': browserUserAgent,
          'x-cog-org-id': ?internal,
        },
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 401 || r.statusCode == 403) {
        final detail = asMap(r.json)?['detail'];
        if (detail == 'No organizations found for auth1 user') {
          _fail('Devin 找不到该 Token 对应的组织', hint: '从一次成功的 billing/quota/usage 请求复制 x-cog-org-id');
        }
        _fail('Devin Token 无效或已过期', hint: '重新登录 app.devin.ai 后复制新的 Bearer Token');
      }
      if (!r.ok) {
        lastError = ProviderException('Devin 接口错误 HTTP ${r.statusCode}', statusCode: r.statusCode);
        continue;
      }
      final root = asMap(r.json) ?? _fail('Devin 返回了无法解析的数据');
      final parsed = parseDevinUsage(root);
      final overage = parsed.overage;
      return snapshot(
        account,
        ctx,
        plan: parsed.plan,
        source: 'api-key',
        windows: [?parsed.daily, ?parsed.weekly],
        credits: [
          if (overage != null) balanceRow('devin-overage', overage, label: '超额余额', currency: 'USD'),
        ],
      );
    }
    throw lastError ?? ProviderException('Devin 没有可用的额度接口');
  }
}

// ----------------------------------------------------------------------- Notion

({RateWindow? window, String? limitText}) _notionWindow(
  Object? raw, {
  required bool rolling,
  required DateTime now,
  double? resets,
}) {
  if (raw == null) return (window: null, limitText: null);
  final value = asMap(raw) ?? _fail('Notion 额度窗口格式无效');
  for (final f in ['creditType', 'scope', 'window', 'cadence']) {
    if (value[f] != null && value[f] is! String) _fail('Notion 额度字段无效: $f');
  }
  double? strict(Object? v) {
    if (v == null) return null;
    return v is num && v.isFinite ? v.toDouble() : _fail('Notion 额度字段无效');
  }

  final used = strict(value['used']);
  final limit = strict(value['limit']);
  final end = strict(value['periodEndMs']);
  if (used == null || limit == null || limit <= 0) return (window: null, limitText: null);
  final usedPercent = math.max(0, used / limit * 100).toDouble();
  final limitText = '${_fmt(used)} / ${_fmt(limit)} credits';
  if (!rolling) {
    return (
      window: quotaWindow(
        'notion-billing',
        '账单周期',
        usedPercent: usedPercent,
        resetsAt: end != null && end > 0
            ? DateTime.fromMillisecondsSinceEpoch(end.round(), isUtc: true)
            : null,
        windowMinutes: 43200,
      ),
      limitText: limitText,
    );
  }
  final match = RegExp(r'^([1-9][0-9]*)([mhdw])$')
      .firstMatch((asString(value['window']) ?? '').toLowerCase());
  int? minutes;
  if (match != null) {
    final unit = {'m': 1, 'h': 60, 'd': 1440, 'w': 10080}[match.group(2)!]!;
    final total = int.parse(match.group(1)!) * unit;
    if (total != 43200) minutes = total;
  }
  return (
    window: quotaWindow(
      'notion-rolling',
      '滚动额度',
      usedPercent: usedPercent,
      resetsAt: resets != null && resets >= 0
          ? now.toUtc().add(Duration(seconds: resets.round()))
          : null,
      windowMinutes: minutes,
    ),
    limitText: limitText,
  );
}

String _notionKey(String raw) => raw.trim().replaceAll('-', '').toLowerCase();

Map<String, Object?>? _notionUnwrap(Object? value) {
  final outer = asMap(value);
  final inner = asMap(outer?['value']);
  return asMap(inner?['value']) ?? inner ?? outer;
}

class NotionProvider extends UsageProvider {
  @override
  String get id => 'notion';
  @override
  String get displayName => 'Notion AI';
  @override
  int get brandColor => 0xFF337EA9;
  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];
  @override
  String get manualSourceLabel => '手动粘贴 Cookie';
  @override
  String get setupHint =>
      '登录 notion.so 后，复制任一请求的 Cookie 请求头，或只粘贴 token_v2 的值。Business/Enterprise 工作区才有 AI 额度。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.cookie(
      label: 'notion.so Cookie',
      hint: 'token_v2=... 或只粘贴 token_v2 的值',
      help: '浏览器登录 notion.so → 开发者工具 → 网络 → 任一请求的 Cookie 请求头',
    ),
    ProviderField(
      key: 'workspaceId',
      label: 'Workspace ID（可选）',
      kind: FieldKind.text,
      required: false,
      hint: '工作区 UUID',
      help: '填写后跳过工作区自动发现',
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final cookie = cookieHeaderFor(v.secret, 'token_v2');
    if (cookieValue(cookie, 'token_v2') == null) {
      _fail('Notion Cookie 中没有 token_v2', hint: '粘贴包含 token_v2 的 Cookie');
    }
    final headers = {
      'Cookie': cookie,
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://app.notion.com/',
      'Origin': 'https://app.notion.com',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-origin',
      'User-Agent': browserUserAgent,
    };
    Future<Map<String, Object?>> post(String endpoint, Map<String, String> body) async {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://app.notion.com/api/v3/$endpoint'),
        method: 'POST',
        headers: headers,
        body: body,
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 401) {
        _fail('Notion 会话 Cookie 无效或已过期', hint: '重新登录 notion.so 后复制 Cookie');
      }
      if (!r.ok) {
        throw ProviderException(
          'Notion HTTP ${r.statusCode} 来自 $endpoint',
          statusCode: r.statusCode,
        );
      }
      return asMap(r.json) ??
          _fail('Could not parse Notion usage: $endpoint response is not an object');
    }

    final pinned = _notionKey(v['workspaceId'] ?? '');
    final pinnedValid = RegExp(r'^[a-f0-9]{32}$').hasMatch(pinned);
    String? workspaceId;
    String? workspaceName;
    String? tier;
    String? email;
    if (pinnedValid) {
      workspaceId = pinned.replaceFirstMapped(
        RegExp(r'^(.{8})(.{4})(.{4})(.{4})(.{12})$'),
        (m) => '${m[1]}-${m[2]}-${m[3]}-${m[4]}-${m[5]}',
      );
    } else {
      final spaces = await post('getSpaces', const {});
      final ids = spaces.keys.where((id) {
        final users = asMap(asMap(spaces[id])?['notion_user']);
        return _notionUnwrap(users?[id])?['id'] == id;
      }).toList();
      final userId = ids.length == 1
          ? ids.single
          : (ids.isEmpty && spaces.length == 1 ? spaces.keys.single : null);
      if (userId == null) {
        _fail('Could not parse Notion usage: getSpaces did not identify a single user');
      }
      final container = asMap(spaces[userId]) ?? const {};
      final users = asMap(container['notion_user']) ?? const {};
      final user =
          _notionUnwrap(users[userId]) ??
          users.values.map(_notionUnwrap).whereType<Map<String, Object?>>().firstOrNull;
      email = asString(user?['email']);
      final records = asMap(container['space']) ?? const {};
      final workspaces = <Map<String, Object?>>[];
      for (final key in records.keys.toList()..sort()) {
        final record = _notionUnwrap(records[key]);
        if (record != null) workspaces.add({...record, 'id': asString(record['id']) ?? key});
      }
      final chosen =
          (pinned.isEmpty
              ? null
              : workspaces
                    .where((w) => _notionKey(asString(w['id']) ?? '') == pinned)
                    .firstOrNull) ??
          workspaces
              .where(
                (w) => const [
                  'business',
                  'enterprise',
                ].contains(asString(w['subscription_tier'])?.toLowerCase()),
              )
              .firstOrNull ??
          workspaces.firstOrNull;
      if (chosen == null) throw ProviderException('没有找到 Notion 工作区', hint: '在设置中填写 Workspace ID');
      workspaceId = asString(chosen['id']);
      workspaceName = asString(chosen['name']);
      tier = asString(chosen['subscription_tier']);
    }

    final usage = await post('getCreditRateLimitStatus', {'spaceId': workspaceId!});
    for (final f in ['status', 'enforcement']) {
      if (usage[f] != null && usage[f] is! String) {
        _fail('Could not parse Notion usage: invalid $f');
      }
    }
    final resetsNum = _devinNumber(usage['resetsInSeconds']);
    final now = ctx.now();
    final primary = _notionWindow(usage['window'], rolling: true, now: now, resets: resetsNum);
    final secondary = _notionWindow(usage['billingPeriodWindow'], rolling: false, now: now);
    if (asString(usage['status'])?.toLowerCase() == 'not_applicable') {
      throw ProviderException('此 Notion 工作区不提供 AI 额度统计', hint: '额度仅适用于 Business 和 Enterprise 工作区');
    }
    if (usage['window'] == null && usage['billingPeriodWindow'] == null) {
      _fail('Could not parse Notion usage: getCreditRateLimitStatus returned no usage windows');
    }
    final plan = tier == null || tier.isEmpty
        ? null
        : '${tier[0].toUpperCase()}${tier.substring(1)}';
    return snapshot(
      account,
      ctx,
      plan: plan,
      email: email,
      source: 'web',
      windows: [?primary.window, ?secondary.window],
      extras: {'工作区': ?workspaceName, '滚动额度': ?primary.limitText, '账单周期额度': ?secondary.limitText},
    );
  }
}

/// All providers in this group, for registration by the lead.
final List<UsageProvider> cookieAProviders = [
  PerplexityProvider(),
  ManusProvider(),
  OllamaProvider(),
  MistralProvider(),
  T3ChatProvider(),
  QoderProvider(),
  AbacusProvider(),
  CommandCodeProvider(),
  DevinProvider(),
  NotionProvider(),
];
