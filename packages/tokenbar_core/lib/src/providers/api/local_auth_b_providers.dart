import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

const _manualHint = '检查凭证是否正确或已过期';
const _defaultTimeout = Duration(seconds: 20);

/// A credential for one fetch. [localHint] is set for read-only local logins:
/// it tells the user how to log in again, since TokenBar never refreshes them.
class _Credential {
  const _Credential(this.value, {this.localHint});

  final String value;
  final String? localHint;
}

/// JSON request. A 401/403 with [expiredHint] means the login has expired.
Future<Map<String, Object?>> _sendJson(
  FetchContext ctx,
  String provider,
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
  Duration timeout = _defaultTimeout,
  String authHint = _manualHint,
  String? expiredHint,
}) async {
  final r = await sendRequest(
    ctx,
    provider,
    url,
    method: method,
    headers: headers,
    body: body,
    timeout: timeout,
  );
  if (expiredHint != null && (r.statusCode == 401 || r.statusCode == 403)) {
    throw ProviderException(
      '$provider 登录已过期 (HTTP ${r.statusCode})',
      hint: expiredHint,
      statusCode: r.statusCode,
    );
  }
  final map = asMap(checkStatus(provider, r, authHint: authHint).json);
  if (map == null) throw ProviderException('$provider 返回了无法解析的数据');
  return map;
}

String _capitalize(String s) => s
    .split(' ')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
    .join(' ');

String _ymd(DateTime d) => d.toUtc().toIso8601String().substring(0, 10);

String _num(Object? v) => (asDouble(v) ?? 0).round().toString();

double _clampPercent(num v) => v.clamp(0, 100).toDouble();

// ------------------------------------------------------------------ Codebuff

/// `default.authToken`, else top-level `authToken` (CodexBar CodebuffSettingsReader).
String? parseCodebuffAuthToken(String text) {
  final map = decodeJsonObject(text);
  return asString(asMap(map?['default'])?['authToken']) ?? asString(map?['authToken']);
}

class CodebuffUsage {
  const CodebuffUsage({this.used, this.total, this.remaining, this.nextQuotaReset, this.autoTopUp});

  final double? used;
  final double? total;
  final double? remaining;
  final DateTime? nextQuotaReset;
  final bool? autoTopUp;
}

CodebuffUsage parseCodebuffUsage(Map<String, Object?> json) {
  final usage = CodebuffUsage(
    used: asDouble(json['usage']) ?? asDouble(json['used']),
    total: asDouble(json['quota']) ?? asDouble(json['limit']),
    remaining: asDouble(json['remainingBalance']) ?? asDouble(json['remaining']),
    nextQuotaReset: parseFlexibleDate(json['next_quota_reset']),
    autoTopUp: asBool(json['autoTopupEnabled']) ?? asBool(json['auto_topup_enabled']),
  );
  if (usage.used == null && usage.total == null && usage.remaining == null) {
    throw ProviderException('Codebuff 返回了无法识别的用量数据');
  }
  return usage;
}

class CodebuffSubscription {
  const CodebuffSubscription({
    this.tier,
    this.status,
    this.email,
    this.billingPeriodEnd,
    this.weeklyUsed,
    this.weeklyLimit,
    this.weeklyResetsAt,
  });

  final String? tier;
  final String? status;
  final String? email;
  final DateTime? billingPeriodEnd;
  final double? weeklyUsed;
  final double? weeklyLimit;
  final DateTime? weeklyResetsAt;
}

CodebuffSubscription parseCodebuffSubscription(Map<String, Object?> json) {
  final sub = asMap(json['subscription']);
  final rate = asMap(json['rateLimit']);
  return CodebuffSubscription(
    tier:
        asString(sub?['displayName']) ??
        asString(json['displayName']) ??
        asString(sub?['tier']) ??
        asString(json['tier']) ??
        asString(sub?['scheduledTier']),
    status: asString(sub?['status']),
    email: asString(json['email']) ?? asString(asMap(json['user'])?['email']),
    billingPeriodEnd: parseFlexibleDate(sub?['billingPeriodEnd'] ?? sub?['currentPeriodEnd']),
    weeklyUsed: asDouble(rate?['weeklyUsed']) ?? asDouble(rate?['used']),
    weeklyLimit: asDouble(rate?['weeklyLimit']) ?? asDouble(rate?['limit']),
    weeklyResetsAt: parseFlexibleDate(rate?['weeklyResetsAt']),
  );
}

/// Credit quota. A balance without a usable total is shown as exhausted, as CodexBar does.
RateWindow? codebuffCreditsWindow(CodebuffUsage u) {
  final total = u.total;
  if (total != null && total > 0) {
    final used = u.used ?? total - (u.remaining ?? total);
    return quotaWindow(
      'codebuff-credits',
      '积分',
      usedPercent: pct(used, total),
      resetsAt: u.nextQuotaReset,
    );
  }
  if (u.used == null && u.remaining == null) return null;
  return quotaWindow('codebuff-credits', '积分', usedPercent: 100, resetsAt: u.nextQuotaReset);
}

RateWindow? codebuffWeeklyWindow(CodebuffSubscription s) {
  final limit = s.weeklyLimit;
  if (limit == null || limit <= 0) return null;
  return quotaWindow(
    RateWindow.weeklyId,
    '每周',
    usedPercent: pct((s.weeklyUsed ?? 0).clamp(0, double.infinity), limit),
    resetsAt: s.weeklyResetsAt,
    windowMinutes: 7 * 24 * 60,
  );
}

class CodebuffProvider extends UsageProvider {
  static const _api = 'https://www.codebuff.com';

  @override
  String get id => 'codebuff';

  @override
  String get displayName => 'Codebuff';

