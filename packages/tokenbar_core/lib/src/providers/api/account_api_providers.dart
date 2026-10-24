import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

abstract class _Simple extends UsageProvider {
  List<String> get keyEnv;
  String get keyLabel => 'API Key';
  List<ProviderField> get extraFields => const [];

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  List<ProviderField> get fields => [
    ProviderField.apiKey(label: keyLabel, envVars: keyEnv),
    ...extraFields,
  ];

  FieldValues values(AccountConfig account) => FieldValues.of(this, account);
  String key(AccountConfig account) => bareToken(values(account).secret);
}

int? _count(Object? v) =>
    v is int && v >= 0 ? v : (v is double && v >= 0 && v == v.roundToDouble() ? v.toInt() : null);

// ---------------------------------------------------------------- Aerostack

class AerostackProvider extends _Simple {
  @override
  String get id => 'aerostack';
  @override
  String get displayName => 'Aerostack';
  @override
  int get brandColor => 0xFF6366F1;
  @override
  List<String> get keyEnv => const ['AEROSTACK_TOKEN'];
  @override
  String get keyLabel => '账户 JWT';
  @override
  String get setupHint => 'Aerostack 账户 JWT（不是 aek_ 开头的 Agent Key），查询本月 AI token 额度。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.aerostack.dev/api/billing/usage'),
      headers: {'Authorization': 'Bearer ${key(account)}'},
      authHint: '账户 JWT 已过期或被拒绝',
    );
    final tokens = asMap(asMap(json['usage'])?['ai_tokens']);
    final used = _count(tokens?['used']);
    final limit = _count(tokens?['limit']);
    if (tokens == null || (used == null && limit == null)) {
      throw ProviderException('Aerostack 返回了无法识别的用量');
    }
    return snapshot(
      account,
      ctx,
      plan: asString(json['tier']),
      source: 'api-key',
      windows: [
        if (used != null && limit != null && limit > 0)
          quotaWindow('aerostack-tokens', '本月 AI Token', usedPercent: pct(used, limit)),
      ],
      extras: {
        'AI Token': limit == null ? '$used' : '$used / $limit',
        if (json['period'] != null) '周期': '${json['period']}',
      },
    );
  }
}

// ------------------------------------------------------------------- Cosmic

int? parseCosmicAllowance(Object? v) {
  if (v is num) return _count(v);
  final m = RegExp(
    r'^(\d+(?:\.\d+)?)\s*([km]?)$',
    caseSensitive: false,
  ).firstMatch(asString(v) ?? '');
  if (m == null) return null;
  final mult = switch (m[2]!.toLowerCase()) {
    'k' => 1000,
    'm' => 1000000,
    _ => 1,
  };
  final n = double.parse(m[1]!) * mult;
  return n == n.roundToDouble() ? n.toInt() : null;
}

class CosmicProvider extends _Simple {
  @override
  String get id => 'cosmic';
  @override
  String get displayName => 'Cosmic AI';
  @override
  int get brandColor => 0xFF29ABE2;
  @override
  List<String> get keyEnv => const ['COSMIC_TOKEN'];
  @override
  String get keyLabel => 'Personal Access Token';
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'projectId',
      label: '项目 ID',
      kind: FieldKind.text,
      envVars: ['COSMIC_PROJECT_ID'],
    ),
  ];
  @override
  String get setupHint => 'Cosmic 个人访问令牌 + 项目 ID，查询项目的输入 / 输出 token 额度。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = values(account);
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse(
        'https://dapi.cosmicjs.com/v3/projects/usage?project_id=${Uri.encodeQueryComponent(v.require('projectId'))}',
      ),
      headers: {
        'Authorization': 'Bearer ${bareToken(v.secret)}',
        'Origin': 'https://app.cosmicjs.com',
      },
    );
    final ai = asMap(asMap(json['usage'])?['ai']) ?? const {};
    final plan = asMap(asMap(json['plan_info'])?['ai_tokens']) ?? const {};
    final windows = <RateWindow>[];
    for (final (id, label, usedKey, maxKey) in [
      ('cosmic-input', '输入 Token', 'input_tokens', 'max_input'),
      ('cosmic-output', '输出 Token', 'output_tokens', 'max_output'),
    ]) {
      final used = _count(ai[usedKey]);
      final max = parseCosmicAllowance(plan[maxKey]);
      if (used != null && max != null && max > 0) {
        windows.add(quotaWindow(id, label, usedPercent: pct(used, max)));
      }
    }
    return snapshot(account, ctx, source: 'api-key', windows: windows);
  }
}

