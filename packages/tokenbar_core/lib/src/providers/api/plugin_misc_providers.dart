import 'dart:convert';

import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

const _maxSafeInt = 9007199254740991;

ProviderException _malformed(String provider) =>
    ProviderException('$provider 返回了无法识别的数据', hint: '接口格式可能已变化，请稍后重试');

int _nonNegInt(String provider, Object? v) {
  if (v is num && v >= 0 && v <= _maxSafeInt && v == v.truncate()) return v.toInt();
  throw _malformed(provider);
}

String _grouped(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

String _fixed1(double v) {
  final parts = v.toStringAsFixed(1).split('.');
  return '${_grouped(int.parse(parts[0]))}.${parts[1]}';
}

/// One decimal unless the value is whole, matching CodexBar's display.
String _dec(double v) => v == v.roundToDouble() ? _grouped(v.round()) : _fixed1(v);

/// Accepts `https://` origins only; the credential must never travel over HTTP.
String _httpsBase(String provider, String raw) {
  final text = raw.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.isScheme('https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ProviderException('$provider 的地址无效: $text', hint: '需要以 https:// 开头的完整地址，且不能包含账号密码');
  }
  return text;
}

String? _validateHttpsField(String provider, FieldValues values, String key) {
  final url = values[key];
  if (url == null) return null;
  try {
    _httpsBase(provider, url);
    return null;
  } on ProviderException catch (e) {
    return e.message;
  }
}

// ----------------------------------------------------------------- Deepgram

const _deepgramDefaultBase = 'https://api.deepgram.com/v1';

class _DeepgramUsage {
  const _DeepgramUsage({
    this.start,
    this.end,
    this.hours = 0,
    this.totalHours = 0,
    this.agentHours = 0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.ttsCharacters = 0,
    this.requests = 0,
  });

  final String? start;
  final String? end;
  final double hours;
  final double totalHours;
  final double agentHours;
  final int tokensIn;
  final int tokensOut;
  final int ttsCharacters;
  final int requests;

  _DeepgramUsage operator +(_DeepgramUsage o) => _DeepgramUsage(
    start: _earlier(start, o.start),
    end: _later(end, o.end),
    hours: hours + o.hours,
    totalHours: totalHours + o.totalHours,
    agentHours: agentHours + o.agentHours,
    tokensIn: tokensIn + o.tokensIn,
    tokensOut: tokensOut + o.tokensOut,
    ttsCharacters: ttsCharacters + o.ttsCharacters,
    requests: requests + o.requests,
  );

  static String? _earlier(String? a, String? b) =>
      a == null ? b : (b == null || a.compareTo(b) <= 0 ? a : b);
  static String? _later(String? a, String? b) =>
      a == null ? b : (b == null || a.compareTo(b) >= 0 ? a : b);
}

double _realOrZero(String provider, Object? v) {
  if (v == null) return 0;
  if (v is num && v.isFinite) return v.toDouble();
  throw _malformed(provider);
}

/// Sums one `/projects/{id}/usage/breakdown` response.
_DeepgramUsage _parseDeepgramUsage(String provider, Map<String, Object?> json) {
  final rows = asList(json['results']) ?? (throw _malformed(provider));
  var total = _DeepgramUsage(start: asString(json['start']), end: asString(json['end']));
  for (final item in rows) {
    final row = asMap(item) ?? (throw _malformed(provider));
    total =
        total +
        _DeepgramUsage(
          hours: _realOrZero(provider, row['hours']),
          totalHours: _realOrZero(provider, row['total_hours']),
          agentHours: _realOrZero(provider, row['agent_hours']),
          tokensIn: row['tokens_in'] == null ? 0 : _nonNegInt(provider, row['tokens_in']),
          tokensOut: row['tokens_out'] == null ? 0 : _nonNegInt(provider, row['tokens_out']),
          ttsCharacters: row['tts_characters'] == null
              ? 0
              : _nonNegInt(provider, row['tts_characters']),
          requests: row['requests'] == null ? 0 : _nonNegInt(provider, row['requests']),
        );
  }
  return total;
}

class DeepgramProvider extends UsageProvider {
  @override
  String get id => 'deepgram';

  @override
  String get displayName => 'Deepgram';

  @override
  int get brandColor => 0xFF6467F2;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      'Deepgram 控制台（console.deepgram.com）的 API Key，需要该项目的 usage:read 权限。'
      '项目 ID 可选，留空则汇总 Key 可见的全部项目。只显示用量（请求数、音频时长、Token、TTS 字符），不含余额。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(label: 'API Key', hint: 'dg_...', envVars: ['DEEPGRAM_API_KEY']),
    ProviderField(
      key: 'projectId',
      label: '项目 ID（可选）',
      kind: FieldKind.text,
      required: false,
      hint: 'UUID，留空则汇总全部项目',
      envVars: ['DEEPGRAM_PROJECT_ID'],
    ),
    ProviderField.baseUrl(
      defaultValue: _deepgramDefaultBase,
      label: 'API 地址（可选）',
      envVars: ['DEEPGRAM_API_URL'],
      help: '必须是 https:// 地址',
    ),
  ];

  @override
  String? validateManual(FieldValues values) => _validateHttpsField(displayName, values, 'baseUrl');

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final base = _httpsBase(displayName, v['baseUrl'] ?? _deepgramDefaultBase);
    final headers = {'Authorization': 'Token ${v.secret}'};
    Future<Map<String, Object?>> getJson(String path, String hint) => fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('$base$path'),
      headers: headers,
      authHint: hint,
      timeout: const Duration(seconds: 15),
    );

    final projects = <({String id, String? name})>[];
    final configured = v['projectId'];
    if (configured != null) {
      projects.add((id: configured, name: null));
    } else {
      final listing =
          asList((await getJson('/projects', '检查 API Key 是否有效'))['projects']) ??
          (throw _malformed(displayName));
      for (final item in listing) {
        final project = asMap(item);
        final id = asString(project?['project_id']) ?? (throw _malformed(displayName));
        projects.add((id: id, name: asString(project?['name'])));
      }
    }
    if (projects.isEmpty) {
      throw ProviderException('Deepgram 没有返回可用项目', hint: '检查 API Key 权限，或在账户设置中填写项目 ID');
    }

    var total = const _DeepgramUsage();
    for (final p in projects) {
      final breakdown = await getJson(
        '/projects/${Uri.encodeComponent(p.id)}/usage/breakdown',
        '需要该项目的 usage:read 权限',
      );
      total = total + _parseDeepgramUsage(displayName, breakdown);
    }

    final names = [for (final p in projects) p.name ?? p.id];
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      extras: {
        '请求数': _grouped(total.requests),
        if (total.hours > 0 || total.totalHours > 0)
          '音频时长': '${_dec(total.hours)} 小时（计费 ${_dec(total.totalHours)} 小时）',
        if (total.agentHours > 0) 'Agent 时长': '${_dec(total.agentHours)} 小时',
        if (total.tokensIn + total.tokensOut > 0)
          'Token 数': _grouped(total.tokensIn + total.tokensOut),
        if (total.ttsCharacters > 0) 'TTS 字符': _grouped(total.ttsCharacters),
        if (total.start != null && total.end != null) '统计周期': '${total.start} 至 ${total.end}',
        '项目': names.join('、'),
      },
    );
  }
}

