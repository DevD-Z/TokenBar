import '../../models/account.dart';
import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

/// Cookie-session providers: the user pastes a browser `Cookie` header (or
/// a site token copied from it). Nothing is read from browser databases.
abstract class _CookieProvider extends UsageProvider {
  String get cookieLabel;
  String? get cookieHint => null;
  List<String> get cookieEnv => const [];
  List<ProviderField> get extraFields => const [];

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  @override
  List<ProviderField> get fields => [
    ProviderField.cookie(label: cookieLabel, hint: cookieHint, envVars: cookieEnv),
    ...extraFields,
  ];

  String cookieOf(AccountConfig account) =>
      normalizeCookieHeader(FieldValues.of(this, account).secret);
}

double? _numOrNull(Object? v) {
  final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);
  return d != null && d.isFinite ? d : null;
}

double? _finiteNum(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

double? _nonNegative(Object? v) {
  final d = _finiteNum(v);
  return d != null && d >= 0 ? d : null;
}

int _count(Object? v, String field) {
  if (v is int && v >= 0) return v;
  throw ProviderException('返回了无法识别的 $field');
}

HttpResult _checked(String provider, HttpResult r, String hint) {
  if (r.statusCode >= 300 && r.statusCode < 400) {
    throw ProviderException(
      '$provider 登录已失效 (HTTP ${r.statusCode})',
      hint: hint,
      statusCode: r.statusCode,
    );
  }
  return checkStatus(provider, r, authHint: hint);
}

Map<String, Object?> _objectOf(String provider, HttpResult r) =>
    decodeJsonObject(r.body) ?? (throw ProviderException('$provider 返回了无法解析的数据'));

String? _header(Map<String, String> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

Future<T?> _optional<T>(Future<T> Function() load) async {
  try {
    return await load();
  } on ProviderException {
    return null;
  }
}

/// en-US grouping, at most two fraction digits (`2,000.5`).
String _num(num v) {
  final fixed = v.abs().toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  final parts = fixed.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final sign = v < 0 && fixed != '0' ? '-' : '';
  return parts.length > 1 ? '$sign$whole.${parts[1]}' : '$sign$whole';
}

String _usd(double v) => v > 0 && v < 0.01 ? '不足 \$0.01' : moneyText(v, 'USD');

// ----------------------------------------------------------------- Trae CN

class TraeCnProvider extends _CookieProvider {
  @override
  String get id => 'traecn';
  @override
  String get displayName => 'Trae CN';
  @override
  int get brandColor => 0xFF4D7CFE;
  @override
  String get cookieLabel => 'trae.cn Cookie';
  @override
  String get setupHint => '浏览器登录 trae.cn 后，复制 api.trae.cn 请求的 Cookie 请求头粘贴到这里，查询 Credits 用量。';

  static const _hint = '在浏览器重新登录 trae.cn 后，复制新的 Cookie';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final base = {
      'Accept': 'application/json',
      'Cookie': cookieOf(account),
      'Origin': 'https://www.trae.cn',
      'Referer': 'https://www.trae.cn/',
      'User-Agent': browserUserAgent,
    };
    final tokenRes = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://api.trae.cn/cloudide/api/v3/common/GetUserToken'),
      method: 'POST',
      headers: base,
      body: <String, Object>{},
      timeout: const Duration(seconds: 15),
    );
    final token = asString(
      asMap(_objectOf(displayName, _checked(displayName, tokenRes, _hint))['Result'])?['Token'],
    );
    if (token == null) throw ProviderException('Trae CN 用量返回格式已变化', hint: _hint);

    final usageRes = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://api.trae.cn/trae/api/v2/pay/user_current_entitlement_list'),
      method: 'POST',
      headers: {...base, 'Authorization': 'Cloud-IDE-JWT $token'},
      body: {'require_usage': true, 'full_data': true},
      timeout: const Duration(seconds: 15),
    );
    final json = _objectOf(displayName, _checked(displayName, usageRes, _hint));
    if (json['code'] == 1001) {
      throw ProviderException('Trae CN 登录已失效', hint: _hint, statusCode: 401);
    }
    final summary = asMap(json['usage_summary']);
    final total = _nonNegative(summary?['total_amount']);
    final used = _nonNegative(summary?['consumed_amount']);
    if (json['is_credits_billing'] != true || total == null || used == null) {
      throw ProviderException('Trae CN 用量返回格式已变化', hint: '接口可能已变更');
    }
    final pack = (asList(json['user_entitlement_pack_list']) ?? const [])
        .map(asMap)
        .whereType<Map<String, Object?>>()
        .where((p) => p['group_type'] == 0 && (p['status'] == null || p['status'] == 1))
        .firstOrNull;
    final remaining = total - used < 0 ? 0.0 : total - used;
    return snapshot(
      account,
      ctx,
      plan: asString(pack?['display_desc']),
      source: 'web',
      windows: [
        if (total > 0) quotaWindow('traecn-credits', 'Credits 用量', usedPercent: pct(used, total)),
      ],
      extras: {'已用': _num(used), '总量': _num(total), '剩余': _num(remaining)},
    );
  }
}

// --------------------------------------------------------------- WorkBuddy

const _wbPaidCodes = [
  'TCACA_code_002_AkiJS3ZHF5',
  'TCACA_code_005_maRGyrHhw1',
  'TCACA_code_003_FAnt7lcmRT',
  'TCACA_code_023_4xbGhMrE6q',
  'TCACA_code_026_BaESVICNoi',
  'TCACA_code_027_0FCGVA6vSa',
  'TCACA_code_009_0XmEQc2xOf',
  'TCACA_code_038_OhvqZtiPKr',
  'TCACA_code_036_lupO5WgNdG',
];

const _wbFreeCodes = [
  'TCACA_code_001_PqouKr6QWV',
  'TCACA_code_008_cfWoLwvjU4',
  'TCACA_code_035_ArVxJcGDsm',
  'TCACA_code_006_DbXS0lrypC',
  'TCACA_code_039_KRcQj7wUat',
  'TCACA_code_040_mi9rCYg46x',
  'TCACA_code_007_nzdH5h4Nl0',
  'TCACA_code_028_NtpWi0jzXs',
  'TCACA_code_037_WxOD3MpI2o',
  'TCACA_code_029_6wCGEWquYy',
  'TCACA_code_030_BjSt89qTvr',
];

ProviderException _wbBad(String field) => ProviderException('WorkBuddy 账单响应格式无效: $field');

double _wbAmount(Object? v, String field) {
  final text = v is String ? v.trim() : null;
  final n = v is num
      ? (v.isFinite ? v.toDouble() : null)
      : (text != null && RegExp(r'^\d+(\.\d+)?$').hasMatch(text) ? double.tryParse(text) : null);
  if (n == null || n < 0) throw _wbBad(field);
  return n;
}