// -------------------------------------------------------------------- FLORA

class FloraProvider extends _Simple {
  @override
  String get id => 'flora';
  @override
  String get displayName => 'FLORA';
  @override
  int get brandColor => 0xFF111111;
  @override
  List<String> get keyEnv => const ['FLORA_API_KEY'];
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'workspaceId',
      label: '工作区 ID',
      kind: FieldKind.text,
      hint: 'ws_...',
      envVars: ['FLORA_WORKSPACE_ID'],
    ),
  ];
  @override
  String get setupHint => 'FLORA 的 API Key（ak_...，需要工作区账单权限）+ 工作区 ID（ws_...），查询可用余额与本月花费。';

  @override
  String? validateManual(FieldValues values) {
    final ws = values['workspaceId'];
    return ws == null || RegExp(r'^ws_[A-Za-z0-9]+$').hasMatch(ws) ? null : '工作区 ID 应形如 ws_...';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = values(account);
    final ws = v.require('workspaceId');
    final now = ctx.now().toUtc();
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse(
        'https://app.flora.ai/api/v1/workspaces/$ws/usage?start_date=${day(startOfUtcMonth(now))}&end_date=${day(now)}',
      ),
      headers: {'Authorization': 'Bearer ${bareToken(v.secret)}'},
    );
    if (r.statusCode == 404) throw ProviderException('FLORA 找不到这个工作区 ID');
    final json = asMap(checkStatus(displayName, r, authHint: 'Key 需要该工作区的账单权限').json) ?? const {};
    final available = json['available_cost'];
    if (available is! num) throw ProviderException('FLORA 返回了无法识别的用量');
    final cur = asString(json['currency']);
    final currency = cur != null && RegExp(r'^[A-Z]{3}$').hasMatch(cur) ? cur : 'USD';
    final spend = asMap(json['spend']) ?? const {};
    final spent = spend['status'] == 'available' ? asDouble(spend['total_cost']) : null;
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [
        balanceRow(
          'flora-available',
          available.toDouble(),
          label: json['balance_scope'] == 'caller' ? '我的可用额度' : '工作区可用余额',
          currency: currency,
        ),
        if (spent != null) spendRow('flora-month', spent, label: '本月花费', currency: currency),
      ],
      extras: {if (spend['classified_runs'] != null) '本月运行次数': '${spend['classified_runs']}'},
    );
  }
}

// ---------------------------------------------------------------- Future AGI

