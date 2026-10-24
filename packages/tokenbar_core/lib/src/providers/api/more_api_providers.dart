import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

abstract class _KeyProvider extends UsageProvider {
  List<String> get keyEnv;
  String get keyLabel => 'API Key';

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  List<ProviderField> get fields => [ProviderField.apiKey(label: keyLabel, envVars: keyEnv)];

  String key(AccountConfig account) => bareToken(FieldValues.of(this, account).secret);
}

String _title(String v) =>
    v.toLowerCase().replaceAllMapped(RegExp(r'\b\w'), (m) => m[0]!.toUpperCase());

// --------------------------------------------------------------- Neuralwatt

UsageSnapshot parseNeuralwatt(UsageSnapshot base, Map<String, Object?> root) {
  final balance = asMap(root['balance']);
  if (balance == null) throw ProviderException('Neuralwatt 返回数据缺少余额');
  double? nonneg(Object? v) => (asDouble(v) ?? -1) >= 0 ? asDouble(v) : null;
  double? positive(Object? v) => (asDouble(v) ?? 0) > 0 ? asDouble(v) : null;
  final totalC = positive(balance['total_credits_usd']);
  final usedC = nonneg(balance['credits_used_usd']);
  final remainingRaw = nonneg(balance['credits_remaining_usd']);
  final remaining =
      remainingRaw ??
      (totalC != null && usedC != null ? (totalC - usedC).clamp(0, totalC).toDouble() : null);
  final sub = asMap(root['subscription']) ?? const {};
  final kwhUsed = nonneg(sub['kwh_used']);
  final kwhRemaining = nonneg(sub['kwh_remaining']);
  final included =
      positive(sub['kwh_included']) ??
      (kwhUsed != null && kwhRemaining != null && kwhUsed + kwhRemaining > 0
          ? kwhUsed + kwhRemaining
          : null);
  final consumed =
      kwhUsed ??
      (included != null && kwhRemaining != null
          ? (included - kwhRemaining).clamp(0, included).toDouble()
          : null);
  final start = parseFlexibleDate(sub['current_period_start']);
  final end = parseFlexibleDate(sub['current_period_end']);
  final minutes = start != null && end != null ? end.difference(start).inMinutes : null;
  final allowance = asMap(asMap(root['key'])?['allowance']) ?? const {};
  final limitUsd = asDouble(allowance['limit_usd']) ?? 0;
  final double? allowancePct = allowance['blocked'] == true
      ? 100
      : (allowance['spent_usd'] != null && limitUsd > 0
            ? pct(asDouble(allowance['spent_usd'])!, limitUsd)
            : null);
  final plan = asString(sub['plan']);
  final method = asString(balance['accounting_method']);
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    plan: plan != null
        ? '${_title(plan.replaceAll('_', ' '))} plan'
        : (method == null ? null : _title(method)),
    source: 'api-key',
    windows: [
      if (included != null && consumed != null)
        quotaWindow(
          'neuralwatt-kwh',
          '能耗额度 (kWh)',
          usedPercent: pct(consumed, included),
          resetsAt: end,
          windowMinutes: (minutes ?? 0) > 0 ? minutes : null,
        ),
      if (allowancePct != null)
        quotaWindow(
          'neuralwatt-key',
          'Key ${_title(asString(allowance['period']) ?? 'allowance')}',
          usedPercent: allowancePct,
        ),
    ],
    credits: [if (remaining != null) balanceRow('neuralwatt-balance', remaining, label: '预付余额')],
  );
}

class NeuralwattProvider extends _KeyProvider {
  @override
  String get id => 'neuralwatt';
  @override
  String get displayName => 'Neuralwatt';
  @override
  int get brandColor => 0xFFD55934;
  @override
  List<String> get keyEnv => const ['NEURALWATT_API_KEY'];
  @override
  String get setupHint => 'Neuralwatt 的 API Key，查询订阅 kWh 额度、Key 限额和预付余额。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.neuralwatt.com/v1/quota'),
      headers: {'Authorization': 'Bearer ${key(account)}'},
      timeout: const Duration(seconds: 15),
    );
    return parseNeuralwatt(snapshot(account, ctx), json);
  }
}

// ------------------------------------------------------------------- ZenMux