// --------------------------------------------------------------------- Nous

const _nousDefaultPortal = 'https://portal.nousresearch.com';
final _decimalText = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$');

ProviderException _nousMalformed(String field) =>
    ProviderException('Nous Portal 返回了无效的账户数据: $field', hint: '接口格式可能已变化，请稍后重试');

/// Money fields are finite JSON numbers or decimal strings; anything else is a parse failure.
double? _money(Object? v, String field) {
  if (v == null) return null;
  final text = v is String ? v.trim() : null;
  final n = v is num
      ? v.toDouble()
      : (text != null && _decimalText.hasMatch(text) ? double.tryParse(text) : null);
  if (n == null || !n.isFinite) throw _nousMalformed(field);
  return n;
}

Map<String, Object?> _nousObject(Object? v, String field) {
  if (v == null) return const <String, Object?>{};
  return asMap(v) ?? (throw _nousMalformed(field));
}

DateTime? _nousRenewal(Object? v) {
  if (v == null) return null;
  final parsed = v is String ? DateTime.tryParse(v.trim()) : null;
  if (parsed == null) throw _nousMalformed('current_period_end');
  return parsed.toUtc();
}

/// Nous Portal account credits (subscription, top-up, total). The access token is
/// pasted by the user; it is never refreshed here (refresh tokens rotate).
class NousProvider extends UsageProvider {
  @override
  String get id => 'nous';