Map<String, Object?> _wbBillingData(String provider, HttpResult r) {
  if (r.statusCode == 403) {
    throw ProviderException('$provider 拒绝访问账单数据', hint: '确认该账号有权限查看用量', statusCode: 403);
  }
  if (r.statusCode == 429) {
    throw ProviderException('$provider 请求过于频繁', hint: '稍后再试', statusCode: 429);
  }
  if (r.statusCode != 200) {
    throw ProviderException('$provider 账单接口返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
  }
  final root = decodeJsonObject(r.body) ?? (throw _wbBad('expected a JSON object'));
  if (root['code'] != 0) throw ProviderException('$provider 账单接口返回 code ${root['code']}');
  return asMap(root['data']) ?? (throw _wbBad('data'));
}

/// `YYYY-MM-DD HH:mm:ss` in China Standard Time, plus one second (as the dashboard does).
DateTime? _wbCycleEnd(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
      .firstMatch(asString(v) ?? '');
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  return DateTime.utc(
    p[0],
    p[1],
    p[2],
    p[3],
    p[4],
    p[5],
  ).subtract(const Duration(hours: 8)).add(const Duration(seconds: 1));
}

class WorkBuddyProvider extends _CookieProvider {
  @override
  String get id => 'workbuddy';
  @override
  String get displayName => 'WorkBuddy';
  @override
  int get brandColor => 0xFF0DC8A6;
  @override
  String get cookieLabel => 'www.workbuddy.cn Cookie';
  @override
  String get setupHint =>
      '浏览器登录 www.workbuddy.cn 后，复制 plans-usage 页面请求的 Cookie 粘贴到这里；'
      '并填写登录时使用的 Chrome 主版本号（会话与 User-Agent 绑定）。';
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'chromeMajor',
      label: 'Chrome 主版本号',
      kind: FieldKind.text,
      required: false,
      hint: '例如 154',
      help: '与登录该站点的 Chrome 主版本一致；留空则不发送 User-Agent，会话可能被判为过期。',
    ),
  ];

  static const _origin = 'https://www.workbuddy.cn';
  static const _hint = '在 www.workbuddy.cn 重新登录后粘贴新的 Cookie';

  static String _agent(int major) =>
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final major = int.tryParse((FieldValues.of(this, account)['chromeMajor'] ?? '').trim());
    final List<String?> agents = major != null && major > 1
        ? [_agent(major), _agent(major - 1)]
        : [null];

    Future<HttpResult> post(String path, Object body, {String? agent, required Duration timeout}) =>
        sendRequest(
          ctx,
          displayName,
          Uri.parse('$_origin$path'),
          method: 'POST',
          timeout: timeout,
          headers: {
            'Accept': 'application/json',
            'Cookie': cookie,
            'Origin': _origin,
            'Referer': '$_origin/profile/plans-usage',
            'User-Agent': ?agent,
          },
          body: body,
        );

    Map<String, Object?>? summary;
    String? agent;
    for (final candidate in agents) {
      final r = await post(
        '/billing/meter/get-user-resource-summary',
        <String, Object>{},
        agent: candidate,
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 401) continue;
      summary = _wbBillingData(displayName, r);
      agent = candidate;
      break;
    }
    if (summary == null) throw ProviderException('WorkBuddy 登录已过期', hint: _hint, statusCode: 401);

    final packages = asList(summary['Packages']) ?? (throw _wbBad('Packages'));
    var total = 0.0;
    var remaining = 0.0;
    var frozen = 0.0;
    for (final raw in packages) {
      final item = asMap(raw) ?? (throw _wbBad('package'));
      if (item['CapacityUnit'] != 'credits') continue;
      total += _wbAmount(item['CycleTotalCapacity'], 'CycleTotalCapacity');
      remaining += _wbAmount(item['CycleRemainCapacity'], 'CycleRemainCapacity');
      if (item.containsKey('CycleFrozenCapacity')) {
        frozen += _wbAmount(item['CycleFrozenCapacity'], 'CycleFrozenCapacity');
      }
    }

    final now = ctx.now();
    final clock = Stopwatch()..start();
    DateTime? reset;
    for (final (path, codes) in [
      ('/billing/meter/get-user-resource-paid-packages', _wbPaidCodes),
      ('/billing/meter/get-user-resource-free-packages', _wbFreeCodes),
    ]) {
      final left = 5000 - clock.elapsedMilliseconds;
      if (left < 1000) break;
      final page = await _optional(
        () async => _wbBillingData(
          displayName,
          await post(
            path,
            {
              'PageNumber': 1,
              'PageSize': 100,
              'PackageCodes': codes,
              'Status': [0, 3],
            },
            agent: agent,
            timeout: Duration(milliseconds: left),
          ),
        ),
      );
      for (final a
          in (asList(page?['Accounts']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
        if (a['CapacityUnit'] != 'credits') continue;
        final end = _wbCycleEnd(a['CycleEndTime']);
        if (end != null && end.isAfter(now) && (reset == null || end.isBefore(reset))) reset = end;
      }
    }

    final extras = total > 0
        ? <String, String>{'剩余': '${_num(remaining)} / ${_num(total)} credits'}
        : <String, String>{'剩余': _num(remaining), '总量': _num(total)};
    if (frozen > 0) extras['冻结'] = _num(frozen);
    return snapshot(
      account,
      ctx,
      plan: asString(summary['SubscriptionPackageName']),
      source: 'web',
      windows: [
        if (total > 0)
          quotaWindow(
            'workbuddy-credits',
            '积分',
            usedPercent: pct(total - remaining, total),
            resetsAt: reset,
          ),
      ],
      extras: extras,
    );
  }
}

// ------------------------------------------------------------------ LongCat

ProviderException _longCatBad(String detail) => ProviderException('LongCat 响应格式无效: $detail');

Map<String, Object?> _longCatPayload(String body) {
  final envelope = decodeJsonObject(body) ?? (throw _longCatBad('not a JSON object'));
  if (envelope.containsKey('code')) {
    final raw = _numOrNull(envelope['code']);
    if (raw == null || raw >= 9.223372036854776e18 || raw < -9.223372036854776e18) {
      throw _longCatBad('response code was not a valid integer');
    }
    final code = raw.truncate();
    if (code == 401 || code == 403) {
      throw ProviderException(
        'LongCat 登录已失效',
        hint: '在 longcat.chat 重新登录后，复制新的 Cookie',
        statusCode: code,
      );
    }
    if (code != 0 && code != 200) {
      throw ProviderException(
        'LongCat 返回错误: ${asString(envelope['message']) ?? asString(envelope['msg']) ?? 'code $code'}',
      );
    }
  }
  return asMap(envelope.containsKey('data') ? envelope['data'] : envelope) ??
      (throw _longCatBad('data was not an object'));
}

class LongCatProvider extends _CookieProvider {
  @override
  String get id => 'longcat';
  @override
  String get displayName => 'LongCat';
  @override
  int get brandColor => 0xFF29E154;
  @override
  String get cookieLabel => 'longcat.chat Cookie';
  @override
  List<String> get cookieEnv => const ['LONGCAT_MANUAL_COOKIE'];
  @override
  String get setupHint => '浏览器登录 longcat.chat 后，复制任一请求的 Cookie 请求头粘贴到这里，查询 Token 额度与加油包。';