UsageSnapshot parseZenMux(UsageSnapshot base, Map<String, Object?> data, {double? payg}) {
  RateWindow win(String id, String label, Object? raw, int minutes) {
    final q = asMap(raw);
    final p = q?['usage_percentage'];
    if (q == null || p is! num) throw ProviderException('ZenMux 返回数据格式无法识别');
    return quotaWindow(
      id,
      label,
      usedPercent: (p * 100).clamp(0, 100).toDouble(),
      resetsAt: parseFlexibleDate(q['resets_at']),
      windowMinutes: minutes,
    );
  }

  final tier = asString(asMap(data['plan'])?['tier']);
  final status = asString(data['account_status']);
  final plan = tier == null ? null : '${_title(tier)} plan';
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    plan: status == null || status.toLowerCase() == 'healthy'
        ? plan
        : [?plan, _title(status)].join(' · '),
    source: 'api-key',
    windows: [
      win(RateWindow.sessionId, '5 小时', data['quota_5_hour'], 300),
      win(RateWindow.weeklyId, '每周', data['quota_7_day'], 10080),
    ],
    credits: [if (payg != null) balanceRow('zenmux-payg', payg, label: 'PAYG 余额')],
  );
}

class ZenMuxProvider extends _KeyProvider {
  @override
  String get id => 'zenmux';
  @override
  String get displayName => 'ZenMux';
  @override
  int get brandColor => 0xFF6C5CE7;
  @override
  List<String> get keyEnv => const ['ZENMUX_MANAGEMENT_API_KEY'];
  @override
  String get keyLabel => 'Management API Key';
  @override
  String get setupHint => 'ZenMux 的管理 API Key（推理 Key 不行），查询 5 小时 / 7 天 flows 额度与 PAYG 余额。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final headers = {'Authorization': 'Bearer ${key(account)}'};
    Future<Map<String, Object?>> get(String path) async {
      final json = await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('https://zenmux.ai/api/v1/management/$path'),
        headers: headers,
        authHint: '需要 Management API Key，推理 Key 不被支持',
      );
      final data = asMap(json['data']);
      if (json['success'] != true || data == null) throw ProviderException('ZenMux 管理接口返回无效数据');
      return data;
    }

    final detail = await get('subscription/detail');
    double? payg;
    try {
      final b = await get('payg/balance');
      if (asString(b['currency'])?.toLowerCase() == 'usd') payg = asDouble(b['total_credits']);
    } on ProviderException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) rethrow;
    }
    return parseZenMux(snapshot(account, ctx), detail, payg: payg);
  }
}

// ---------------------------------------------------------------------- Exa

class ExaProvider extends UsageProvider {
  @override
  String get id => 'exa';
  @override
  String get displayName => 'Exa';
  @override
  int get brandColor => 0xFF0143D9;
  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];
  @override
  String get setupHint => '需要 Exa Team Management 服务密钥（需联系 Exa 开通）和要查询的 API Key ID，查询该 Key 本月花费。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(label: 'Service Key', envVars: ['EXA_SERVICE_KEY']),
    ProviderField(
      key: 'apiKeyId',
      label: 'API Key ID',
      kind: FieldKind.text,
      help: '不是密钥本身，是 Key 的 ID',
      envVars: ['EXA_API_KEY_ID'],
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final v = FieldValues.of(this, account);
    final id = v.require('apiKeyId');
    if (id == '.' || id == '..') throw ProviderException('API Key ID 无效');
    final now = ctx.now().toUtc();
    String iso(DateTime t) => '${t.toIso8601String().split('.').first.replaceAll('Z', '')}.000Z';
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse(
        'https://admin-api.exa.ai/team-management/api-keys/${Uri.encodeComponent(id)}/usage'
        '?start_date=${iso(startOfUtcMonth(now))}&end_date=${iso(now)}',
      ),
      headers: {'x-api-key': v.secret},
      authHint: '需要 Team Management 服务密钥，普通搜索 Key 不支持',
    );
    final total = json['total_cost_usd'];
    if (total is! num || !total.isFinite || total < 0) throw ProviderException('Exa 返回了无法识别的用量');
    return snapshot(
      account,
      ctx,
      plan: 'Service key',
      source: 'api-key',
      credits: [spendRow('exa-spend', total.toDouble(), label: '本月花费（此 Key）')],
    );
  }
}

// ---------------------------------------------------------------------- fal