  @override
  String get displayName => 'Nous Portal';

  @override
  int get brandColor => 0xFFD6A55C;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '在 Hermes Agent 里登录 Nous Portal（运行 hermes），然后把 ~/.hermes/auth.json 里的 access_token 粘贴进来。'
      '访问令牌约 1 小时有效，过期后重新运行 hermes 并更新。推理用的 API Key 无法查询额度。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: '访问令牌',
      envVars: ['NOUS_PORTAL_ACCESS_TOKEN'],
      help: 'Hermes 登录后 ~/.hermes/auth.json 中的 access_token',
    ),
    ProviderField.baseUrl(
      defaultValue: _nousDefaultPortal,
      label: 'Portal 地址（可选）',
      envVars: ['NOUS_PORTAL_BASE_URL', 'HERMES_PORTAL_BASE_URL'],
      help: '必须是 https:// 地址',
    ),
  ];

  @override
  String? validateManual(FieldValues values) => _validateHttpsField(displayName, values, 'baseUrl');

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final base = _httpsBase(displayName, v['baseUrl'] ?? _nousDefaultPortal);
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$base/api/oauth/account'),
      headers: {'Authorization': 'Bearer ${bareToken(v.secret)}'},
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401) {
      throw ProviderException(
        'Nous Portal 登录已过期',
        hint: '在 Hermes Agent 里运行 hermes 重新登录，然后更新访问令牌',
        statusCode: 401,
      );
    }
    checkStatus(displayName, r, authHint: '检查访问令牌是否有效');
    return _snapshot(account, ctx, r.json);
  }

  UsageSnapshot _snapshot(AccountConfig account, FetchContext ctx, Object? json) {
    final root = asMap(json) ?? (throw _nousMalformed('expected an object'));
    if (root['error'] == true || asString(root['error']) != null) {
      throw ProviderException('Nous Portal 账户接口返回了错误', hint: '稍后再试');
    }
    final sub = _nousObject(root['subscription'], 'subscription');
    final access = _nousObject(root['paid_service_access'], 'paid_service_access');
    final user = _nousObject(root['user'], 'user');
    final org = _nousObject(root['organisation'], 'organisation');

    final monthly = _money(sub['monthly_credits'], 'monthly_credits');
    if (monthly != null && monthly < 0) throw _nousMalformed('monthly_credits');
    final remaining =
        _money(sub['credits_remaining'], 'credits_remaining') ??
        _money(access['subscription_credits_remaining'], 'subscription_credits_remaining');
    final rollover = _money(sub['rollover_credits'], 'rollover_credits');
    final purchased =
        _money(root['purchased_credits_remaining'], 'purchased_credits_remaining') ??
        _money(
          access['purchased_credits_remaining'],
          'paid_service_access.purchased_credits_remaining',
        );
    final total = _money(access['total_usable_credits'], 'total_usable_credits');
    if ([monthly, remaining, rollover, purchased, total].every((x) => x == null)) {
      throw _nousMalformed('no credit amounts');
    }
    final renewal = _nousRenewal(sub['current_period_end']);

    final orgName = asString(org['name']);
    final planName =
        asString(sub['plan']) ??
        (access['has_active_subscription'] == true ? 'Subscription' : null);
    return snapshot(
      account,
      ctx,
      plan: planName,
      email: asString(user['email']),
      source: 'api-key',
      windows: [
        if (monthly != null && monthly > 0 && remaining != null)
          quotaWindow(
            'nous-monthly',
            '月度额度',
            usedPercent: pct(monthly - remaining, monthly),
            resetsAt: renewal,
          ),
      ],
      credits: [
        if (remaining != null)
          balanceRow('nous-subscription', remaining < 0 ? 0 : remaining, label: '订阅额度'),
        if (rollover != null && rollover > 0) balanceRow('nous-rollover', rollover, label: '结转额度'),
        if (purchased != null) balanceRow('nous-topup', purchased, label: '加油包余额'),
        if (total != null) balanceRow('nous-total', total, label: '总可用额度'),
      ],
      extras: {
        if (monthly != null) '月度额度': moneyText(monthly, 'USD'),
        '续费日期': ?renewal?.toIso8601String().substring(0, 10),
        '组织': ?orgName,
      },
    );
  }
}