  static const _hint = '在 longcat.chat 重新登录后，复制新的 Cookie';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final headers = {
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Cookie': cookieOf(account),
      'Origin': 'https://longcat.chat',
      'Referer': 'https://longcat.chat/platform/usage',
      'User-Agent': browserUserAgent,
    };
    Future<Map<String, Object?>> call(String path, {bool post = false}) async {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://longcat.chat$path'),
        method: post ? 'POST' : 'GET',
        headers: headers,
        body: post ? <String, Object>{} : null,
      );
      if (r.statusCode == 401 ||
          r.statusCode == 403 ||
          (r.statusCode >= 300 && r.statusCode < 400)) {
        throw ProviderException('LongCat 登录已失效', hint: _hint, statusCode: r.statusCode);
      }
      if (r.statusCode != 200) {
        throw ProviderException('LongCat HTTP ${r.statusCode} for $path', statusCode: r.statusCode);
      }
      return _longCatPayload(r.body);
    }

    final me = await call('/api/v1/user-current');
    final summary = await _optional(
      () => call('/api/pay/quota/metering/token-packs/summary', post: true),
    );
    final lot = asMap(summary?['currentLot']);
    final lotTotal = _numOrNull(lot?['totalToken']);
    final double total;
    final double used;
    if (asString(lot?['status'])?.toUpperCase() == 'ACTIVE' && lotTotal != null && lotTotal > 0) {
      total = lotTotal;
      used = _numOrNull(lot?['consumedToken']) ?? 0.0;
    } else {
      final payload = await call('/api/lc-platform/v1/tokenUsage');
      final usage = asMap(payload['usage']) ?? payload;
      total =
          _numOrNull(usage['totalToken']) ??
          (throw _longCatBad('tokenUsage was missing totalToken'));
      used =
          _numOrNull(usage['usedToken']) ?? total - (_numOrNull(usage['availableToken']) ?? total);
    }

    final fuel = await _optional(() => call('/api/lc-platform/v1/pending-fuel-packages'));
    final fuelTotal = _numOrNull(fuel?['totalQuota']);
    var remaining = 0.0;
    var sawRemaining = false;
    DateTime? reset;
    for (final pack
        in (asList(fuel?['list']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
      final available = _numOrNull(pack['availableToken']);
      if (available != null) {
        remaining += available;
        sawRemaining = true;
      }
      final expiry = parseFlexibleDate(pack['expireTime']);
      if (expiry != null && (reset == null || expiry.isBefore(reset))) reset = expiry;
    }
    if (!sawRemaining) remaining = fuelTotal ?? 0.0;

    final name = asString(me['name']) ?? asString(me['nickName']);
    final fuelUsed = (fuelTotal ?? 0) - remaining;
    return snapshot(
      account,
      ctx,
      source: 'web',
      windows: [
        if (total > 0)
          quotaWindow('longcat-quota', '额度', usedPercent: pct(used < 0 ? 0 : used, total)),
        if (fuelTotal != null && fuelTotal > 0)
          quotaWindow(
            'longcat-fuel',
            '加油包',
            usedPercent: pct(fuelUsed < 0 ? 0 : fuelUsed, fuelTotal),
            resetsAt: reset,
          ),
      ],
      extras: {
        '账户': ?name,
        if (total > 0) '额度用量': '${used.truncate()}/${total.truncate()}',
        if (fuelTotal != null && fuelTotal > 0)
          '加油包余量': '${remaining.truncate()}/${fuelTotal.truncate()}',
      },
    );
  }
}

// ----------------------------------------------------------------- Helmcode

ProviderException _helmBad(String field) => ProviderException('Helmcode 配额返回格式已变化: $field');

class _HelmModel {
  _HelmModel(this.name, this.cap, this.used, this.credit, this.hours, this.resetsAt);

  final String name;
  final int cap;
  final int used;
  final int credit;
  final int? hours;
  final DateTime? resetsAt;
}

class HelmcodeProvider extends _CookieProvider {
  @override
  String get id => 'helmcode';
  @override
  String get displayName => 'Helmcode';
  @override
  int get brandColor => 0xFF4934E1;
  @override
  String get cookieLabel => 'Helmcode Cookie';
  @override
  String? get cookieHint => '__Host-session=...';
  @override
  String get setupHint =>
      '浏览器登录 cloud.helmcode.com（或 cloud.nan.builders）后，复制 Cookie 请求头粘贴到这里，并选择对应租户。';
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'tenant',
      label: '租户',
      kind: FieldKind.choice,
      defaultValue: 'helmcode',
      choices: [
        FieldChoice('helmcode', 'Helmcode Cloud (helmcode.com)'),
        FieldChoice('nanBuilders', 'NaN Builders (nan.builders)'),
      ],
    ),
  ];

  static const _hint = '在 cloud 控制台重新登录后，复制新的 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final text = values[ProviderField.secretKey]?.trimLeft().toLowerCase() ?? '';
    return text.startsWith('curl ') ? '不支持 cURL 命令，请粘贴 Cookie 请求头' : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    const cloud = (domain: 'helmcode.com', name: 'Helmcode Cloud');
    const nan = (domain: 'nan.builders', name: 'NaN Builders');
    final tenant = FieldValues.of(this, account)['tenant'] == 'nanBuilders' ? nan : cloud;
    final base = 'https://cloud-api.${tenant.domain}';
    final headers = {
      'Accept': 'application/json',
      'Cookie': cookieOf(account),
      'Origin': 'https://cloud.${tenant.domain}',
      'Referer': 'https://cloud.${tenant.domain}/dashboard',
      'User-Agent': browserUserAgent,
    };
    Future<HttpResult> get(String path, int seconds) => sendRequest(
      ctx,
      displayName,
      Uri.parse('$base$path'),
      headers: headers,
      timeout: Duration(seconds: seconds),
    );

    final quota = _objectOf(
      displayName,
      _checked(displayName, await get('/api/usage/quota', 8), _hint),
    );
    final periodStart = asString(quota['periodStart']);
    final models = asList(quota['models']);
    if (periodStart == null || models == null) throw _helmBad('periodStart or models');

    final billing = await _optional(
      () async =>
          _objectOf(displayName, _checked(displayName, await get('/api/billing', 2), _hint)),
    );
    final premium = asMap(billing?['subscription'])?['premium'] == true;

    final start = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(periodStart);
    final startMonth = start == null ? 0 : int.parse(start[2]!);
    final fallback = start == null || startMonth < 1 || startMonth > 12
        ? null
        : DateTime.utc(int.parse(start[1]!), startMonth + 1);

    final rows = <_HelmModel>[];
    for (final raw in models) {
      final row = asMap(raw) ?? (throw _helmBad('model'));
      final name = row['model'];
      if (name is! String ||
          name.isEmpty ||
          name.length > 80 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
        throw _helmBad('model name');
      }
      final cap = _count(row['cap'], 'cap');
      final used = _count(row['tokensUsed'], 'tokensUsed');
      final credit = row['creditTokens'] == null ? 0 : _count(row['creditTokens'], 'creditTokens');
      final hours = row['windowHours'] == null ? null : _count(row['windowHours'], 'windowHours');
      if (hours != null && (hours < 1 || hours > 8760)) throw _helmBad('windowHours');
      final periodEnd = row['periodEnd'];
      final resetsAt = periodEnd is String
          ? (DateTime.tryParse(periodEnd)?.toUtc() ?? fallback)
          : fallback;
      if (cap > 0 && (hours == null || premium)) {
        rows.add(_HelmModel(name, cap, used, credit, hours, resetsAt));
      }
    }
    rows.sort((a, b) {
      final byRatio = (b.used / b.cap).compareTo(a.used / a.cap);
      return byRatio != 0 ? byRatio : a.name.compareTo(b.name);
    });

    final windows = [
      for (final m in rows)
        quotaWindow(
          'helmcode-${m.name}',
          m.name,
          usedPercent: pct(m.used, m.cap),
          resetsAt: m.resetsAt,
          windowMinutes: m.hours == null ? null : m.hours! * 60,
        ),
    ];
    final extras = <String, String>{'组织': tenant.name};
    for (final m in rows) {
      extras['${m.name} 用量'] =
          '${_num(m.used)} / ${_num(m.cap)} tokens${m.credit > 0 ? ' · ${_num(m.credit)} credit-funded' : ''}';
    }

    Credits? prepaid;
    if (tenant.domain == 'helmcode.com') {
      final credits = await _optional(
        () async => _objectOf(
          displayName,
          _checked(displayName, await get('/api/billing/credits', 2), _hint),
        ),
      );
      final micros = credits?['balanceMicros'];
      final cur = credits?['currency'];
      final currency = cur == null ? 'EUR' : (cur is String ? cur.toUpperCase() : '');
      if (micros is int && RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
        prepaid = balanceRow(
          'helmcode-prepaid',
          micros < 0 ? 0.0 : micros / 1e6,
          label: '预付余额',
          currency: currency,
        );
      }
    }

    return snapshot(
      account,
      ctx,
      source: 'web',
      windows: windows,
      credits: [?prepaid],
      extras: extras,
    );
  }
}