  @override
  int get brandColor => 0xFF00FF95;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli, SourceType.apiKey];

  @override
  String get setupHint =>
      '粘贴 Codebuff API Key（只显示积分）；或在本机运行 codebuff login 后选择"本机登录"'
      '（只读 ~/.config/manicode/credentials.json，同时显示每周额度）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(label: 'API Key', envVars: ['CODEBUFF_API_KEY']),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 API Key';

  @override
  String get localSourceLabel => '本机 Codebuff 登录';

  Future<String?> _localToken(AccountConfig account) async {
    if (!platform.localAccessSupported) return null;
    final home = account.homeDir ?? platform.homeDirectory();
    if (home == null) return null;
    final text = await platform.readTextFile(
      platform.joinPath(home, '.config', 'manicode', 'credentials.json'),
    );
    return text == null ? null : parseCodebuffAuthToken(text);
  }

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async => (await _localToken(account)) != null;

  Future<_Credential> _credential(AccountConfig account) async {
    if (account.sourceType == SourceType.apiKey) {
      return _Credential(bareToken(FieldValues.of(this, account).secret));
    }
    final token = await _localToken(account);
    if (token == null) {
      throw ProviderException('未找到 Codebuff 本机登录', hint: '运行 codebuff login，或改用手动粘贴 API Key');
    }
    return _Credential(token, localHint: '在本机运行 codebuff login 重新登录后再刷新');
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cred = await _credential(account);
    final headers = {'Authorization': 'Bearer ${cred.value}'};
    final usage = parseCodebuffUsage(
      await _sendJson(
        ctx,
        displayName,
        Uri.parse('$_api/api/v1/usage'),
        method: 'POST',
        headers: headers,
        body: {'fingerprintId': 'codexbar-usage'},
        expiredHint: cred.localHint,
      ),
    );
    CodebuffSubscription? sub;
    if (cred.localHint != null) {
      try {
        sub = parseCodebuffSubscription(
          await _sendJson(
            ctx,
            displayName,
            Uri.parse('$_api/api/user/subscription'),
            headers: headers,
          ),
        );
      } on ProviderException {
        sub = null;
      }
    }
    final tier = sub?.tier;
    final billing = sub?.billingPeriodEnd;
    final weekly = sub == null ? null : codebuffWeeklyWindow(sub);
    final credit = codebuffCreditsWindow(usage);
    final remaining = usage.remaining;
    return snapshot(
      account,
      ctx,
      plan: tier == null ? null : _capitalize(tier),
      email: sub?.email,
      source: cred.localHint != null ? 'local' : 'api-key',
      windows: [?credit, ?weekly],
      credits: [
        if (remaining != null)
          balanceRow('codebuff-remaining', remaining, label: '剩余积分', currency: null),
      ],
      extras: {
        if (usage.autoTopUp == true) '自动充值': '已开启',
        if (sub?.status != null) '订阅状态': sub!.status!,
        if (billing != null) '计费周期结束': _ymd(billing),
      },
    );
  }
}

// ----------------------------------------------------------------- ClinePass

class ClinePassCredential {
  const ClinePassCredential(this.token, {required this.isOAuth});

  final String token;
  final bool isOAuth;
}

/// Cline `providers.cline.settings`: OAuth `auth.accessToken` first, then `apiKey`, then `auth.apiKey`.
ClinePassCredential? parseClinePassSettings(String text) {
  final settings = asMap(asMap(asMap(decodeJsonObject(text)?['providers'])?['cline'])?['settings']);
  if (settings == null) return null;
  final auth = asMap(settings['auth']);
  final access = asString(auth?['accessToken']);
  if (access != null) {
    return ClinePassCredential(
      access.startsWith('workos:') ? access : 'workos:$access',
      isOAuth: true,
    );
  }
  final key = asString(settings['apiKey']) ?? asString(auth?['apiKey']);
  return key == null ? null : ClinePassCredential(key, isOAuth: false);
}

String _expandHome(String path, String? home) {
  if (home == null) return path;
  if (path == '~') return home;
  if (path.startsWith('~/') || path.startsWith('~\\')) {
    return platform.joinPath(home, path.substring(2));
  }
  return path;
}

/// Same lookup order as the Cline CLI: explicit file, data dir, then CLINE_DIR or ~/.cline.
String? clinePassProvidersPath(String? home) {
  final file = platform.envVar('CLINE_PROVIDER_SETTINGS_PATH');
  if (file != null) return _expandHome(file, home);
  final dataDir = platform.envVar('CLINE_DATA_DIR');
  if (dataDir != null) {
    return platform.joinPath(_expandHome(dataDir, home), 'settings', 'providers.json');
  }
  final clineDir = platform.envVar('CLINE_DIR');
  final root = clineDir != null
      ? _expandHome(clineDir, home)
      : (home == null ? null : platform.joinPath(home, '.cline'));
  return root == null ? null : platform.joinPath(root, 'data', 'settings', 'providers.json');
}

typedef _ClineWindow = ({String id, String label, int minutes});

const _clinePassWindows = <String, _ClineWindow>{
  'five_hour': (id: RateWindow.sessionId, label: '5 小时', minutes: 300),
  'weekly': (id: RateWindow.weeklyId, label: '每周', minutes: 10080),
  'monthly': (id: 'clinepass-monthly', label: '每月', minutes: 43200),
};