class FutureAgiProvider extends _Simple {
  @override
  String get id => 'futureagi';
  @override
  String get displayName => 'Future AGI';
  @override
  int get brandColor => 0xFF7857FC;
  @override
  List<String> get keyEnv => const ['FI_API_KEY'];
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(key: 'secretKey', label: 'Secret Key', envVars: ['FI_SECRET_KEY']),
  ];
  @override
  String get setupHint => 'Future AGI 的 API Key + Secret Key，查询本计费周期 AI credits / 网关请求额度。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = values(account);
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.futureagi.com/usage/v2/usage-overview/'),
      headers: {'X-Api-Key': v.secret, 'X-Secret-Key': v.require('secretKey')},
    );
    final result = asMap(json['result']);
    final dims = asList(result?['dimensions']);
    if (json['status'] != true || dims == null) throw ProviderException('Future AGI 返回了无法识别的用量概览');
    final start = parseFlexibleDate(result!['billing_period_start']);
    final end = parseFlexibleDate(result['billing_period_end']);
    final minutes = start != null && end != null ? end.difference(start).inMinutes : null;
    final windows = <RateWindow>[];
    final extras = <String, String>{};
    for (final d in dims.map(asMap).whereType<Map<String, Object?>>()) {
      final used = asDouble(d['current_usage']) ?? 0;
      final allowance = asDouble(d['free_allowance']) ?? 0;
      final name = asString(d['display_name']) ?? asString(d['key']) ?? '';
      extras[name] = '${_n(used)} / ${_n(allowance)} ${asString(d['display_unit']) ?? ''}'.trim();
      if (allowance > 0 && const {'ai_credits', 'gateway_requests'}.contains(d['key'])) {
        windows.add(
          quotaWindow(
            'futureagi-${d['key']}',
            d['key'] == 'ai_credits' ? 'AI Credits' : '网关请求',
            usedPercent: pct(used, allowance),
            resetsAt: end,
            windowMinutes: minutes,
          ),
        );
      }
    }
    final cost = asDouble(result['total_estimated_cost']);
    return snapshot(
      account,
      ctx,
      plan: asString(json['plan_display_name']) ?? asString(result['plan_display_name']),
      source: 'api-key',
      windows: windows,
      credits: [
        if (cost != null) spendRow('futureagi-cost', cost, label: '本周期估算费用', resetsAt: end),
      ],
      extras: extras,
    );
  }
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

// ---------------------------------------------------------------- GitKraken

class GitKrakenProvider extends _Simple {
  @override
  String get id => 'gitkraken';
  @override
  String get displayName => 'GitKraken AI';
  @override
  int get brandColor => 0xFF179287;
  @override
  List<String> get keyEnv => const ['GITKRAKEN_API_TOKEN'];
  @override
  String get keyLabel => '会话 Access Token';
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'orgId',
      label: '组织 ID',
      kind: FieldKind.text,
      required: false,
      envVars: ['GITKRAKEN_ORG_ID'],
    ),
  ];
  @override
  String get setupHint =>
      '浏览器登录 gitkraken.dev，在开发者工具里复制请求头 Authorization: Bearer 后面的值，查询每周 AI credits。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = values(account);
    final org = v['orgId'];
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.gitkraken.dev/v1/ai-tasks/usage'),
      headers: {
        'Authorization': 'Bearer ${bareToken(v.secret)}',
        'Client-Name': 'TokenBar',
        'Client-Version': '0.0.0',
        'User-Agent': ctx.userAgent,
        'gk-org-id': ?org,
      },
      authHint: '会话令牌已过期，重新从浏览器复制',
    );
    final data = asMap(json['data']);
    final used = asDouble(data?['used']);
    final limit = asDouble(data?['limit']);
    final reset = parseFlexibleDate(data?['resetsOn']);
    if (json['error'] != null || used == null || limit == null || reset == null) {
      throw ProviderException('GitKraken 返回了无法识别的用量');
    }
    final orgPool = asMap(data!['organization']);
    final orgUsed = asDouble(orgPool?['used']);
    final orgLimit = asDouble(orgPool?['limit']);
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      windows: [
        if (limit > 0)
          quotaWindow(
            'gitkraken-personal',
            '个人每周',
            usedPercent: pct(used, limit),
            resetsAt: reset,
            windowMinutes: 10080,
          ),
        if (orgUsed != null && orgLimit != null && orgLimit > 0)
          quotaWindow(
            'gitkraken-org',
            '组织共享池',
            usedPercent: pct(orgUsed, orgLimit),
            resetsAt: reset,
            windowMinutes: 10080,
          ),
      ],
      extras: {
        '个人': limit > 0
            ? '${_n(used)} / ${_n(limit)} credits'
            : '${_n(used)} credits · ${limit < 0 ? '不限' : '无额度'}',
      },
    );
  }
}

// ------------------------------------------------------------ Sail Research