// ---------------------------------------------------------------------- X API

ProviderException _xBad() => ProviderException('X API 返回了无法识别的账户或余额');

class XApiProvider extends _CookieProvider {
  @override
  String get id => 'xapi';
  @override
  String get displayName => 'X API';
  @override
  int get brandColor => 0xFF71767B;
  @override
  String get cookieLabel => 'console.x.com Cookie';
  @override
  String? get cookieHint => 'auth_token=...; ct0=...';
  @override
  String get setupHint =>
      '浏览器登录 console.x.com 后，复制请求的 Cookie 请求头粘贴到这里（需包含 auth_token 与 ct0），查询 Credits 余额。';

  static const _hint = '重新登录 console.x.com 后粘贴新的 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null) return null;
    final cookie = normalizeCookieHeader(secret);
    return cookieValue(cookie, 'auth_token') == null || cookieValue(cookie, 'ct0') == null
        ? '需要同时包含 auth_token 与 ct0 的 Cookie'
        : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final ct0 = cookieValue(cookie, 'ct0');
    if (ct0 == null) throw ProviderException('X API 的 Cookie 缺少 ct0', hint: _hint);
    final headers = {
      'Accept': 'application/json',
      'Cookie': cookie,
      'X-CSRF-Token': ct0,
      'User-Agent': browserUserAgent,
    };

    Future<Map<String, Object?>> get(String path) async {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://console.x.com$path'),
        headers: headers,
      );
      final json = decodeJsonObject(r.body);
      final legacyExpired =
          r.statusCode == 400 &&
          (asList(json?['errors']) ?? const []).map(asMap).any((e) => e?['code'] == 215);
      if (r.statusCode == 401 || legacyExpired) {
        throw ProviderException('X API 登录已过期', hint: _hint, statusCode: 401);
      }
      if (r.statusCode == 403) {
        throw ProviderException('X 开发者控制台拒绝访问', hint: '确认该账号有控制台权限', statusCode: 403);
      }
      if (r.statusCode == 429) {
        throw ProviderException('X API 控制台请求过于频繁', hint: '稍后再试', statusCode: 429);
      }
      if (r.statusCode >= 500) {
        throw ProviderException('X 开发者控制台暂不可用 (HTTP ${r.statusCode})', statusCode: r.statusCode);
      }
      if (r.statusCode != 200) {
        throw ProviderException('X 开发者控制台返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
      }
      return json ?? (throw _xBad());
    }

    final me = await get('/api/me');
    final rawId = asMap(me['account'])?['id'];
    final String accountId;
    if (rawId is int && rawId >= 0) {
      accountId = '$rawId';
    } else if (rawId is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(rawId)) {
      accountId = rawId;
    } else {
      throw _xBad();
    }
    final credits = await get('/api/accounts/$accountId/credits');
    final paid = _finiteNum(asMap(credits['credits'])?['balance']) ?? (throw _xBad());
    final free = credits.containsKey('freeCredits')
        ? (_finiteNum(asMap(credits['freeCredits'])?['balance']) ?? (throw _xBad()))
        : 0.0;
    final balance = paid + free;
    return snapshot(
      account,
      ctx,
      source: 'web',
      credits: [balanceRow('xapi-balance', balance, label: '余额', currency: 'USD')],
      extras: {'购买余额': moneyText(paid, 'USD'), '免费余额': moneyText(free, 'USD')},
    );
  }
}

// ------------------------------------------------------------------ LithosAI

ProviderException _lithBad(String field) => ProviderException('LithosAI 返回了无法解析的 $field');

Map<String, String> _lithSpend(Map<String, Object?> report, String start, String end) {
  final days = asList(report['days']);
  if (report['start'] != start || report['end'] != end || days == null) {
    throw _lithBad('spend range');
  }
  var today = 0;
  var month = 0;
  for (final raw in days) {
    final day = asMap(raw) ?? (throw _lithBad('spend day'));
    final date = day['day'];
    if (date is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        date.compareTo(start) < 0 ||
        date.compareTo(end) > 0) {
      throw _lithBad('spend day');
    }
    final nanos = day['nanos'];
    if (nanos is! int || nanos < 0) throw _lithBad('spend amount');
    month += nanos;
    if (date == end) today += nanos;
  }
  return {'今日 (UTC)': _usd(today / 1e9), '本月 (UTC)': _usd(month / 1e9)};
}

class LithosAiProvider extends _CookieProvider {
  @override
  String get id => 'lithosai';
  @override
  String get displayName => 'LithosAI';
  @override
  int get brandColor => 0xFF6B7280;
  @override
  String get cookieLabel => 'console.lithosai.cloud Cookie';
  @override
  String? get cookieHint => '__Host-console_session=...; __Host-console_csrf=...';
  @override
  String get setupHint =>
      '浏览器登录 console.lithosai.cloud 后，复制请求的 Cookie（需包含 __Host-console_session 与 __Host-console_csrf）粘贴到这里。';

  static const _session = '__Host-console_session';
  static const _csrf = '__Host-console_csrf';
  static const _hint = '重新登录 console.lithosai.cloud 后粘贴新的 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null) return null;
    final cookie = normalizeCookieHeader(secret);
    return cookieValue(cookie, _session) == null || cookieValue(cookie, _csrf) == null
        ? '需要同时包含 $_session 与 $_csrf 的 Cookie'
        : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final csrf = cookieValue(cookie, _csrf);
    if (csrf == null || cookieValue(cookie, _session) == null) {
      throw ProviderException('LithosAI 的 Cookie 缺少 $_session 或 $_csrf', hint: _hint);
    }
    final headers = {
      'Accept': 'application/json',
      'Cookie': cookie,
      'X-Console-Csrf': csrf,
      'User-Agent': browserUserAgent,
    };