/// Plan usage limits. Unknown limit types are ignored, as in CodexBar.
List<RateWindow> parseClinePassUsageLimits(Map<String, Object?> json) {
  const invalid = 'ClinePass 返回了无法识别的用量数据';
  if (json['success'] != true) throw ProviderException(invalid, hint: '接口返回 success 不为 true');
  final limits = asList(asMap(json['data'])?['limits']);
  if (limits == null) throw ProviderException(invalid, hint: '缺少 data.limits');
  final byType = <String, RateWindow>{};
  for (final raw in limits) {
    final limit = asMap(raw);
    final type = limit?['type'];
    if (limit == null || type is! String) throw ProviderException(invalid);
    final spec = _clinePassWindows[type];
    if (spec == null) continue;
    final percent = limit['percentUsed'];
    if (percent is! num || !percent.isFinite) {
      throw ProviderException(invalid, hint: '$type 缺少 percentUsed');
    }
    final resetRaw = limit['resetsAt'];
    if (resetRaw != null && resetRaw is! String) {
      throw ProviderException(invalid, hint: '$type 的 resetsAt 格式错误');
    }
    DateTime? resetsAt;
    if (resetRaw is String) {
      resetsAt = DateTime.tryParse(resetRaw)?.toUtc();
      if (resetsAt == null) throw ProviderException(invalid, hint: '$type 的 resetsAt 无法解析');
    }
    byType[type] = quotaWindow(
      spec.id,
      spec.label,
      usedPercent: _clampPercent(percent),
      resetsAt: resetsAt,
      windowMinutes: spec.minutes,
    );
  }
  return [
    for (final t in _clinePassWindows.keys)
      if (byType[t] != null) byType[t]!,
  ];
}

class ClinePassProvider extends UsageProvider {
  static const _url = 'https://api.cline.bot/api/v1/users/me/plan/usage-limits';

  @override
  String get id => 'clinepass';

  @override
  String get displayName => 'ClinePass';

  @override
  int get brandColor => 0xFF5487C8;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli, SourceType.apiKey];

  @override
  String get setupHint =>
      '粘贴 ClinePass API Key；或在本机运行 cline auth 登录后选择"本机登录"'
      '（只读 Cline 的 providers.json，不刷新令牌）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(label: 'API Key', envVars: ['CLINE_API_KEY', 'CLINEPASS_API_KEY']),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 API Key';

  @override
  String get localSourceLabel => '本机 Cline 登录';

  Future<ClinePassCredential?> _localCredential(AccountConfig account) async {
    if (!platform.localAccessSupported) return null;
    final path = clinePassProvidersPath(account.homeDir ?? platform.homeDirectory());
    if (path == null) return null;
    final text = await platform.readTextFile(path);
    return text == null ? null : parseClinePassSettings(text);
  }

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async =>
      (await _localCredential(account)) != null;

  Future<(ClinePassCredential, String?)> _resolve(AccountConfig account) async {
    if (account.sourceType == SourceType.apiKey) {
      final key = bareToken(FieldValues.of(this, account).secret);
      return (ClinePassCredential(key, isOAuth: false), null);
    }
    final local = await _localCredential(account);
    if (local == null) {
      throw ProviderException('未找到 ClinePass 本机登录', hint: '运行 cline auth 登录，或改用手动粘贴 API Key');
    }
    return (local, '在终端运行 cline auth 重新登录后再刷新');
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final (cred, localHint) = await _resolve(account);
    final json = await _sendJson(
      ctx,
      displayName,
      Uri.parse(_url),
      headers: {'Authorization': 'Bearer ${cred.token}'},
      timeout: const Duration(seconds: 15),
      authHint: '检查 API Key 是否正确，或运行 cline auth 刷新登录',
      expiredHint: localHint,
    );
    return snapshot(
      account,
      ctx,
      source: localHint != null ? 'local' : 'api-key',
      windows: parseClinePassUsageLimits(json),
      extras: {'登录方式': cred.isOAuth ? 'Browser' : 'API key'},
    );
  }
}

// ------------------------------------------------------------------- Augment

class AugmentCredits {
  const AugmentCredits({this.remaining, this.consumed, this.available});

  final double? remaining;
  final double? consumed;
  final double? available;

  double? get limit {
    final a = available;
    if (a != null && a > 0) return a;
    final r = remaining;
    final c = consumed;
    return (r != null && c != null) ? r + c : null;
  }
}

AugmentCredits parseAugmentCredits(Map<String, Object?> json) {
  final credits = AugmentCredits(
    remaining: asDouble(json['usageUnitsRemaining']),
    consumed: asDouble(json['usageUnitsConsumedThisBillingCycle']),
    available: asDouble(json['usageUnitsAvailable']),
  );
  if (credits.remaining == null && credits.consumed == null && credits.available == null) {
    throw ProviderException('Augment 返回了无法识别的积分数据');
  }
  return credits;
}

double augmentUsedPercent(AugmentCredits c) {
  final limit = c.limit;
  if (limit == null || limit <= 0) return 0;
  final consumed = c.consumed;
  if (consumed != null) return pct(consumed, limit);
  final remaining = c.remaining;
  return remaining == null ? 0 : pct(limit - remaining, limit);
}

class AugmentProvider extends UsageProvider {
  static const _base = 'https://app.augmentcode.com';

  @override
  String get id => 'augment';

  @override
  String get displayName => 'Augment';

  @override
  int get brandColor => 0xFF1AA049;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => '浏览器登录 app.augmentcode.com，在开发者工具的网络面板复制任一请求的 Cookie 请求头粘贴进来（手机也能用）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.cookie(label: 'app.augmentcode.com Cookie', hint: '_session=...; ...'),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null || secret.contains('=')) return null;
    return '需要 Cookie 请求头（形如 name=value; ...）';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final headers = {'Cookie': normalizeCookieHeader(FieldValues.of(this, account).secret)};
    const expired = '在浏览器重新登录 app.augmentcode.com 后，粘贴新的 Cookie';
    final credits = parseAugmentCredits(
      await _sendJson(
        ctx,
        displayName,
        Uri.parse('$_base/api/credits'),
        headers: headers,
        expiredHint: expired,
      ),
    );
    Map<String, Object?>? sub;
    try {
      sub = await _sendJson(
        ctx,
        displayName,
        Uri.parse('$_base/api/subscription'),
        headers: headers,
        expiredHint: expired,
      );
    } on ProviderException {
      sub = null;
    }
    final limit = credits.limit;
    final remaining = credits.remaining;
    final used =
        credits.consumed ?? (limit == null || remaining == null ? null : limit - remaining);
    final end = parseFlexibleDate(sub?['billingPeriodEnd']);
    return snapshot(
      account,
      ctx,
      plan: asString(sub?['planName']),
      email: asString(sub?['email']),
      source: 'web',
      windows: [
        if (limit != null)
          quotaWindow(
            'augment-cycle',
            '本计费周期',
            usedPercent: augmentUsedPercent(credits),
            resetsAt: end,
          ),
      ],
      credits: [
        if (limit != null && used != null)
          spendRow('augment-credits', used, limit: limit, label: '积分', currency: null),
      ],
    );
  }
}