class SailResearchProvider extends _Simple {
  @override
  String get id => 'sailresearch';
  @override
  String get displayName => 'Sail Research';
  @override
  int get brandColor => 0xFF2C4681;
  @override
  List<String> get keyEnv => const ['SAIL_API_KEY'];
  @override
  String get setupHint => 'Sail Research 的 API Key，查询组织 credits 余额与近期花费。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('https://api.sailresearch.com/v2/usage/summary?range=30d'),
      headers: {'Authorization': 'Bearer ${key(account)}'},
      timeout: const Duration(seconds: 15),
    );
    if (r.statusCode == 402) {
      throw ProviderException('Sail Research 的 credits 已用完，Key 被停用', statusCode: 402);
    }
    final json = asMap(checkStatus(displayName, r).json) ?? const {};
    if (json['object'] != 'usage.summary') throw ProviderException('Sail Research 返回了无法识别的账单摘要');
    if (json['available'] == false) throw ProviderException('Sail Research 暂时无法提供账单数据');
    if (json['has_metronome_customer'] == false) {
      throw ProviderException('这个 Sail Research 组织没有账单账户');
    }
    final label = switch (json['effective_range']) {
      '1h' => '近 1 小时花费',
      '6h' => '近 6 小时花费',
      '24h' => '近 24 小时花费',
      '7d' => '近 7 天花费',
      'period' => '本计费周期花费',
      _ => '近 30 天花费',
    };
    final balance = json['balance_unavailable'] == true ? null : asDouble(json['balance']);
    final spend = asDouble(json['period_spend']);
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [
        if (balance != null) balanceRow('sail-balance', balance / 100, label: 'Credits 余额'),
        if (spend != null) spendRow('sail-spend', spend / 100, label: label),
      ],
    );
  }
}

// ------------------------------------------------------------------- Munito

class MunitoProvider extends _Simple {
  @override
  String get id => 'munito';
  @override
  String get displayName => 'Munito';
  @override
  int get brandColor => 0xFF702CF6;
  @override
  List<String> get keyEnv => const ['MUNITO_API_KEY', 'MUNITO_ADMIN_KEY'];
  @override
  String get keyLabel => 'Admin API Key';
  @override
  String get setupHint => 'Munito 的 Admin API Key（需要“读取账户数据”权限），查询每日 / 每月花费限额。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final headers = {'Authorization': 'Bearer ${key(account)}'};
    final limits = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.munito.ai/admin/v1/limits'),
      headers: headers,
      authHint: 'Admin API 需要有“读取账户数据”权限的 Key',
    );
    Map<String, Object?>? org;
    try {
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse('https://api.munito.ai/admin/v1/organization'),
        headers: headers,
        timeout: const Duration(seconds: 3),
      );
      org = r.ok ? asMap(r.json) : null;
    } on ProviderException {
      org = null;
    }
    final periods = asList(limits['periods']);
    if (periods == null) throw ProviderException('Munito 返回了无法识别的限额数据');
    Map<String, Object?>? find(String p) => periods
        .map(asMap)
        .whereType<Map<String, Object?>>()
        .where((e) => e['period'] == p)
        .firstOrNull;
    final day = find('day');
    final month = find('month');
    double spent(Map<String, Object?> m) => asDouble(m['spent_usd']) ?? 0;
    double lim(Map<String, Object?> m) => asDouble(m['limit_usd']) ?? 0;
    final costSource = month ?? day;
    return snapshot(
      account,
      ctx,
      plan: asString(org?['name']) ?? asString(limits['usage_tier']),
      source: 'api-key',
      windows: [
        if (day != null && lim(day) > 0)
          quotaWindow(
            'munito-day',
            '每日',
            usedPercent: pct(spent(day), lim(day)),
            windowMinutes: 1440,
          ),
        if (month != null && lim(month) > 0)
          quotaWindow('munito-month', '每月', usedPercent: pct(spent(month), lim(month))),
      ],
      credits: [
        if (costSource != null)
          spendRow(
            'munito-spend',
            spent(costSource),
            limit: lim(costSource),
            label: month != null ? '本月' : '今日',
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- Sofya

class SofyaProvider extends _Simple {
  @override
  String get id => 'sofya';
  @override
  String get displayName => 'Sofya';
  @override
  int get brandColor => 0xFFB0B820;
  @override
  List<String> get keyEnv => const ['SOFYA_API_KEY'];
  @override
  String get setupHint => 'sofya.co 的 API Key，查询可用 / 套餐 / 购买 credits。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://sofya.co/v1/auth/me'),
      headers: {'Authorization': 'Bearer ${key(account)}'},
      timeout: const Duration(seconds: 15),
    );
    final rows = <String, double>{
      for (final (k, label) in [
        ('credits', '可用 Credits'),
        ('plan_credits', '套餐 Credits'),
        ('purchased_credits', '购买 Credits'),
      ])
        if (asDouble(json[k]) != null) label: asDouble(json[k])!,
    };
    if (rows.isEmpty) throw ProviderException('Sofya 返回了无法识别的 credits 数据');
    final free = json['is_free_tier'];
    return snapshot(
      account,
      ctx,
      plan: free == true ? 'Free tier' : (free == false ? 'Pay as you go' : 'API'),
      source: 'api-key',
      credits: [
        for (final e in rows.entries)
          balanceRow('sofya-${e.key}', e.value, label: e.key, currency: null),
      ],
      extras: {
        if (free == true && json['credits_reset_at'] != null) '每月重置': '${json['credits_reset_at']}',
      },
    );
  }
}