    Future<Map<String, Object?>> get(String path, {String? org}) async {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://console.lithosai.cloud$path'),
        headers: {...headers, 'X-Organization-Id': ?org},
      );
      if (r.statusCode == 401) {
        throw ProviderException('LithosAI 登录已过期', hint: _hint, statusCode: 401);
      }
      if (r.statusCode == 403) {
        throw ProviderException('LithosAI 控制台拒绝访问', hint: '确认该账号有控制台权限', statusCode: 403);
      }
      if (r.statusCode == 429) {
        throw ProviderException('LithosAI 控制台请求过于频繁', hint: '稍后再试', statusCode: 429);
      }
      if (r.statusCode >= 500) {
        throw ProviderException(
          'LithosAI 控制台暂不可用 (HTTP ${r.statusCode})',
          statusCode: r.statusCode,
        );
      }
      if (r.statusCode != 200) {
        throw ProviderException('LithosAI 控制台返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
      }
      return decodeJsonObject(r.body) ?? (throw _lithBad('JSON response'));
    }

    final me = await get('/api/me');
    final org = asMap(me['activeOrganization']) ?? (throw _lithBad('activeOrganization'));
    final orgId = asString(org['id']);
    if (orgId == null || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(orgId)) {
      throw _lithBad('organization ID');
    }

    final billing = await get('/api/billing', org: orgId);
    final nanos = billing['balanceNanos'];
    if (nanos is! int || nanos.abs() > 9007199254740991) throw _lithBad('balanceNanos');
    final hasCard = billing['hasCard'];
    if (hasCard is! bool) throw _lithBad('hasCard');
    final onHold = billing['onHold'];
    if (onHold is! bool) throw _lithBad('onHold');
    final balance = nanos / 1e9;

    final today = ctx.now().toUtc().toIso8601String().substring(0, 10);
    final start = '${today.substring(0, 7)}-01';
    var spend = <String, String>{'花费': '不可用'};
    try {
      spend = _lithSpend(
        await get('/api/billing/spend?start=$start&end=$today', org: orgId),
        start,
        today,
      );
    } on ProviderException catch (e) {
      if (e.statusCode == 401) rethrow;
    }

    final name = asString(org['name']);
    return snapshot(
      account,
      ctx,
      email: asString(asMap(me['user'])?['email']),
      source: 'web',
      credits: [balanceRow('lithosai-balance', balance, label: '余额', currency: 'USD')],
      extras: {
        '组织': ?name,
        '支付卡': hasCard ? '已添加' : '未添加',
        '账户状态': onHold ? '已冻结' : '正常',
        ...spend,
      },
    );
  }
}

// ------------------------------------------------------------------- TinyApi

class TinyApiProvider extends _CookieProvider {
  @override
  String get id => 'tinyapi';
  @override
  String get displayName => 'TinyApi';
  @override
  int get brandColor => 0xFFF97316;
  @override
  String get cookieLabel => 'tinyapi.rest Cookie';
  @override
  String? get cookieHint => '__Secure-authjs.session-token=...';
  @override
  String get setupHint =>
      '浏览器登录 tinyapi.rest 后，复制请求的 Cookie 请求头粘贴到这里（需包含 __Secure-authjs.session-token），查询可用 credits。';

  static const _hint = '重新登录 tinyapi.rest 或粘贴新的 Cookie';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    return secret == null || secret.contains('authjs.session-token')
        ? null
        : '需要包含 __Secure-authjs.session-token 的 Cookie';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://tinyapi.rest/api/user/credits'),
      headers: {
        'Accept': 'application/json',
        'Cookie': cookieOf(account),
        'User-Agent': browserUserAgent,
      },
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ProviderException('TinyApi 登录已过期', hint: _hint, statusCode: r.statusCode);
    }
    if (r.statusCode == 429) {
      throw ProviderException('TinyApi credits 请求被限流', hint: '稍后再试', statusCode: 429);
    }
    if (r.statusCode >= 500) {
      throw ProviderException(
        'TinyApi credits 服务返回 HTTP ${r.statusCode}',
        statusCode: r.statusCode,
      );
    }
    if (r.statusCode != 200) {
      throw ProviderException(
        'TinyApi credits 请求返回 HTTP ${r.statusCode}',
        statusCode: r.statusCode,
      );
    }
    final json = decodeJsonObject(r.body);
    final available = _nonNegative(asMap(json?['data'])?['totalAvailable']);
    if (json?['success'] != true || available == null) {
      throw ProviderException('TinyApi credits 返回了无法识别的余额');
    }
    return snapshot(
      account,
      ctx,
      source: 'web',
      credits: [balanceRow('tinyapi-credits', available, label: '可用 Credits', currency: null)],
    );
  }
}

// ------------------------------------------------------------------ Parallel

class ParallelProvider extends _CookieProvider {
  @override
  String get id => 'parallel';
  @override
  String get displayName => 'Parallel';
  @override
  int get brandColor => 0xFF1D1C1A;
  @override
  String get cookieLabel => 'platform.parallel.ai Cookie';
  @override
  String get setupHint => '浏览器登录 platform.parallel.ai 后，复制请求的 Cookie 请求头粘贴到这里（API Key 无法查询余额）。';

  static const _hint = '重新登录 platform.parallel.ai 后粘贴新的 Cookie';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://platform.parallel.ai/api/rpc/billing/payments/refresh-balance'),
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'Cookie': cookieOf(account),
        'Origin': 'https://platform.parallel.ai',
        'User-Agent': browserUserAgent,
      },
      body: <String, Object>{},
      timeout: const Duration(seconds: 20),
    );
    final contentType = (_header(r.headers, 'content-type') ?? '').toLowerCase();
    final signedOut =
        r.statusCode == 401 ||
        r.statusCode == 403 ||
        (r.statusCode >= 300 && r.statusCode < 400) ||
        (r.statusCode == 200 && contentType.contains('text/html'));
    if (signedOut) throw ProviderException('Parallel 登录已过期', hint: _hint, statusCode: r.statusCode);
    final ok = checkStatus(displayName, r);
    final json = decodeJsonObject(ok.body);
    final data = json?['kind'] == 'ok' ? asMap(json?['data']) : null;
    final balance = _finiteNum(data?['balance']);
    if (balance == null) throw ProviderException('Parallel 账单响应格式已变化', hint: '该接口为非公开接口，可能已变更');
    final pending = _finiteNum(data?['pendingDebitBalanceCents']);
    return snapshot(
      account,
      ctx,
      source: 'web',
      credits: [balanceRow('parallel-balance', balance / 100, label: '余额', currency: 'USD')],
      extras: {if (pending != null && pending != 0) '待扣款': moneyText(pending / 100, 'USD')},
    );
  }
}

// -------------------------------------------------------------------- Muse