// ------------------------------------------------------------------- Factory

const _factoryAuthHint = '检查 API Key / Cookie 是否正确，或重新生成';
const _unlimitedAllowance = 1e12;

/// `FACTORY_API_KEY` line from `~/.factory/.env` (optionally prefixed with `export`).
String? parseFactoryApiKeyFromDotEnv(String text) {
  for (var line in text.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trim();
    final eq = line.indexOf('=');
    if (eq < 0 || line.substring(0, eq).trim() != 'FACTORY_API_KEY') continue;
    return asString(line.substring(eq + 1).trim().replaceAll(RegExp(r'''^["']|["']$'''), ''));
  }
  return null;
}

/// A pasted value with `name=value` pairs is a Cookie header; otherwise it is an API/bearer key.
bool looksLikeFactoryCookie(String value) =>
    value.contains(';') ||
    RegExp(r'^(cookie:\s*)?[\w.-]+=', caseSensitive: false).hasMatch(value.trim());

/// Percent for one token pool: API ratio when valid, else used / allowance (CodexBar rules).
double factoryTokenPercent(Map<String, Object?> tokens) {
  final used = asDouble(tokens['userTokens']) ?? 0;
  final allowance = asDouble(tokens['totalAllowance']) ?? 0;
  final ratio = asDouble(tokens['usedRatio']);
  final ignoreRatio = ratio == 0 && used > 0 && allowance > 0 && allowance <= _unlimitedAllowance;
  if (ratio != null && !ignoreRatio) {
    if (ratio >= -0.001 && ratio <= 1.001) return _clampPercent(ratio * 100);
    final allowanceReliable = allowance > 0 && allowance <= _unlimitedAllowance;
    if (!allowanceReliable && ratio >= -0.1 && ratio <= 100.1) return _clampPercent(ratio);
  }
  if (allowance > _unlimitedAllowance) return _clampPercent(used / 1e8 * 100);
  if (allowance <= 0) return 0;
  return _clampPercent(used / allowance * 100);
}

RateWindow? _factoryWindow(
  Map<String, Object?>? w,
  String id,
  String label,
  int? minutes,
  DateTime now,
) {
  if (w == null) return null;
  final seconds = asDouble(w['secondsRemaining']);
  DateTime? reset;
  if (seconds != null && seconds > 0) reset = now.add(Duration(seconds: seconds.round()));
  if (reset == null) {
    final end = parseFlexibleDate(w['windowEnd']);
    if (end != null && end.isAfter(now)) reset = end;
  }
  // A stale window with only an end date has reset already, as in the Factory web UI.
  final stale = reset == null && w['windowEnd'] != null && seconds == null;
  final raw = asDouble(w['usedPercent']) ?? 0;
  return quotaWindow(
    id,
    label,
    usedPercent: stale ? 0 : _clampPercent(raw),
    resetsAt: reset,
    windowMinutes: minutes,
  );
}

List<RateWindow> _factoryPoolWindows(
  Map<String, Object?>? pool,
  DateTime now, {
  required bool core,
}) {
  final pre = core ? '核心 ' : '';
  return [
    ?_factoryWindow(
      asMap(pool?['fiveHour']),
      core ? 'factory-core-5h' : RateWindow.sessionId,
      '${pre}5 小时',
      300,
      now,
    ),
    ?_factoryWindow(
      asMap(pool?['weekly']),
      core ? 'factory-core-weekly' : RateWindow.weeklyId,
      '$pre每周',
      10080,
      now,
    ),
    ?_factoryWindow(
      asMap(pool?['monthly']),
      core ? 'factory-core-monthly' : 'factory-monthly',
      '$pre每月',
      null,
      now,
    ),
  ];
}