// ------------------------------------------------------------------ Chatbox

class ChatboxProvider extends _Simple {
  @override
  String get id => 'chatbox';
  @override
  String get displayName => 'Chatbox AI';
  @override
  int get brandColor => 0xFF228BE6;
  @override
  List<String> get keyEnv => const ['CHATBOX_LICENSE_KEY'];
  @override
  String get keyLabel => 'License Key';
  @override
  String get setupHint => 'Chatbox AI 的 License Key，查询套餐 / 奖励 / 加油包 / 图片额度。';

  @override
  String? validateManual(FieldValues values) {
    final k = values[ProviderField.secretKey];
    return k != null && (k.length > 4096 || RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(k))
        ? 'License Key 格式无效'
        : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.chatboxai.app/api/license/detail/realtime'),
      headers: {'Authorization': values(account).secret, 'Cache-Control': 'no-store'},
      authHint: 'License Key 无效',
    );
    final data = asMap(json['data']);
    if (data == null || (json['error'] != null && json['error'] != false)) {
      throw ProviderException('Chatbox AI 返回了无法识别的数据');
    }
    final now = ctx.now();
    final expiry = parseFlexibleDate(data['token_expire_time'] ?? data['expires_at']);
    final status = asString(data['status']);
    final usable =
        (status == null || status == 'active') && (expiry == null || expiry.isAfter(now));
    final details = (asList(data['unified_token_usage_details']) ?? const [])
        .map(asMap)
        .whereType<Map<String, Object?>>();
    final plan = details.where((d) => d['type'] == 'plan').firstOrNull;
    final planUsed = _count(plan?['token_usage']);
    final planLimit = _count(plan?['token_limit']);
    final next = parseFlexibleDate(data['token_next_refresh_time']);
    final reset = next != null && next.isAfter(now) && (expiry == null || next.isBefore(expiry))
        ? next
        : null;
    final expUsed = _count(data['expansion_pack_usage']);
    final expLimit = _count(data['expansion_pack_limit']);
    final imgUsed = _count(data['image_used_count']);
    final imgLimit = _count(data['image_total_quota']);
    return snapshot(
      account,
      ctx,
      plan: asString(data['name']),
      source: 'api-key',
      windows: [
        if (usable && planUsed != null && planLimit != null && planLimit > 0)
          quotaWindow('chatbox-plan', '套餐', usedPercent: pct(planUsed, planLimit), resetsAt: reset),
        if (expUsed != null && expLimit != null && expLimit > 0)
          quotaWindow('chatbox-topup', '加油包', usedPercent: pct(expUsed, expLimit)),
        if (imgUsed != null && imgLimit != null && imgLimit > 0)
          quotaWindow('chatbox-image', '图片生成', usedPercent: pct(imgUsed, imgLimit)),
      ],
    );
  }
}