ProviderException _museDiscoveryFailure() =>
    ProviderException('无法找到可用的 muse.ai 订阅接口', hint: 'muse.ai 可能已更新，刷新重试');

ProviderException _museExpired() =>
    ProviderException('muse.ai 登录已过期', hint: '在 muse.ai 重新登录后刷新 Cookie', statusCode: 401);

bool _museSignedOut(HttpResult r) =>
    r.statusCode == 401 ||
    r.statusCode == 403 ||
    (_header(r.headers, 'location') ?? '').startsWith('https://auth.muse.ai/');

bool _museStale(HttpResult r) =>
    r.statusCode == 404 &&
    RegExp(r'server action not found', caseSensitive: false).hasMatch(r.body);

Future<HttpResult> _postMuseAction(FetchContext ctx, String cookie, String actionId) => sendRequest(
  ctx,
  'muse.ai',
  Uri.parse('https://muse.ai/'),
  method: 'POST',
  headers: {
    'Accept': 'text/x-component',
    'Cookie': cookie,
    'Next-Action': actionId,
    'Origin': 'https://muse.ai',
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Dest': 'empty',
    'User-Agent': browserUserAgent,
  },
  body: [
    {'includeAgreement': true},
  ],
);

List<String> _museChunkPaths(String text) =>
    {for (final m in RegExp(r'static/chunks/[\w~.-]+\.js').allMatches(text)) '/_next/${m.group(0)}'}
        .toList();

Future<List<String>> _fetchMuseChunks(FetchContext ctx, List<String> paths) => Future.wait(
  paths.map((path) async {
    try {
      final r = await sendRequest(
        ctx,
        'muse.ai',
        Uri.parse('https://muse.ai$path'),
        headers: {'Accept': '*/*', 'User-Agent': browserUserAgent},
      );
      return r.statusCode == 200 ? r.body : '';
    } on ProviderException {
      return '';
    }
  }),
);

/// The server action ID changes on every muse.ai deploy. It is found in the
/// public chunks: the app chunk preloads a settings module whose loader lists
/// the chunk that names `fetchSubscriptionAction`. No cookies are sent to chunks.
Future<String> _discoverMuseAction(FetchContext ctx, String cookie) async {
  final page = await sendRequest(
    ctx,
    'muse.ai',
    Uri.parse('https://muse.ai/'),
    headers: {'Accept': 'text/html', 'Cookie': cookie, 'User-Agent': browserUserAgent},
  );
  if (_museSignedOut(page)) throw _museExpired();
  if (page.statusCode != 200) {
    throw ProviderException('muse.ai 返回 HTTP ${page.statusCode}', statusCode: page.statusCode);
  }
  final paths = _museChunkPaths(page.body).take(96).toList();
  var text = '';
  for (var i = 0; i < paths.length; i += 8) {
    final end = i + 8 < paths.length ? i + 8 : paths.length;
    text += '\n${(await _fetchMuseChunks(ctx, paths.sublist(i, end))).join('\n')}';
    if (text.length > 8 * 1024 * 1024) throw _museDiscoveryFailure();
    final module = RegExp(r'\.A\((\d+)\)\.then\(\(\{[^}]*Settings').firstMatch(text)?.group(1);
    if (module == null) continue;
    final loader = RegExp(r'[,{\[]' + module + r',\w+=>\{\w+\.v\(\w+=>Promise\.all\(\[([^\]]*)')
        .firstMatch(text)
        ?.group(1);
    if (loader == null) continue;
    final settings = _museChunkPaths(loader).take(32).toList();
    for (var j = 0; j < settings.length; j += 8) {
      final last = j + 8 < settings.length ? j + 8 : settings.length;
      for (final body in await _fetchMuseChunks(ctx, settings.sublist(j, last))) {
        final id = RegExp(r'"([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction"')
            .firstMatch(body)
            ?.group(1);
        if (id != null) return id;
      }
    }
    break;
  }
  throw _museDiscoveryFailure();
}

String? _tokensLeft(String? label) =>
    RegExp(r'\(([^()]+ tokens left)\)').firstMatch(label ?? '')?.group(1);

/// React Flight rows look like `1:{...}`; the subscription is the row with `success`.
Map<String, Object?> _parseMuseSubscription(String body) {
  Map<String, Object?>? sub;
  for (final line in body.split('\n')) {
    final payload = RegExp(r'^[0-9a-f]+:(\{.*\})\s*$').firstMatch(line)?.group(1);
    final row = payload == null ? null : decodeJsonObject(payload);
    if (row?['success'] == true) sub = asMap(row?['subscription']);
  }
  final usage = asMap(sub?['usage']);
  if (sub == null || usage == null || usage['percentUsed'] is! num) {
    throw ProviderException('muse.ai 返回了无法识别的订阅数据', hint: '页面结构可能已变化，刷新重试');
  }
  return sub;
}

class MuseAiProvider extends _CookieProvider {
  String? _actionId;