// ------------------------------------------------------------------- llmman

const _llmmanDefaultHost = 'http://127.0.0.1:17434';
const _llmmanName = 'llmman';

/// Normalizes a daemon address the way `llmman serve` reads `LLMMAN_HOST`: a scheme-less
/// host uses HTTP on port 17434, a trailing `/v1` is dropped, and plain HTTP is only
/// allowed for loopback/private hosts. Credentials, queries and fragments are rejected.
String llmmanBaseUrl(String raw) {
  final text = raw.trim().replaceAll(RegExp(r'/+$'), '');
  final hasScheme = text.contains('://');
  final uri = Uri.tryParse(hasScheme ? text : 'http://$text');
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ProviderException('llmman 的地址无效: $text', hint: '使用 http(s)://主机:端口，不能包含账号密码、查询参数或 #');
  }
  final hostPort = (hasScheme ? text.replaceFirst(RegExp(r'^[a-zA-Z][\w+.-]*://'), '') : text)
      .split('/')
      .first;
  final explicitPort = hostPort.contains(']') ? hostPort.contains(']:') : hostPort.contains(':');
  final host = uri.host == '0.0.0.0' ? '127.0.0.1' : uri.host;
  final port = explicitPort ? ':${uri.port}' : (hasScheme ? '' : ':17434');
  final path = uri.path.replaceFirst(RegExp(r'/v1$'), '');
  final hostText = host.contains(':') ? '[$host]' : host;
  return gatewayBaseUrl(_llmmanName, '${uri.scheme}://$hostText$port$path');
}

ProviderException _llmmanMalformed() => _malformed(_llmmanName);

int _llmmanBytes(Object? v) => _nonNegInt(_llmmanName, v);

/// Loaded or stored models as (name, bytes), largest first.
List<MapEntry<String, int>> _llmmanModels(Object? v) {
  final map = asMap(v) ?? (throw _llmmanMalformed());
  final list = [for (final e in map.entries) MapEntry(e.key, _llmmanBytes(e.value))];
  list.sort((a, b) => a.value != b.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  return list;
}

int _llmmanSum(List<MapEntry<String, int>> models) => models.fold(0, (sum, e) => sum + e.value);

/// Decimal units, as `llmman list` and `llmman ps` print them.
String _llmmanSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  final scale = bytes >= 1000000000 ? 1e9 : (bytes >= 1000000 ? 1e6 : 1e3);
  final unit = bytes >= 1000000000 ? 'GB' : (bytes >= 1000000 ? 'MB' : 'kB');
  return '${_fixed1(bytes / scale)} $unit';
}

class LlmmanProvider extends UsageProvider {
  @override
  String get id => 'llmman';

  @override
  String get displayName => _llmmanName;