String? _factoryPlan(String? tier, String? planName) {
  final parts = [
    if (tier != null) 'Factory ${_capitalize(tier)}',
    if (planName != null && !planName.toLowerCase().contains('factory')) planName,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

class FactoryProvider extends UsageProvider {
  static const _appBase = 'https://app.factory.ai';
  static const _apiBase = 'https://api.factory.ai';

  @override
  String get id => 'factory';

  @override
  String get displayName => 'Factory';

  @override
  int get brandColor => 0xFFFF6B35;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli, SourceType.apiKey];

  @override
  String get setupHint =>
      '粘贴 fk- 开头的 API Key（推荐，手机也能用），或粘贴 app.factory.ai 的 Cookie 请求头；'
      '桌面端选择"本机配置"时只读 ~/.factory/.env 里的 FACTORY_API_KEY。';

  @override
  List<ProviderField> get fields => const [
    ProviderField(
      key: ProviderField.secretKey,
      label: 'API Key 或 Cookie',
      multiline: true,
      hint: 'fk-... 或 Cookie: ...',
      help: 'API Key 填 fk- 开头的值；网页方式填 app.factory.ai 请求的 Cookie 请求头。',
      envVars: ['FACTORY_API_KEY'],
    ),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 API Key / Cookie';

  @override
  String get localSourceLabel => '本机 Factory 配置';

  Future<String?> _localKey(AccountConfig account) async {
    if (!platform.localAccessSupported) return null;
    final env = platform.envVar('FACTORY_API_KEY');
    if (env != null) return env;
    final home = account.homeDir ?? platform.homeDirectory();
    if (home == null) return null;
    final text = await platform.readTextFile(platform.joinPath(home, '.factory', '.env'));
    return text == null ? null : parseFactoryApiKeyFromDotEnv(text);
  }

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async => (await _localKey(account)) != null;

  Future<_Credential> _credential(AccountConfig account) async {
    if (account.sourceType == SourceType.apiKey) {
      return _Credential(bareToken(FieldValues.of(this, account).secret));
    }
    final key = await _localKey(account);
    if (key == null) {
      throw ProviderException(
        '未找到 Factory 本机 API Key',
        hint: '设置 FACTORY_API_KEY 环境变量，或在 ~/.factory/.env 中写入，或改用手动填写',
      );
    }
    return _Credential(key, localHint: '到 app.factory.ai 重新生成 API Key，并更新 ~/.factory/.env');
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cred = await _credential(account);
    final cookie = looksLikeFactoryCookie(cred.value);
    final source = cred.localHint != null ? 'local' : (cookie ? 'web' : 'api-key');
    final expired = cred.localHint ?? (cookie ? '在浏览器重新登录 app.factory.ai 后，粘贴新的 Cookie' : null);
    final headers = {
      'Origin': _appBase,
      'Referer': '$_appBase/',
      'x-factory-client': 'web-app',
      if (cookie)
        'Cookie': normalizeCookieHeader(cred.value)
      else
        'Authorization': 'Bearer ${cred.value}',
    };
    // Cookie logins only reach app.factory.ai; API keys try the API host first, like CodexBar.
    final bases = cookie ? [_appBase] : [_apiBase, _appBase];
    ProviderException? authError;
    ProviderException? lastError;
    for (final base in bases) {
      try {
        return await _fetchFrom(account, ctx, base, headers, expired, source);
      } on ProviderException catch (e) {
        lastError = e;
        if (e.statusCode == 401 || e.statusCode == 403) authError ??= e;
      }
    }
    throw authError ?? lastError ?? ProviderException('Factory 无法获取用量');
  }

  Future<UsageSnapshot> _fetchFrom(
    AccountConfig account,
    FetchContext ctx,
    String base,
    Map<String, String> headers,
    String? expired,
    String source,
  ) async {
    final now = ctx.now();
    final auth = await _sendJson(
      ctx,
      displayName,
      Uri.parse('$base/api/app/auth/me'),
      headers: headers,
      authHint: _factoryAuthHint,
      expiredHint: expired,
    );
    final org = asMap(auth['organization']);
    final subscription = asMap(org?['subscription']);
    final profile = asMap(auth['userProfile']);
    final plan = _factoryPlan(
      asString(subscription?['factoryTier']),
      asString(asMap(asMap(subscription?['orbSubscription'])?['plan'])?['name']),
    );
    final email = asString(profile?['email']);
    final orgName = asString(org?['name']);
    final orgExtras = {'组织': ?orgName};

    final billing = await _optionalJson(ctx, '$_apiBase/api/billing/limits', headers);
    final limits = asMap(billing?['limits']);
    if (billing?['usesTokenRateLimitsBilling'] == true && limits != null) {
      return snapshot(
        account,
        ctx,
        plan: plan,
        email: email,
        source: source,
        extras: orgExtras,
        windows: [
          ..._factoryPoolWindows(asMap(limits['standard']), now, core: false),
          ..._factoryPoolWindows(asMap(limits['core']), now, core: true),
        ],
      );
    }

    final userId = asString(profile?['id']);
    final usageUri = Uri.parse('$base/api/organization/subscription/usage')
        .replace(queryParameters: {'useCache': 'true', 'userId': ?userId});
    final usage = await _sendJson(
      ctx,
      displayName,
      usageUri,
      headers: headers,
      authHint: _factoryAuthHint,
      expiredHint: expired,
    );
    final data = asMap(usage['usage']);
    final standard = asMap(data?['standard']) ?? const <String, Object?>{};
    final premium = asMap(data?['premium']);
    final end = parseFlexibleDate(data?['endDate']);
    return snapshot(
      account,
      ctx,
      plan: plan,
      email: email,
      source: source,
      extras: {
        ...orgExtras,
        '标准 Tokens 已用': '${_num(standard['userTokens'])} / ${_num(standard['totalAllowance'])}',
      },
      windows: [
        quotaWindow(
          'factory-standard',
          '标准 Tokens',
          usedPercent: factoryTokenPercent(standard),
          resetsAt: end,
        ),
        if (premium != null && (asDouble(premium['totalAllowance']) ?? 0) > 0)
          quotaWindow(
            'factory-premium',
            '高级 Tokens',
            usedPercent: factoryTokenPercent(premium),
            resetsAt: end,
          ),
      ],
    );
  }

  /// Optional request: any failure yields null (CodexBar treats billing limits as best-effort).
  Future<Map<String, Object?>?> _optionalJson(
    FetchContext ctx,
    String url,
    Map<String, String> headers,
  ) async {
    try {
      return await _sendJson(ctx, displayName, Uri.parse(url), headers: headers);
    } on ProviderException {
      return null;
    }
  }
}

// ---------------------------------------------------------------- OpenCode Go

/// One meter as a window. [fractionOk] lets console values in 0..1 be read as fractions.
RateWindow? openCodeGoMeterWindow(
  Map<String, Object?>? meter, {
  required String id,
  required String label,
  required int minutes,
  required DateTime now,
  DateTime? fallbackReset,
  bool fractionOk = false,
}) {
  if (meter == null) return null;
  final raw = asDouble(meter['usagePercent']);
  if (raw == null) throw ProviderException('OpenCode Go 返回了无法识别的 $label 用量');
  final percent = fractionOk && raw >= 0 && raw <= 1 ? raw * 100 : raw;
  final secs = asDouble(meter['resetInSec']);
  final reset = (secs != null && secs > 0)
      ? now.add(Duration(seconds: secs.round()))
      : (parseFlexibleDate(meter['resetsAt']) ?? fallbackReset);
  return quotaWindow(
    id,
    label,
    usedPercent: _clampPercent(percent),
    resetsAt: reset,
    windowMinutes: minutes,
  );
}

class OpenCodeGoProvider extends UsageProvider {
  static const _apiUrl = 'https://opencode.ai/zen/go/v1/usage';
  static const _consoleUrl = 'https://opencode.ai/console/api/go/status';
  static final _workspacePattern = RegExp(r'^(wrk_|org_)[A-Za-z0-9_-]+$');

  @override
  String get id => 'opencodego';

  @override
  String get displayName => 'OpenCode Go';

  @override
  int get brandColor => 0xFF3B82F6;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '粘贴 OpenCode Go 的 API Key（推荐，手机也能用）；或粘贴 opencode.ai 控制台的 Cookie 请求头，'
      '并填写工作区 ID（wrk_… 或 org_…）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField(
      key: ProviderField.secretKey,
      label: 'API Key',
      required: false,
      hint: 'OpenCode Go 的 API Key',
      envVars: ['OPENCODE_API_KEY'],
    ),
    ProviderField(
      key: 'cookie',
      label: 'opencode.ai Cookie',
      required: false,
      multiline: true,
      help: '不使用 API Key 时：登录 opencode.ai 控制台后复制 Cookie 请求头，并填写下面的工作区 ID。',
    ),
    ProviderField(
      key: 'workspaceId',
      label: '工作区 ID（Cookie 模式）',
      kind: FieldKind.text,
      required: false,
      hint: 'wrk_...',
      envVars: ['CODEXBAR_OPENCODEGO_WORKSPACE_ID'],
    ),
  ];

  @override
  String? validateManual(FieldValues values) {
    if (values[ProviderField.secretKey] == null && values['cookie'] == null) {
      return '需要 API Key 或 Cookie 二选一';
    }
    final ws = values['workspaceId'];
    if (ws != null && !_workspacePattern.hasMatch(ws)) return '工作区 ID 应形如 wrk_... 或 org_...';
    return null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final key = v[ProviderField.secretKey];
    if (key != null) return _fetchApi(account, ctx, bareToken(key));
    final cookie = v['cookie'];
    if (cookie == null) {
      throw ProviderException(
        '未填写 OpenCode Go 的 API Key 或 Cookie',
        hint: '在账户设置中填写 API Key（推荐）或 Cookie',
      );
    }
    final workspace = v['workspaceId'];
    if (workspace == null) {
      throw ProviderException(
        'Cookie 模式需要工作区 ID',
        hint: '在 opencode.ai 控制台的工作区页面网址中找到 wrk_ 开头的 ID 并填写',
      );
    }
    return _fetchConsole(account, ctx, normalizeCookieHeader(cookie), workspace);
  }

  Future<UsageSnapshot> _fetchApi(AccountConfig account, FetchContext ctx, String key) async {
    final json = await _sendJson(
      ctx,
      displayName,
      Uri.parse(_apiUrl),
      headers: {'Authorization': 'Bearer $key', 'User-Agent': ctx.userAgent},
      authHint: 'API Key 无效，请到 opencode.ai 控制台重新生成',
      timeout: const Duration(seconds: 15),
    );
    final usage = asMap(json['usage']);
    final rolling = asMap(usage?['rolling']);
    if (rolling == null) {
      throw ProviderException('OpenCode Go 返回了无法识别的用量', hint: '缺少 usage.rolling');
    }
    final now = ctx.now();
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      windows: [
        ?openCodeGoMeterWindow(
          rolling,
          id: RateWindow.sessionId,
          label: '5 小时',
          minutes: 300,
          now: now,
        ),
        ?openCodeGoMeterWindow(
          asMap(usage?['weekly']),
          id: RateWindow.weeklyId,
          label: '每周',
          minutes: 10080,
          now: now,
        ),
        ?openCodeGoMeterWindow(
          asMap(usage?['monthly']),
          id: 'opencodego-monthly',
          label: '每月',
          minutes: 43200,
          now: now,
        ),
      ],
    );
  }

  Future<UsageSnapshot> _fetchConsole(
    AccountConfig account,
    FetchContext ctx,
    String cookie,
    String workspace,
  ) async {
    final json = await _sendJson(
      ctx,
      displayName,
      Uri.parse(_consoleUrl),
      headers: {'Cookie': cookie, 'x-org-id': workspace, 'User-Agent': ctx.userAgent},
      authHint: '检查工作区 ID 是否正确',
      expiredHint: '在浏览器重新登录 opencode.ai 后，粘贴新的 Cookie',
    );
    if (json['access'] == null) {
      throw ProviderException('该工作区没有 OpenCode Go 订阅', hint: '确认工作区 ID 正确，且已订阅 OpenCode Go');
    }
    final access = asMap(json['access']);
    final meters = asMap(access?['meters']);
    if (meters == null || meters['fiveHour'] == null) {
      throw ProviderException('OpenCode Go 控制台返回了无法识别的用量');
    }
    final now = ctx.now();
    final endsAt = parseFlexibleDate(access?['endsAt']);
    return snapshot(
      account,
      ctx,
      source: 'web',
      windows: [
        ?openCodeGoMeterWindow(
          asMap(meters['fiveHour']),
          id: RateWindow.sessionId,
          label: '5 小时',
          minutes: 300,
          now: now,
          fractionOk: true,
        ),
        ?openCodeGoMeterWindow(
          asMap(meters['week']),
          id: RateWindow.weeklyId,
          label: '每周',
          minutes: 10080,
          now: now,
          fractionOk: true,
        ),
        ?openCodeGoMeterWindow(
          asMap(meters['month']),
          id: 'opencodego-monthly',
          label: '每月',
          minutes: 43200,
          now: now,
          fallbackReset: endsAt,
          fractionOk: true,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- Windsurf

const _windsurfPlanUrl =
    'https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus';

/// Protobuf request: field 1 `auth_token` (string), field 2 `include_top_up_status` (true).
Uint8List encodeWindsurfPlanStatusRequest(String sessionToken) {
  final token = utf8.encode(sessionToken);
  return Uint8List.fromList([0x0A, ..._varint(token.length), ...token, 0x10, 0x01]);
}

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

class WindsurfPlanStatus {
  const WindsurfPlanStatus({
    this.planName,
    this.planEnd,
    this.dailyRemaining,
    this.weeklyRemaining,
    this.dailyReset,
    this.weeklyReset,
  });

  final String? planName;
  final DateTime? planEnd;
  final int? dailyRemaining;
  final int? weeklyRemaining;
  final DateTime? dailyReset;
  final DateTime? weeklyReset;
}

class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get done => _pos >= _bytes.length;

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (_pos >= _bytes.length) break;
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
    }
    throw ProviderException('Windsurf 返回了损坏的数据');
  }

  (int, int) key() {
    final k = varint();
    return (k >> 3, k & 7);
  }

  Uint8List bytes() {
    final length = varint();
    if (_pos + length > _bytes.length) throw ProviderException('Windsurf 返回了损坏的数据');
    final out = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return out;
  }

  void skip(int wire) {
    if (wire == 0) {
      varint();
    } else if (wire == 1) {
      _pos += 8;
    } else if (wire == 2) {
      bytes();
    } else if (wire == 5) {
      _pos += 4;
    } else {
      throw ProviderException('Windsurf 返回了不支持的 protobuf 字段');
    }
  }
}

String? _decodePlanName(Uint8List bytes) {
  final r = _ProtoReader(bytes);
  String? name;
  while (!r.done) {
    final (field, wire) = r.key();
    if (field == 2 && wire == 2) {
      name = asString(utf8.decode(r.bytes(), allowMalformed: true));
    } else {
      r.skip(wire);
    }
  }
  return name;
}

DateTime? _decodeTimestamp(Uint8List bytes) {
  final r = _ProtoReader(bytes);
  int? seconds;
  while (!r.done) {
    final (field, wire) = r.key();
    if (field == 1 && wire == 0) {
      seconds = r.varint();
    } else {
      r.skip(wire);
    }
  }
  return seconds == null ? null : epochSeconds(seconds);
}

WindsurfPlanStatus _decodePlanStatus(Uint8List bytes) {
  final r = _ProtoReader(bytes);
  String? planName;
  DateTime? planEnd;
  int? daily;
  int? weekly;
  int? dailyReset;
  int? weeklyReset;
  while (!r.done) {
    final (field, wire) = r.key();
    if (field == 1 && wire == 2) {
      planName = _decodePlanName(r.bytes());
    } else if (field == 3 && wire == 2) {
      planEnd = _decodeTimestamp(r.bytes());
    } else if (field == 14 && wire == 0) {
      daily = r.varint();
    } else if (field == 15 && wire == 0) {
      weekly = r.varint();
    } else if (field == 17 && wire == 0) {
      dailyReset = r.varint();
    } else if (field == 18 && wire == 0) {
      weeklyReset = r.varint();
    } else {
      r.skip(wire);
    }
  }
  return WindsurfPlanStatus(
    planName: planName,
    planEnd: planEnd,
    dailyRemaining: daily,
    weeklyRemaining: weekly,
    dailyReset: dailyReset == null ? null : epochSeconds(dailyReset),
    weeklyReset: weeklyReset == null ? null : epochSeconds(weeklyReset),
  );
}

/// GetPlanStatus response: field 1 is the plan status message.
WindsurfPlanStatus parseWindsurfPlanStatusResponse(Uint8List bytes) {
  final root = _ProtoReader(bytes);
  Uint8List? status;
  while (!root.done) {
    final (field, wire) = root.key();
    if (field == 1 && wire == 2) {
      status = root.bytes();
    } else {
      root.skip(wire);
    }
  }
  if (status == null) throw ProviderException('Windsurf 返回了无法解析的套餐数据');
  return _decodePlanStatus(status);
}

RateWindow? _counterWindow(String id, String label, {int? used, int? remaining, int? total}) {
  if (total == null || total <= 0) return null;
  final consumed = used ?? (remaining == null ? null : total - remaining);
  if (consumed == null) return null;
  return quotaWindow(id, label, usedPercent: pct(consumed.clamp(0, total), total));
}

/// Windows from the desktop cache (`windsurf.settings.cachedPlanInfo`), which only updates when Windsurf starts.
List<RateWindow> parseWindsurfCachedPlan(Map<String, Object?> json) {
  final quota = asMap(json['quotaUsage']);
  final daily = asDouble(quota?['dailyRemainingPercent']);
  final weekly = asDouble(quota?['weeklyRemainingPercent']);
  if (quota != null && (daily != null || weekly != null)) {
    return [
      if (daily != null)
        quotaWindow(
          'windsurf-daily',
          '每日',
          usedPercent: _clampPercent(100 - daily),
          resetsAt: epochSeconds(asInt(quota['dailyResetAtUnix'])),
        ),
      if (weekly != null)
        quotaWindow(
          'windsurf-weekly',
          '每周',
          usedPercent: _clampPercent(100 - weekly),
          resetsAt: epochSeconds(asInt(quota['weeklyResetAtUnix'])),
        ),
    ];
  }
  final usage = asMap(json['usage']);
  if (usage == null) return [];
  return [
    ?_counterWindow(
      'windsurf-messages',
      '消息',
      used: asInt(usage['usedMessages']),
      remaining: asInt(usage['remainingMessages']),
      total: asInt(usage['messages']),
    ),
    ?_counterWindow(
      'windsurf-flow',
      'Flow Actions',
      used: asInt(usage['usedFlowActions']),
      remaining: asInt(usage['remainingFlowActions']),
      total: asInt(usage['flowActions']),
    ),
  ];
}

/// Windsurf's `state.vscdb` (VS Code layout) under the app data directory.
String? _windsurfStateDb() {
  final String? root;
  if (platform.isWindows) {
    final appData = platform.envVar('APPDATA');
    root = appData == null ? null : platform.joinPath(appData, 'Windsurf');
  } else if (platform.isMacOS) {
    final home = platform.homeDirectory();
    root = home == null
        ? null
        : platform.joinPath(home, 'Library', 'Application Support', 'Windsurf');
  } else {
    final home = platform.homeDirectory();
    root = home == null ? null : platform.joinPath(home, '.config', 'Windsurf');
  }
  return root == null ? null : platform.joinPath(root, 'User', 'globalStorage', 'state.vscdb');
}

class WindsurfProvider extends UsageProvider {
  @override
  String get id => 'windsurf';

  @override
  String get displayName => 'Windsurf';

  @override
  int get brandColor => 0xFF34E8BB;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli, SourceType.apiKey];

  @override
  String get setupHint =>
      '在 windsurf.com 登录后，从浏览器的 Local Storage（app.devin.ai 或 windsurf.com）复制 4 个 devin_* 值，'
      '手机也能用。本机模式只读 Windsurf 的套餐缓存（可能过期，Windsurf 启动后才更新）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField(key: 'devin_session_token', label: 'devin_session_token', help: '会话 Token'),
    ProviderField(key: 'devin_auth1_token', label: 'devin_auth1_token', help: 'auth1 Token'),
    ProviderField(key: 'devin_account_id', label: 'devin_account_id', help: '账户 ID'),
    ProviderField(key: 'devin_primary_org_id', label: 'devin_primary_org_id', help: '主组织 ID'),
  ];

  @override
  String get manualSourceLabel => '手动粘贴会话值';

  @override
  String get localSourceLabel => '本机 Windsurf 缓存';

  Future<String?> _cachedPlanJson() async {
    final db = _windsurfStateDb();
    if (db == null || !platform.localAccessSupported) return null;
    return platform.readSqliteText(db, 'SELECT value FROM ItemTable WHERE key = ?', [
      'windsurf.settings.cachedPlanInfo',
    ]);
  }

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async => (await _cachedPlanJson()) != null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    if (account.sourceType == SourceType.apiKey) return _fetchWeb(account, ctx);
    return _fetchLocal(account, ctx);
  }

  Future<UsageSnapshot> _fetchWeb(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final session = v.require('devin_session_token');
    final auth1 = v.require('devin_auth1_token');
    final accountId = v.require('devin_account_id');
    final orgId = v.require('devin_primary_org_id');
    final status = parseWindsurfPlanStatusResponse(
      await _postProto(ctx, Uri.parse(_windsurfPlanUrl), {
        'Content-Type': 'application/proto',
        'Connect-Protocol-Version': '1',
        'Origin': 'https://windsurf.com',
        'Referer': 'https://windsurf.com/profile',
        'x-auth-token': session,
        'x-devin-session-token': session,
        'x-devin-auth1-token': auth1,
        'x-devin-account-id': accountId,
        'x-devin-primary-org-id': orgId,
      }, encodeWindsurfPlanStatusRequest(session)),
    );
    final daily = status.dailyRemaining;
    final weekly = status.weeklyRemaining;
    final planEnd = status.planEnd;
    return snapshot(
      account,
      ctx,
      plan: status.planName,
      source: 'web',
      windows: [
        if (daily != null)
          quotaWindow(
            'windsurf-daily',
            '每日',
            usedPercent: _clampPercent(100 - daily),
            resetsAt: status.dailyReset,
          ),
        if (weekly != null)
          quotaWindow(
            'windsurf-weekly',
            '每周',
            usedPercent: _clampPercent(100 - weekly),
            resetsAt: status.weeklyReset,
          ),
      ],
      extras: {if (planEnd != null) '套餐到期': _ymd(planEnd)},
    );
  }

  Future<UsageSnapshot> _fetchLocal(AccountConfig account, FetchContext ctx) async {
    final raw = await _cachedPlanJson();
    final json = raw == null ? null : decodeJsonObject(raw);
    if (json == null) {
      throw ProviderException('未找到 Windsurf 本机缓存', hint: '打开 Windsurf 桌面端并登录一次，或改用手动粘贴会话值');
    }
    final endMs = asInt(json['endTimestamp']);
    final end = endMs == null ? null : parseFlexibleDate(endMs);
    return snapshot(
      account,
      ctx,
      plan: asString(json['planName']),
      source: 'local',
      windows: parseWindsurfCachedPlan(json),
      extras: {'数据来源': '本机缓存（仅在 Windsurf 启动时更新，可能过期）', if (end != null) '套餐到期': _ymd(end)},
    );
  }

  Future<Uint8List> _postProto(
    FetchContext ctx,
    Uri url,
    Map<String, String> headers,
    Uint8List body,
  ) async {
    final request = http.Request('POST', url)
      ..headers.addAll(headers)
      ..bodyBytes = body;
    try {
      final streamed = await ctx.client.send(request).timeout(_defaultTimeout);
      final response = await http.Response.fromStream(streamed).timeout(_defaultTimeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw ProviderException(
          'Windsurf 会话已过期 (HTTP ${response.statusCode})',
          hint: '刷新 windsurf.com/profile 页面后，粘贴新的会话值',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != 200) {
        throw ProviderException(
          'Windsurf 接口错误 HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return response.bodyBytes;
    } on TimeoutException {
      throw ProviderException('Windsurf 请求超时', hint: '检查网络后重试');
    } on http.ClientException catch (e) {
      throw ProviderException('Windsurf 网络错误: ${e.message}', hint: '检查网络或代理设置');
    }
  }
}