  @override
  String get id => 'museai';
  @override
  String get displayName => 'Muse (muse.ai)';
  @override
  int get brandColor => 0xFF0668E1;
  @override
  String get cookieLabel => 'muse.ai Cookie';
  @override
  String get setupHint => '浏览器登录 muse.ai 后，复制请求的 Cookie 请求头粘贴到这里，查询每周用量与加油包。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final cookie = cookieOf(account);
    final cached = _actionId;
    var response = cached == null ? null : await _postMuseAction(ctx, cookie, cached);
    var actionId = cached;
    if (response == null || _museStale(response)) {
      actionId = await _discoverMuseAction(ctx, cookie);
      response = await _postMuseAction(ctx, cookie, actionId);
      if (_museStale(response)) throw _museDiscoveryFailure();
    }
    if (_museSignedOut(response)) {
      throw ProviderException(
        'muse.ai 登录已过期',
        hint: '在 muse.ai 重新登录后刷新 Cookie',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw ProviderException(
        'muse.ai 接口返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    _actionId = actionId;

    final sub = _parseMuseSubscription(response.body);
    final usage = asMap(sub['usage']) ?? const {};
    final percent = (_finiteNum(usage['percentUsed']) ?? 0).clamp(0, 100).toDouble();
    final topupBalance = _finiteNum(sub['topupBalance']);
    final topupTotal = _finiteNum(sub['topupTotal']);
    final extras = <String, String>{};
    final tokensLeft = _tokensLeft(asString(sub['usageRowValueLabel']));
    if (tokensLeft != null) extras['剩余 Token'] = tokensLeft;
    if (topupBalance != null && topupTotal != null && topupTotal > 0) {
      extras[asString(sub['topupRowLabel']) ?? 'Additional tokens'] =
          _tokensLeft(asString(sub['topupRowValueLabel'])) ??
          asString(sub['topupRowValueLabel']) ??
          '${moneyText(topupBalance / 1e6, 'USD')} left';
    }
    final renews = epochSeconds(asInt(asMap(sub['agreement'])?['currentPeriodEndTime']));
    if (renews != null) extras['续费日期'] = renews.toIso8601String().substring(0, 10);

    return snapshot(
      account,
      ctx,
      plan: asString(asMap(sub['tier'])?['name']) ?? asString(sub['usageRowLabel']),
      source: 'web',
      windows: [
        quotaWindow(
          RateWindow.weeklyId,
          '每周',
          usedPercent: percent,
          resetsAt: epochSeconds(asInt(usage['resetsAt'])),
          windowMinutes: 10080,
        ),
      ],
      extras: extras,
    );
  }
}

// ----------------------------------------------------------------- StepFun

const _stepfunDefaultWebId = 'c8a1002d2c457e758785a9979832217c7c0b884c';
const _stepfunBase = 'https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard';

/// Accepts a bare Oasis-Token or a cookie header containing `Oasis-Token=`.
String _stepfunToken(String raw) {
  final text = raw.trim();
  final at = text.indexOf('Oasis-Token=');
  return at < 0 ? text : text.substring(at + 'Oasis-Token='.length).split(';').first.trim();
}

/// The device id lives in the JWT payload of the refresh half (or the access half).
String _stepfunWebId(String token) {
  for (final half in token.split('...').reversed) {
    final id = asString(decodeJwtPayload(half)?['device_id']);
    if (id != null) return id;
  }
  return _stepfunDefaultWebId;
}

double _stepfunFlex(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) ?? 0 : 0);

double? _stepfunCreditFraction(List<Object?> buckets, double? single) {
  if (buckets.isNotEmpty) {
    var total = 0.0;
    var residual = 0.0;
    var usable = true;
    for (final raw in buckets) {
      final bucket = asMap(raw);
      final t = _numOrNull(bucket?['credit_total']);
      final r = _numOrNull(bucket?['credit_residual']);
      if (t == null || r == null || t <= 0 || r < 0 || r > t) {
        usable = false;
        break;
      }
      total += t;
      residual += r;
    }
    if (usable) return residual / total;
  }
  return single;
}

DateTime? _stepfunReset(Object? v) {
  final seconds = _stepfunFlex(v);
  return seconds > 0 ? epochSeconds(seconds.toInt()) : null;
}

double _leftToUsed(double left) => ((1 - left) * 100).clamp(0, 100).toDouble();

class StepFunProvider extends _CookieProvider {
  @override
  String get id => 'stepfun';
  @override
  String get displayName => 'StepFun';
  @override
  int get brandColor => 0xFF2196F3;
  @override
  String get cookieLabel => 'platform.stepfun.com Oasis-Token';
  @override
  String? get cookieHint => 'Oasis-Token=...';
  @override
  List<String> get cookieEnv => const ['STEPFUN_TOKEN'];
  @override
  String get setupHint =>
      '浏览器登录 platform.stepfun.com 后，复制 Cookie 中的 Oasis-Token 粘贴到这里，查询 Step Plan 用量。令牌失效后需重新复制。';

  static const _hint = '在 platform.stepfun.com 重新登录后，复制新的 Oasis-Token';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    return secret == null || _stepfunToken(secret).isNotEmpty ? null : '未找到 Oasis-Token';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final token = _stepfunToken(FieldValues.of(this, account).secret);
    final webId = _stepfunWebId(token);
    final headers = {
      'Accept': 'application/json',
      'oasis-appid': '10300',
      'oasis-platform': 'web',
      'oasis-webid': webId,
      'Cookie': 'Oasis-Token=$token; Oasis-Webid=$webId',
      'User-Agent': browserUserAgent,
    };

    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$_stepfunBase/QueryStepPlanRateLimit'),
      method: 'POST',
      headers: headers,
      body: <String, Object>{},
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ProviderException('StepFun 令牌已失效', hint: _hint, statusCode: r.statusCode);
    }
    if (r.statusCode != 200) {
      throw ProviderException('StepFun 接口错误 HTTP ${r.statusCode}', statusCode: r.statusCode);
    }
    final json = decodeJsonObject(r.body) ?? (throw ProviderException('StepFun 返回了无法解析的数据'));
    if (_stepfunFlex(json['status']) != 1) {
      throw ProviderException(
        'StepFun 返回错误: ${asString(json['message']) ?? asString(json['desc']) ?? json['code'] ?? 'unknown'}',
      );
    }

    final credit = asMap(json['plan_credit_rate_limit']);
    final subscriptionLeft = _numOrNull(credit?['subscription_credit_left_rate']);
    final topupLeft = _numOrNull(credit?['topup_credit_left_rate']);
    final buckets = asList(credit?['credit_buckets']) ?? const [];
    final liveWindow =
        _stepfunFlex(json['five_hour_usage_reset_time']) > 0 ||
        _stepfunFlex(json['weekly_usage_reset_time']) > 0;
    final creditPool = subscriptionLeft != null || topupLeft != null || buckets.isNotEmpty;
    final creditPlan = !liveWindow && (creditPool || _stepfunFlex(json['plan_family']) == 2);
    if (!creditPlan &&
        (json['five_hour_usage_left_rate'] == null ||
            json['weekly_usage_left_rate'] == null ||
            json['five_hour_usage_reset_time'] == null ||
            json['weekly_usage_reset_time'] == null)) {
      throw ProviderException('StepFun 用量字段缺失', hint: '接口格式可能已变化');
    }

    final windows = <RateWindow>[];
    if (creditPlan) {
      final fraction = _stepfunCreditFraction(buckets, subscriptionLeft ?? topupLeft);
      if (fraction != null) {
        final resetAt = _stepfunReset(credit?['subscription_credit_reset_time']);
        windows.add(
          quotaWindow(
            'stepfun-credit',
            '积分',
            usedPercent: _leftToUsed(fraction),
            resetsAt: resetAt,
            windowMinutes: resetAt == null ? null : 43200,
          ),
        );
      }
    } else {
      windows
        ..add(
          quotaWindow(
            RateWindow.sessionId,
            '5 小时窗口',
            usedPercent: _leftToUsed(_stepfunFlex(json['five_hour_usage_left_rate'])),
            resetsAt: _stepfunReset(json['five_hour_usage_reset_time']),
            windowMinutes: 300,
          ),
        )
        ..add(
          quotaWindow(
            RateWindow.weeklyId,
            '每周窗口',
            usedPercent: _leftToUsed(_stepfunFlex(json['weekly_usage_left_rate'])),
            resetsAt: _stepfunReset(json['weekly_usage_reset_time']),
            windowMinutes: 10080,
          ),
        );
    }

    final plan = await _optional(() async {
      final pr = await sendRequest(
        ctx,
        displayName,
        Uri.parse('$_stepfunBase/GetStepPlanStatus'),
        method: 'POST',
        headers: headers,
        body: <String, Object>{},
        timeout: const Duration(seconds: 15),
      );
      return pr.statusCode == 200
          ? asString(asMap(decodeJsonObject(pr.body)?['subscription'])?['name'])
          : null;
    });

    return snapshot(
      account,
      ctx,
      plan: plan,
      source: 'web',
      windows: windows,
      extras: {'计划类型': creditPlan ? '积分套餐' : '编程套餐'},
    );
  }
}

// ----------------------------------------------------------------- ZoomMate

class _ZoomAuthError extends ProviderException {
  _ZoomAuthError()
    : super(
        'ZoomMate 登录已过期',
        hint: '在浏览器重新登录 zoom.us 后复制新的 Cookie，或粘贴新的 Authorization',
        statusCode: 401,
      );
}