  @override
  int get brandColor => 0xFF6CC5B0;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '运行 llmman serve 的主机地址（默认 http://127.0.0.1:17434，局域网可填 http://IP:端口，公网必须 https://）。'
      '守护进程设置了 LLMMAN_API_KEYS 时才需要 API Key。显示已加载模型占用的内存，没有额度重置。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: 'API Key（可选）',
      required: false,
      envVars: ['LLMMAN_API_KEY'],
      help: '仅当守护进程设置了 LLMMAN_API_KEYS 时需要',
    ),
    ProviderField.baseUrl(
      defaultValue: _llmmanDefaultHost,
      label: '服务地址',
      envVars: ['LLMMAN_HOST'],
      help: '本机默认 http://127.0.0.1:17434；局域网可用 http://，公网必须 https://',
    ),
  ];

  @override
  String? validateManual(FieldValues values) {
    final url = values['baseUrl'];
    if (url == null) return null;
    try {
      llmmanBaseUrl(url);
      return null;
    } on ProviderException catch (e) {
      return e.message;
    }
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final base = llmmanBaseUrl(v['baseUrl'] ?? _llmmanDefaultHost);
    final key = v[ProviderField.secretKey];
    final headers = {if (key != null) 'Authorization': 'Bearer ${bareToken(key)}'};

    final node = await _probe(ctx, base, '/llmman/node', headers);
    if (node.statusCode == 401 || node.statusCode == 403) {
      if (key == null) {
        throw ProviderException(
          'llmman 需要 API Key',
          hint: '在账户设置中填写，或设置环境变量 LLMMAN_API_KEY',
          statusCode: node.statusCode,
        );
      }
      throw ProviderException(
        'llmman 拒绝了 API Key (HTTP ${node.statusCode})',
        hint: '确认 Key 与守护进程的 LLMMAN_API_KEYS 一致',
        statusCode: node.statusCode,
      );
    }
    if (node.statusCode == 429) {
      throw ProviderException('llmman 正忙 (HTTP 429)', hint: '稍后再试', statusCode: 429);
    }
    if (node.statusCode >= 500) {
      throw ProviderException('llmman 服务错误 HTTP ${node.statusCode}', statusCode: node.statusCode);
    }
    if (!node.ok) {
      throw ProviderException(
        '$base 不是 llmman 守护进程 (HTTP ${node.statusCode})',
        hint: '确认地址指向 llmman serve',
        statusCode: node.statusCode,
      );
    }

    final json = asMap(node.json);
    final memory = _llmmanBytes(json?['memory']);
    final loaded = _llmmanModels(json?['loaded']);
    final stored = _llmmanModels(json?['stored']);
    final inUse = _llmmanSum(loaded);
    final storedBytes = _llmmanSum(stored);
    final version = await _llmmanVersion(ctx, base, headers);

    return snapshot(
      account,
      ctx,
      plan: key == null ? '本机守护进程' : 'API Key',
      source: 'local',
      windows: [
        if (memory > 0) quotaWindow('llmman-memory', '模型内存', usedPercent: pct(inUse, memory)),
      ],
      extras: {
        '已加载': '${loaded.length} 个 · ${_llmmanSize(inUse)}',
        '已存储': '${stored.length} 个 · ${_llmmanSize(storedBytes)}',
        if (memory > 0) '内存': '${_llmmanSize(inUse)} / ${_llmmanSize(memory)}',
        '版本': ?version,
        if (loaded.isNotEmpty)
          '加载中的模型': loaded.take(24).map((e) => '${e.key} ${_llmmanSize(e.value)}').join('、'),
      },
    );
  }

  Future<HttpResult> _probe(
    FetchContext ctx,
    String base,
    String path,
    Map<String, String> headers,
  ) async {
    try {
      return await sendRequest(
        ctx,
        displayName,
        Uri.parse('$base$path'),
        headers: headers,
        timeout: const Duration(seconds: 5),
      );
    } on ProviderException {
      throw ProviderException('llmman 无法连接: $base', hint: '运行 llmman serve 启动守护进程，或检查服务地址');
    }
  }

  /// Best effort: the version is display-only and older daemons may not serve it.
  Future<String?> _llmmanVersion(FetchContext ctx, String base, Map<String, String> headers) async {
    try {
      final r = await _probe(ctx, base, '/api/version', headers);
      return r.ok ? asString(asMap(r.json)?['version']) : null;
    } on ProviderException {
      return null;
    }
  }
}

// ----------------------------------------------------------------- Langdock

ProviderException _langdockMalformed() => _malformed('Langdock');

ProviderException _langdockError(String code) => switch (code) {
  'UNAUTHORIZED' => ProviderException(
    'Langdock 登录已失效',
    hint: '在浏览器中重新登录 langdock.com，然后粘贴新的 Cookie',
    statusCode: 401,
  ),
  'FORBIDDEN' => ProviderException(
    'Langdock 拒绝访问个人用量',
    hint: '确认该账号可以查看 Usage 页面',
    statusCode: 403,
  ),
  'TOO_MANY_REQUESTS' => ProviderException('Langdock 用量请求过于频繁', hint: '稍后再试', statusCode: 429),
  'INTERNAL_SERVER_ERROR' || 'TIMEOUT' => ProviderException('Langdock 个人用量暂时不可用', hint: '稍后再试'),
  _ => ProviderException('Langdock 拒绝了用量请求 ($code)'),
};