// ------------------------------------------------------------------ IBM Bob

String ibmBobAuthorization(String token) {
  final parts = token.split('.');
  final isJwt = parts.length == 3 && decodeJwtPayload(token) != null;
  return isJwt ? 'Bearer $token' : 'Apikey $token';
}

String ibmBobRegionalBase(String? domain) {
  if (domain == null || domain.trim().isEmpty) return 'https://api.us-east.bob.ibm.com';
  final d = domain.trim();
  final host = d.toLowerCase().startsWith('api.') ? d : 'api.$d';
  final uri = Uri.tryParse('https://$host');
  final h = uri?.host.toLowerCase() ?? '';
  final trusted =
      uri != null &&
      !host.contains('/') &&
      !host.contains('@') &&
      !host.contains(':') &&
      (h == 'bob.ibm.com' || h.endsWith('.bob.ibm.com'));
  if (!trusted) throw ProviderException('IBM Bob 返回了不受信任的区域地址: $host');
  return 'https://$h';
}

class IbmBobProvider extends _Simple {
  @override
  String get id => 'ibmbob';
  @override
  String get displayName => 'IBM Bob';
  @override
  int get brandColor => 0xFF0E61FA;
  @override
  List<String> get keyEnv => const ['BOBSHELL_API_KEY'];
  @override
  String get setupHint => 'IBM Bob 的 API Key（或 Bob 会话 JWT），查询各团队 Bobcoin 预算。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final token = values(account).secret.trim();
    final base = {
      'Authorization': ibmBobAuthorization(token),
      'Content-Type': 'application/json',
      'User-Agent': ctx.userAgent,
    };
    final profile = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.us-east.bob.ibm.com/admin/v1/profile'),
      headers: base,
      authHint: '检查 Key 是否有效并可读取订阅用量',
    );
    var used = 0.0;
    var limit = 0.0;
    var allLimited = true;
    var teams = 0;
    DateTime? reset;
    final plans = <String>{};
    for (final inst
        in (asList(profile['instances']) ?? const [])
            .map(asMap)
            .whereType<Map<String, Object?>>()) {
      final userId = asString(inst['user_id']);
      if (userId == null) continue;
      final regional = ibmBobRegionalBase(asString(inst['region_domain']));
      final at = parseFlexibleDate(inst['refresh_at']);
      if (at != null && (reset == null || at.isBefore(reset))) reset = at;
      final plan = asString(inst['plan_name']);
      if (plan != null) plans.add(plan);
      for (final team
          in (asList(inst['teams']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
        final teamId = asString(team['id']);
        if (teamId == null) continue;
        final budget = await fetchJsonObject(
          ctx,
          displayName,
          Uri.parse('$regional/admin/v1/teams/$teamId/users/$userId'),
          headers: {
            ...base,
            'x-instance-id': asString(inst['instance_id']) ?? '',
            'x-team-id': teamId,
          },
        );
        final u = asDouble(budget['usage']);
        if (u == null) throw ProviderException('IBM Bob 团队预算缺少 usage');
        used += u < 0 ? 0 : u;
        final l = asDouble(budget['budget_limit']) ?? asDouble(team['budget_limit']);
        if (l == null || l < 0) {
          allLimited = false;
        } else {
          limit += l;
        }
        teams++;
      }
    }
    if (teams == 0) throw ProviderException('这个 IBM Bob Key 没有订阅实例或团队');
    final hasLimit = allLimited && limit > 0;
    return snapshot(
      account,
      ctx,
      plan: (plans.toList()..sort()).join(', '),
      source: 'api-key',
      windows: [
        quotaWindow(
          'ibmbob-bobcoins',
          'Bobcoins',
          usedPercent: hasLimit ? pct(used, limit) : 0,
          resetsAt: reset,
          windowMinutes: 43200,
        ),
      ],
      extras: {'Bobcoins': hasLimit ? '${_n(used)} / ${_n(limit)}' : '已用 ${_n(used)}'},
    );
  }
}