class _ZoomParseError extends ProviderException {
  _ZoomParseError(String detail) : super('ZoomMate 返回了无法识别的数据: $detail');
}

class ZoomMateProvider extends _CookieProvider {
  @override
  String get id => 'zoommate';
  @override
  String get displayName => 'ZoomMate';
  @override
  int get brandColor => 0xFF0B5CFF;
  @override
  String get cookieLabel => 'zoom.us Cookie';
  @override
  String? get cookieHint => 'Cookie 请求头（或 Authorization 值）';
  @override
  String get setupHint =>
      '浏览器登录 zoom.us 后，复制 Cookie 请求头粘贴到这里（会自动换取访问令牌）；'
      '也可以直接粘贴 credits/status 请求的 Authorization 值，约 1 小时过期。';

  static const _hosts = ['ai.zoom.us', 'zoommate.zoom.us'];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final secret = FieldValues.of(this, account).secret;
    final cookie = secret.contains('=') ? normalizeCookieHeader(secret) : null;

    Future<Map<String, Object?>> call(String host, String path, {String? token}) async {
      final bearer = token == null ? null : 'Bearer $token';
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://$host/ai-computer/api/v1/$path'),
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'Accept-Language': 'en-US,en;q=0.9',
          'User-Agent': browserUserAgent,
          'Sec-Fetch-Dest': 'empty',
          'Sec-Fetch-Mode': 'cors',
          'Sec-Fetch-Site': 'same-site',
          'Origin': 'https://zoommate.zoom.us',
          'Referer': 'https://zoommate.zoom.us',
          'Cookie': ?cookie,
          'Authorization': ?bearer,
        },
      );
      if (r.statusCode == 401 || r.statusCode == 403) throw _ZoomAuthError();
      if (r.statusCode != 200) {
        throw ProviderException('ZoomMate HTTP ${r.statusCode}', statusCode: r.statusCode);
      }
      return asMap(decodeJsonObject(r.body)?['data']) ??
          (throw _ZoomParseError('missing data object'));
    }

    Future<T> failover<T>(Future<T> Function(String host) op) async {
      ProviderException? last;
      for (final host in _hosts) {
        try {
          return await op(host);
        } on _ZoomAuthError {
          rethrow;
        } on _ZoomParseError {
          rethrow;
        } on ProviderException catch (e) {
          last = e;
        }
      }
      throw last!;
    }

    final String token;
    String? email;
    if (cookie != null) {
      final login = await failover(
        (host) => call(host, 'login/?continue=https%3A%2F%2Fzoommate.zoom.us%2F'),
      );
      token =
          asString(login['nak']) ??
          (throw _ZoomParseError('missing nak in login bootstrap response'));
      email = asString(asMap(login['user_profile'])?['email']);
    } else {
      token = secret.replaceFirst(RegExp(r'^bearer\s+', caseSensitive: false), '').trim();
    }

    final status =
        asMap(
          (await failover((host) => call(host, 'credits/status', token: token)))['credit_status'],
        ) ??
        (throw _ZoomParseError('missing credit_status object'));
    double? number(String key) {
      final v = status[key];
      if (v == null) return null;
      if (v is num && v.isFinite) return v.toDouble();
      throw _ZoomParseError('invalid $key');
    }

    for (final key in [
      'budget_cap',
      'used_credit',
      'remaining_credit',
      'overage_credit',
      'cycle_start_date',
      'cycle_end_date',
    ]) {
      number(key);
    }
    for (final key in ['allow_overage', 'is_quota_available', 'is_unlimited']) {
      final v = status[key];
      if (v != null && v is! bool) throw _ZoomParseError('invalid $key');
    }
    final cap = number('budget_cap') ?? 0;
    final used = number('used_credit') ?? 0;
    final cycleStart = number('cycle_start_date');
    final cycleEnd = number('cycle_end_date');
    final unlimited = status['is_unlimited'] == true || cap <= 0;
    final usedPercent = unlimited ? 0.0 : pct(used, cap);
    final now = ctx.now().toUtc();

    final since = now.subtract(const Duration(days: 30));
    Future<List<Map<String, Object?>>> history(String host) async {
      final records = <Map<String, Object?>>[];
      for (var page = 0; page < 20; page++) {
        final query =
            'app_id=demo_app&limit=50&page=$page&sort_by=time&sort_order=desc'
            '&start_time=${Uri.encodeQueryComponent(since.toIso8601String())}'
            '&end_time=${Uri.encodeQueryComponent(now.toIso8601String())}';
        final data = await call(host, 'credits/history?$query', token: token);
        final raw = data['records'];
        if (raw != null && raw is! List) throw _ZoomParseError('invalid history records');
        final rows = [
          for (final item in (raw as List?) ?? const [])
            asMap(item) ?? (throw _ZoomParseError('invalid history record')),
        ];
        records.addAll(rows);
        final total = _numOrNull(data['total']) ?? records.length.toDouble();
        final exhausted = rows.every((row) {
          final t = DateTime.tryParse(asString(row['time']) ?? '');
          return t != null && t.isBefore(since);
        });
        if (rows.isEmpty || (page + 1) * 50 >= total || exhausted) break;
      }
      return records;
    }

    final historyRows = await _optional(() => failover(history));
    final extras = <String, String>{
      '额度': unlimited ? '不限' : '${_num(used)} / ${_num(cap)} credits',
    };
    if (historyRows != null) {
      var today = 0.0;
      var month = 0.0;
      for (final row in historyRows) {
        final cost = _numOrNull(row['cost']);
        final time = DateTime.tryParse(asString(row['time']) ?? '');
        if (row['is_deleted'] == true ||
            cost == null ||
            cost < 0 ||
            time == null ||
            time.isBefore(since)) {
          continue;
        }
        month += cost;
        final t = time.toUtc();
        if (t.year == now.year && t.month == now.month && t.day == now.day) today += cost;
      }
      extras['今日'] = _num(today);
      extras['近30天'] = _num(month);
      if (!unlimited && cycleStart != null && cycleEnd != null && cycleEnd > cycleStart) {
        final duration = ((cycleEnd - cycleStart) / 60000).truncateToDouble() * 60000;
        final remaining = cycleEnd - now.millisecondsSinceEpoch;
        if (duration > 0 &&
            remaining > 0 &&
            remaining <= duration &&
            !(remaining == duration && usedPercent > 0)) {
          final delta = usedPercent - (1 - remaining / duration) * 100;
          final amount = delta.abs().round();
          extras['节奏'] = delta.abs() <= 2 ? '正常' : (delta > 0 ? '超前 $amount%' : '落后 $amount%');
        }
      }
    }

    final resetsAt = !unlimited && cycleEnd != null && cycleEnd > 0
        ? DateTime.fromMillisecondsSinceEpoch(cycleEnd.toInt(), isUtc: true)
        : null;
    return snapshot(
      account,
      ctx,
      email: email,
      source: cookie != null ? 'web' : 'api-key',
      windows: [
        quotaWindow('zoommate-credits', '积分额度', usedPercent: usedPercent, resetsAt: resetsAt),
      ],
      extras: extras,
    );
  }
}