double _langdockPercent(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  throw _langdockMalformed();
}

DateTime? _langdockReset(Object? v) {
  if (v == null) return null;
  final parsed = v is String ? DateTime.tryParse(v) : null;
  if (parsed == null) throw _langdockMalformed();
  return parsed.toUtc();
}

/// Personal included-usage limits (5-hour session and weekly) from Langdock's internal
/// tRPC endpoint, authenticated with a pasted `auth_token` cookie.
class LangdockProvider extends UsageProvider {
  @override
  String get id => 'langdock';

  @override
  String get displayName => 'Langdock';

  @override
  int get brandColor => 0xFF5A4AE7;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '浏览器登录 app.langdock.com 后，把 Cookie 请求头（需包含 auth_token）粘贴进来，'
      '查询个人包含额度的 5 小时与每周用量百分比。该接口未公开，Langdock 改版后可能失效。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.cookie(
      label: 'app.langdock.com Cookie',
      hint: 'auth_token=...',
      help: '浏览器登录 app.langdock.com → 开发者工具 → 网络 → 任一请求的 Cookie 请求头',
    ),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null ||
        cookieValue(cookieHeaderFor(secret, 'auth_token'), 'auth_token') != null) {
      return null;
    }
    return '无法识别：需要包含 auth_token 的 Cookie';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieHeaderFor(FieldValues.of(this, account).secret, 'auth_token');
    if (cookieValue(cookie, 'auth_token') == null) {
      throw ProviderException('Cookie 中没有 auth_token', hint: '重新复制 app.langdock.com 的 Cookie 请求头');
    }
    final uri = Uri.https('app.langdock.com', '/api/trpc/usageSettings.getPersonalUsage', {
      'batch': '1',
      'input': jsonEncode({
        '0': {
          'json': null,
          'meta': {
            'values': ['undefined'],
            'v': 1,
          },
        },
      }),
    });
    final r = await sendRequest(
      ctx,
      displayName,
      uri,
      headers: {
        'Cookie': cookie,
        'Referer': 'https://app.langdock.com/settings/account/usage',
        'User-Agent': browserUserAgent,
      },
    );
    final code = switch (r.statusCode) {
      401 => 'UNAUTHORIZED',
      403 => 'FORBIDDEN',
      429 => 'TOO_MANY_REQUESTS',
      >= 500 => 'INTERNAL_SERVER_ERROR',
      _ => null,
    };
    if (code != null) throw _langdockError(code);
    if (!r.ok) {
      throw ProviderException('Langdock 用量请求失败 HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    return _snapshot(account, ctx, r.json);
  }

  UsageSnapshot _snapshot(AccountConfig account, FetchContext ctx, Object? json) {
    final list = asList(json);
    if (list == null || list.length != 1) throw _langdockMalformed();
    final envelope = asMap(list.first) ?? (throw _langdockMalformed());
    final error = envelope['error'];
    if (error != null) {
      final code = asString(asMap(asMap(asMap(error)?['json'])?['data'])?['code']);
      throw code == null ? _langdockMalformed() : _langdockError(code);
    }
    final payload =
        asMap(asMap(asMap(envelope['result'])?['data'])?['json']) ?? (throw _langdockMalformed());
    final has = payload['hasIncludedUsageLimits'];
    if (has != null && has is! bool) throw _langdockMalformed();
    final planUsage = payload['planUsage'];
    if (has == false || planUsage == null) {
      return snapshot(account, ctx, source: 'web', extras: {'包含额度': '暂无可用的包含用量限制'});
    }

    final usage = asMap(planUsage) ?? (throw _langdockMalformed());
    final enabled = usage['sessionUsageLimitsEnabled'];
    if (enabled is! bool) throw _langdockMalformed();
    final sessionReset = _langdockReset(usage['sessionResetsAt']);
    final weeklyReset = _langdockReset(usage['weeklyResetsAt']);
    return snapshot(
      account,
      ctx,
      source: 'web',
      windows: [
        if (enabled)
          quotaWindow(
            RateWindow.sessionId,
            '5 小时',
            usedPercent: _langdockPercent(usage['sessionUsagePercent']),
            resetsAt: sessionReset,
            windowMinutes: 300,
          ),
        quotaWindow(
          RateWindow.weeklyId,
          '每周',
          usedPercent: _langdockPercent(usage['weeklyUsagePercent']),
          resetsAt: weeklyReset,
          windowMinutes: 10080,
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------- Zed

ProviderException _zedMalformed() => _malformed('Zed');

double _zedCents(Object? v) {
  if (v is num && v >= 0 && v <= _maxSafeInt) return v / 100;
  throw _zedMalformed();
}

String _zedPlanLabel(String raw) => raw
    .split(RegExp(r'[_\s]+'))
    .where((w) => w.isNotEmpty)
    .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
    .join(' ');

/// Zed token spend and edit-prediction quota from the zed.dev billing page, authenticated
/// with a pasted `zed.session` cookie (the editor's Keychain login is not read).
class ZedProvider extends UsageProvider {
  @override
  String get id => 'zed';

  @override
  String get displayName => 'Zed';

  @override
  int get brandColor => 0xFF084EFF;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '浏览器登录 zed.dev 后，把 cloud.zed.dev 请求的 Cookie 请求头（需包含 zed.session）粘贴进来。'
      '显示编辑预测额度与本计费周期的 Token 花费。只读网页账单，不读取编辑器本机登录。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.cookie(
      label: 'zed.dev Cookie',
      hint: 'zed.session=...',
      help: '浏览器登录 zed.dev → 开发者工具 → 网络 → 请求 cloud.zed.dev 的 Cookie 请求头',
    ),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null ||
        cookieValue(cookieHeaderFor(secret, 'zed.session'), 'zed.session') != null) {
      return null;
    }
    return '无法识别：需要包含 zed.session 的 Cookie';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieHeaderFor(FieldValues.of(this, account).secret, 'zed.session');
    if (cookieValue(cookie, 'zed.session') == null) {
      throw ProviderException('Cookie 中没有 zed.session', hint: '重新复制 zed.dev 的 Cookie 请求头');
    }
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://cloud.zed.dev/frontend/billing/usage'),
      headers: {'Cookie': cookie, 'User-Agent': browserUserAgent},
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ProviderException(
        'Zed 浏览器会话已过期',
        hint: '在浏览器中重新登录 zed.dev，然后粘贴新的 Cookie',
        statusCode: r.statusCode,
      );
    }
    checkStatus(displayName, r, authHint: '在浏览器中重新登录 zed.dev 后复制 Cookie');
    return _snapshot(account, ctx, r.json);
  }

  UsageSnapshot _snapshot(AccountConfig account, FetchContext ctx, Object? json) {
    final root = asMap(json) ?? (throw _zedMalformed());
    final plan = asString(root['plan']) ?? (throw _zedMalformed());
    final usage = asMap(root['current_usage']) ?? (throw _zedMalformed());
    final spend = asMap(usage['token_spend']) ?? (throw _zedMalformed());
    final predictions = asMap(usage['edit_predictions']) ?? (throw _zedMalformed());

    final spent = _zedCents(spend['spend_in_cents']);
    final capRaw = spend['limit_in_cents'];
    final cap = capRaw == null ? null : _zedCents(capRaw);

    if (!predictions.containsKey('limit')) throw _zedMalformed();
    final used = _nonNegInt(displayName, predictions['used']);
    final rawLimit = predictions['limit'];
    final unlimited = rawLimit == null || rawLimit == 'unlimited';
    final limit = unlimited
        ? null
        : _nonNegInt(displayName, asMap(rawLimit)?['limited'] ?? rawLimit);

    return snapshot(
      account,
      ctx,
      plan: _zedPlanLabel(plan),
      source: 'web',
      windows: [
        if (limit != null && limit > 0)
          quotaWindow('zed-predictions', '编辑预测', usedPercent: pct(used, limit)),
      ],
      credits: [spendRow('zed-spend', spent, limit: cap, label: '本周期 Token 花费')],
      extras: {'编辑预测': limit == null ? '不限量' : '${used > limit ? limit : used} / $limit'},
    );
  }
}