class FalProvider extends _KeyProvider {
  @override
  String get id => 'fal';
  @override
  String get displayName => 'fal';
  @override
  int get brandColor => 0xFF7C3AED;
  @override
  List<String> get keyEnv => const ['FAL_KEY'];
  @override
  String get setupHint =>
      'fal.ai 的 API Key（需要 billing:usage:read 权限，BILLING / READONLY / FULL 预设），查询 credits 余额。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.fal.ai/v1/account/billing?expand=credits'),
      headers: {'Authorization': 'Key ${key(account)}'},
      authHint: 'Key 需要 billing:usage:read 权限',
    );
    final credits = asMap(json['credits']);
    if (credits == null) throw ProviderException('fal 这次没有返回余额', hint: '稍后刷新');
    final raw = credits['current_balance'];
    final balance = raw is num
        ? raw.toDouble()
        : (raw is String && RegExp(r'^\s*-?\d+(\.\d+)?\s*$').hasMatch(raw)
              ? double.parse(raw)
              : null);
    if (balance == null || !balance.isFinite) throw ProviderException('fal 返回了无法识别的余额');
    final cur = asString(credits['currency']);
    return snapshot(
      account,
      ctx,
      plan: asString(json['username']),
      source: 'api-key',
      credits: [
        balanceRow(
          'fal-balance',
          balance,
          label: 'Credits 余额',
          currency: cur != null && RegExp(r'^[A-Z]{3}$').hasMatch(cur) ? cur : 'USD',
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- Soniox

class SonioxProvider extends _KeyProvider {
  @override
  String get id => 'soniox';
  @override
  String get displayName => 'Soniox';
  @override
  int get brandColor => 0xFF253772;
  @override
  List<String> get keyEnv => const ['SONIOX_ORG_API_KEY'];
  @override
  String get keyLabel => '组织 API Key';
  @override
  String get setupHint => 'Soniox 组织 API Key（需要“余额与花费”和“用量与限额”权限，项目 Key 不行），查询本月用量与预算。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final headers = {'Authorization': 'Bearer ${key(account)}'};
    Future<Map<String, Object?>> get(String path) => fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.soniox.com/v1/organization/$path'),
      headers: headers,
      timeout: const Duration(seconds: 15),
      authHint: '需要组织 API Key，项目 Key 不被支持',
    );
    final balance = await get('balance');
    final monthly = await get('usage/monthly');
    double? dec(Object? v) => v is String && RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v.trim())
        ? double.parse(v.trim())
        : null;
    final available = dec(balance['available_balance_usd']);
    final invoice = balance['invoice_billing_enabled'];
    final used = dec(monthly['usage_usd']);
    final budget = dec(monthly['monthly_budget_usd']);
    final month = RegExp(r'^(\d{4})-(0[1-9]|1[0-2])$').firstMatch(asString(monthly['month']) ?? '');
    if (available == null ||
        invoice is! bool ||
        used == null ||
        used < 0 ||
        budget == null ||
        budget < 0 ||
        month == null) {
      throw ProviderException('Soniox 返回了无效的账单数据');
    }
    final reset = DateTime.utc(int.parse(month[1]!), int.parse(month[2]!) + 1);
    return snapshot(
      account,
      ctx,
      plan: invoice ? '发票结算' : '预付',
      source: 'api-key',
      windows: [
        if (budget > 0)
          quotaWindow('soniox-budget', '月度预算', usedPercent: pct(used, budget), resetsAt: reset),
      ],
      credits: [
        spendRow('soniox-month', used, limit: budget, label: '本月', resetsAt: reset),
        if (!invoice) balanceRow('soniox-balance', available, label: '预付余额'),
      ],
    );
  }
}

// ---------------------------------------------------------------------- Poe

class PoeProvider extends _KeyProvider {
  @override
  String get id => 'poe';
  @override
  String get displayName => 'Poe';
  @override
  int get brandColor => 0xFF5D5CDE;
  @override
  List<String> get keyEnv => const ['POE_API_KEY'];
  @override
  String get setupHint => 'poe.com/api/keys 的 API Key，查询剩余积分。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.poe.com/usage/current_balance'),
      headers: {'Authorization': 'Bearer ${key(account)}'},
    );
    final points = asDouble(json['current_point_balance']);
    if (points == null) throw ProviderException('Poe 返回数据缺少积分余额');
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [balanceRow('poe-points', points, label: '积分余额', currency: null)],
    );
  }
}
