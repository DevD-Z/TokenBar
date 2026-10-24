import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

abstract class _Keyed extends UsageProvider {
  List<String> get keyEnv;
  List<ProviderField> get extraFields => const [];

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  List<ProviderField> get fields => [ProviderField.apiKey(envVars: keyEnv), ...extraFields];

  FieldValues values(AccountConfig account) => FieldValues.of(this, account);
  Map<String, String> bearer(AccountConfig account) => {
    'Authorization': 'Bearer ${bareToken(values(account).secret)}',
  };
}

double? _num(Object? v) => v is String ? double.tryParse(v.trim()) : asDouble(v);

// --------------------------------------------------------------------- Kimi

const _kimiLevels = {
  'LEVEL_FREE': 'Adagio',
  'LEVEL_TRIAL': 'Andante',
  'LEVEL_BASIC': 'Moderato',
  'LEVEL_INTERMEDIATE': 'Allegretto',
  'LEVEL_ADVANCED': 'Allegro',
};

DateTime? _kimiReset(Map<String, Object?> m) =>
    parseFlexibleDate(m['resetTime'] ?? m['reset_time'] ?? m['resetAt'] ?? m['reset_at']);

/// Percent from a `{limit, used, remaining}` counter block.
double? _kimiCountPercent(Map<String, Object?>? m) {
  if (m == null) return null;
  final limit = _num(m['limit']);
  if (limit == null || limit <= 0) return null;
  final remaining = _num(m['remaining']);
  final used =
      _num(m['used']) ??
      (remaining != null && remaining >= 0 && remaining <= limit ? limit - remaining : null);
  return used == null ? null : pct(used, limit);
}

UsageSnapshot parseKimiCodeUsage(UsageSnapshot base, Map<String, Object?> json) {
  final pools = asMap(json['usages']) ?? const {};
  RateWindow? ratio(String key, String id, String label, int minutes) {
    final p = asMap(pools[key]);
    final r = asDouble(p?['used_ratio']);
    if (r == null) return null;
    return quotaWindow(
      id,
      label,
      usedPercent: (r.clamp(0, 1) * 100).toDouble(),
      resetsAt: parseFlexibleDate(p!['reset_time']),
      windowMinutes: minutes,
    );
  }

  final usage = asMap(json['usage']);
  final weeklyPct = _kimiCountPercent(usage);
  final weekly =
      ratio('limit_7d', RateWindow.weeklyId, '每周', 10080) ??
      (weeklyPct == null
          ? null
          : quotaWindow(
              RateWindow.weeklyId,
              '每周',
              usedPercent: weeklyPct,
              resetsAt: _kimiReset(usage!),
              windowMinutes: 10080,
            ));

  final limit0 = asMap((asList(json['limits']) ?? const []).firstOrNull);
  final detail = asMap(limit0?['detail']);
  final win = asMap(limit0?['window']);
  final duration = asInt(win?['duration']);
  final minutes = duration == null
      ? 300
      : duration *
            switch (win?['timeUnit']) {
              'TIME_UNIT_HOUR' => 60,
              'TIME_UNIT_DAY' => 1440,
              _ => 1,
            };
  final sessionPct = _kimiCountPercent(detail);
  final session =
      ratio('limit_5h', RateWindow.sessionId, '5 小时', 300) ??
      (sessionPct == null
          ? null
          : quotaWindow(
              RateWindow.sessionId,
              minutes % 60 == 0 ? '${minutes ~/ 60} 小时' : '$minutes 分钟',
              usedPercent: sessionPct,
              resetsAt: _kimiReset(detail!),
              windowMinutes: minutes,
            ));
  final monthly = ratio('limit_month_total', 'kimi-monthly', '月度总量', 43200);

  final membership = asMap(asMap(json['user'])?['membership']);
  final version = asString(membership?['version']);
  final level = asString(membership?['level']);
  final plan =
      (version == null || version == 'GOODS_VERSION_V1') &&
          level != null &&
          level != 'LEVEL_UNSPECIFIED'
      ? _kimiLevels[level] ?? level
      : null;
  final windows = [?weekly, ?session, ?monthly];
  if (windows.isEmpty) throw ProviderException('Kimi 返回数据中没有用量信息');
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    plan: plan,
    source: 'api-key',
    windows: windows,
  );
}

class KimiProvider extends _Keyed {
  @override
  String get id => 'kimi';
  @override
  String get displayName => 'Kimi Code';
  @override
  int get brandColor => 0xFFFE603C;
  @override
  List<String> get keyEnv => const ['KIMI_CODE_API_KEY'];
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'region',
      label: '区域',
      kind: FieldKind.choice,
      defaultValue: 'china',
      choices: [
        FieldChoice('china', '中国站 api.kimi.com'),
        FieldChoice('international', '国际站 api.kimi.ai'),
      ],
    ),
  ];
  @override
  String get setupHint => 'Kimi Code 的 API Key，查询每周 / 5 小时 / 月度编程额度。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final host = values(account)['region'] == 'international'
        ? 'https://api.kimi.ai'
        : 'https://api.kimi.com';
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('$host/coding/v1/usages'),
      headers: bearer(account),
    );
    return parseKimiCodeUsage(snapshot(account, ctx), json);
  }
}

// ------------------------------------------------------------------ MiniMax

DateTime? _epoch(Object? v) {
  final n = asDouble(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch((n > 1e12 ? n : n * 1000).round(), isUtc: true);
}

UsageSnapshot parseMiniMaxRemains(UsageSnapshot base, Map<String, Object?> root, DateTime now) {
  final baseResp = asMap(root['base_resp']) ?? asMap(asMap(root['data'])?['base_resp']);
  final code = asInt(baseResp?['status_code']) ?? 0;
  if (code != 0) {
    final msg = asString(baseResp?['status_msg']) ?? '';
    final auth =
        code == 1004 ||
        RegExp(r'cookie|log ?in|invalid api key', caseSensitive: false).hasMatch(msg);
    throw ProviderException(
      auth ? 'MiniMax 拒绝了这个 Key' : 'MiniMax 返回错误: $msg',
      hint: auth ? '检查 Token Plan / Coding Plan Key' : null,
    );
  }
  final data = asMap(root['data']) ?? root;
  final items = (asList(data['model_remains']) ?? const [])
      .map(asMap)
      .whereType<Map<String, Object?>>()
      .toList();
  if (items.isEmpty) throw ProviderException('MiniMax 返回数据中没有套餐额度');

  RateWindow? lane(Map<String, Object?> m, String prefix, String id, String label) {
    final status = asInt(m['current_${prefix}_status']);
    final total = asDouble(m['current_${prefix}_total_count']) ?? 0;
    final remainingPct = asDouble(m['current_${prefix}_remaining_percent']);
    if (status == 3 && total <= 0) return null;
    double? used;
    if (remainingPct != null) {
      used = (100 - remainingPct).clamp(0, 100).toDouble();
    } else if (total > 0 && m['current_${prefix}_usage_count'] != null) {
      used = pct(total - asDouble(m['current_${prefix}_usage_count'])!, total);
    }
    if (used == null) return null;
    final startKey = prefix == 'interval' ? 'start_time' : 'weekly_start_time';
    final endKey = prefix == 'interval' ? 'end_time' : 'weekly_end_time';
    final remainsKey = prefix == 'interval' ? 'remains_time' : 'weekly_remains_time';
    final start = _epoch(m[startKey]);
    final end = _epoch(m[endKey]);
    final minutes = start != null && end != null ? end.difference(start).inMinutes : null;
    var reset = end != null && end.isAfter(now) ? end : null;
    final remains = asDouble(m[remainsKey]);
    if (reset == null && remains != null && remains > 0) {
      reset = now.add(
        Duration(milliseconds: (remains > 1000000 ? remains : remains * 1000).round()),
      );
    }
    return quotaWindow(
      id,
      label,
      usedPercent: used,
      resetsAt: reset,
      windowMinutes: (minutes ?? 0) > 0 ? minutes : null,
    );
  }

  final windows = <RateWindow>[];
  for (final (i, m) in items.indexed) {
    final name = asString(m['model_name']) ?? 'model$i';
    final suffix = i == 0 ? '' : '-$name';
    final tag = i == 0 ? '' : ' · $name';
    final interval = lane(
      m,
      'interval',
      i == 0 ? RateWindow.sessionId : 'minimax-interval$suffix',
      '区间$tag',
    );
    final weekly = lane(
      m,
      'weekly',
      i == 0 ? RateWindow.weeklyId : 'minimax-weekly$suffix',
      '每周$tag',
    );
    windows.addAll([?interval, ?weekly]);
  }
  final plan =
      [
        'plan_name',
        'current_subscribe_title',
        'combo_title',
        'current_plan_title',
      ].map((k) => asString(data[k])).nonNulls.firstOrNull ??
      asString(asMap(data['current_combo_card'])?['title']);
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    plan: plan,
    source: 'api-key',
    windows: windows,
  );
}

class MiniMaxProvider extends _Keyed {
  @override
  String get id => 'minimax';
  @override
  String get displayName => 'MiniMax';
  @override
  int get brandColor => 0xFFFE603C;
  @override
  List<String> get keyEnv => const ['MINIMAX_CODING_API_KEY', 'MINIMAX_API_KEY'];
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'region',
      label: '区域',
      kind: FieldKind.choice,
      defaultValue: 'cn',
      choices: [
        FieldChoice('cn', '中国站 api.minimaxi.com'),
        FieldChoice('global', '国际站 api.minimax.io'),
      ],
    ),
  ];
  @override
  String get setupHint => 'MiniMax Token Plan / Coding Plan 的 API Key，查询区间与每周额度。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final host = values(account)['region'] == 'global'
        ? 'https://api.minimax.io'
        : 'https://api.minimaxi.com';
    final headers = {
      ...bearer(account),
      'Content-Type': 'application/json',
      'MM-API-Source': 'TokenBar',
    };
    final r = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$host/v1/token_plan/remains'),
      headers: headers,
    );
    final json = r.ok && asMap(r.json) != null
        ? asMap(r.json)!
        : await fetchJsonObject(
            ctx,
            displayName,
            Uri.parse('$host/v1/api/openplatform/coding_plan/remains'),
            headers: headers,
          );
    return parseMiniMaxRemains(snapshot(account, ctx), json, ctx.now());
  }
}

// ----------------------------------------------------------------------- v0

class V0Provider extends _Keyed {
  @override
  String get id => 'v0';
  @override
  String get displayName => 'v0';
  @override
  int get brandColor => 0xFF111111;
  @override
  List<String> get keyEnv => const ['V0_API_KEY'];
  @override
  List<ProviderField> get extraFields => const [
    ProviderField(
      key: 'scope',
      label: 'Scope（项目 ID / slug）',
      kind: FieldKind.text,
      required: false,
      envVars: ['V0_SCOPE'],
    ),
  ];
  @override
  String get setupHint => 'v0 Platform API Key，查询账单余额与 API 速率限制。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final scope = values(account)['scope'];
    final query = scope == null ? '' : '?scope=${Uri.encodeQueryComponent(scope)}';
    Future<Map<String, Object?>> get(String path) => fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.v0.dev/v1$path$query'),
      headers: bearer(account),
    );
    final billing = await get('/user/billing');
    final rate = await get('/rate-limits');
    final type = asString(billing['billingType']);
    final data = asMap(billing['data']) ?? const {};
    double? usedPct;
    DateTime? reset;
    if (type == 'token') {
      final balance = asMap(data['balance']) ?? const {};
      final total = asDouble(balance['total']);
      final remaining = asDouble(balance['remaining']);
      if (total == null || remaining == null) throw ProviderException('v0 账单数据无法识别');
      usedPct = pct((total - remaining).clamp(0, double.infinity), total);
      reset = _epoch(asMap(data['billingCycle'])?['end']);
    } else if (type == 'legacy') {
      final limit = asDouble(data['limit']);
      final remaining = asDouble(data['remaining']);
      if (limit == null) throw ProviderException('v0 账单数据无法识别');
      if (remaining != null) usedPct = pct((limit - remaining).clamp(0, double.infinity), limit);
      reset = _epoch(data['reset']);
    } else {
      throw ProviderException('v0 返回了未知的计费类型');
    }
    final rLimit = asDouble(rate['limit']);
    final rRemaining = asDouble(rate['remaining']);
    return snapshot(
      account,
      ctx,
      plan: type == 'token' ? 'Token 计费' : 'Legacy',
      source: 'api-key',
      windows: [
        if (usedPct != null)
          quotaWindow('v0-billing', '账单额度', usedPercent: usedPct, resetsAt: reset),
        if (rLimit != null && rRemaining != null)
          quotaWindow(
            'v0-rate',
            '速率限制',
            usedPercent: pct((rLimit - rRemaining).clamp(0, double.infinity), rLimit),
            resetsAt: _epoch(rate['reset']),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ DevPass

class DevPassProvider extends _Keyed {
  @override
  String get id => 'devpass';
  @override
  String get displayName => 'DevPass';
  @override
  int get brandColor => 0xFF2563EB;
  @override
  List<String> get keyEnv => const ['DEVPASS_API_KEY'];
  @override
  String get setupHint => 'DevPass (LLM Gateway) 的 API Key，查询套餐 credits、每周 premium 额度与 Key 花费。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.llmgateway.io/v1/key'),
      headers: bearer(account),
      authHint: '需要普通网关 API Key',
    );
    final data = asMap(json['data']);
    final plan = asString(data?['devPlan']);
    if (data == null || !const {'none', 'lite', 'pro', 'max'}.contains(plan)) {
      throw ProviderException('DevPass 返回了无法识别的用量');
    }
    double money(String k) => _num(data[k]) ?? (throw ProviderException('DevPass 返回了无法识别的用量'));
    final keyLimit = data['limit'] == null ? null : money('limit');
    final keySpend = spendRow('devpass-key', money('usage'), limit: keyLimit, label: 'Key 累计花费');
    if (plan == 'none') {
      return snapshot(account, ctx, plan: 'Pay as you go', source: 'api-key', credits: [keySpend]);
    }
    final used = money('devPlanCreditsUsed');
    final limit = money('devPlanCreditsLimit');
    final wUsed = money('devPlanPremiumCreditsUsed');
    final wLimit = money('devPlanPremiumWeeklyLimit');
    return snapshot(
      account,
      ctx,
      plan: 'DevPass ${plan![0].toUpperCase()}${plan.substring(1)}',
      source: 'api-key',
      windows: [
        if (limit > 0) quotaWindow('devpass-cycle', '套餐 Credits', usedPercent: pct(used, limit)),
        if (wLimit > 0)
          quotaWindow(
            RateWindow.weeklyId,
            'Premium 每周',
            usedPercent: pct(wUsed, wLimit),
            resetsAt: parseFlexibleDate(data['devPlanPremiumWeekResetsAt']),
            windowMinutes: 10080,
          ),
      ],
      credits: [
        spendRow('devpass-credits', used, limit: limit, label: '本周期 Credits'),
        keySpend,
      ],
    );
  }
}

// -------------------------------------------------------------------- xKiro

class XKiroProvider extends _Keyed {
  @override
  String get id => 'xkiro';
  @override
  String get displayName => 'xKiro';
  @override
  int get brandColor => 0xFF52C99B;
  @override
  List<String> get keyEnv => const ['XKIRO_API_KEY'];
  @override
  String get setupHint => 'xKiro 的 API Key，查询每日免费 token 额度（UTC 0 点重置）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.xkiro.com/v1/usage'),
      headers: bearer(account),
    );
    final free = asMap(json['free_tokens']);
    if (json['object'] != 'usage' || free == null) throw ProviderException('xKiro 返回了无法识别的用量');
    final used = asInt(free['used_today']);
    final limit = asInt(free['limit_per_day']);
    return snapshot(
      account,
      ctx,
      plan: json['plan'] == null ? 'Pay as you go' : asString(json['plan']),
      email: asString(asMap(json['user'])?['email']),
      source: 'api-key',
      windows: [
        if (used != null && limit != null)
          quotaWindow(
            'xkiro-daily',
            '每日免费 Token',
            usedPercent: limit == 0 ? 100 : pct(used, limit),
            resetsAt: nextUtcDay(ctx.now()),
            windowMinutes: 1440,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------- ai&

/// Exact decimal sum of `cost` strings, returned as a double only at the end.
double sumDecimalStrings(Iterable<String> values) {
  var coefficient = BigInt.zero;
  var scale = 0;
  for (final raw in values) {
    final m = RegExp(r'^([+-]?)(\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d+))?$').firstMatch(raw.trim());
    if (m == null) continue;
    final mantissa = m[2]!.replaceFirstMapped(RegExp(r'(\.\d*?)0+$'), (g) => g[1]!);
    final fraction = mantissa.contains('.') ? mantissa.split('.')[1].length : 0;
    final exponent = int.parse(m[3] ?? '0');
    final s = fraction - exponent;
    if (exponent.abs() > 127 || s > 128) continue;
    var c = BigInt.parse(
      '${m[1] == '-' ? '-' : ''}${mantissa.replaceFirst('.', '').isEmpty ? '0' : mantissa.replaceFirst('.', '')}',
    );
    var cs = s;
    if (cs < 0) {
      c *= BigInt.from(10).pow(-cs);
      cs = 0;
    }
    final target = cs > scale ? cs : scale;
    coefficient =
        coefficient * BigInt.from(10).pow(target - scale) + c * BigInt.from(10).pow(target - cs);
    scale = target;
  }
  return double.parse('${coefficient}e${-scale}');
}

class AiAndProvider extends _Keyed {
  @override
  String get id => 'aiand';
  @override
  String get displayName => 'ai&';
  @override
  int get brandColor => 0xFFE25C2B;
  @override
  List<String> get keyEnv => const ['AIAND_API_KEY'];
  @override
  String get setupHint => 'ai& 的 API Key，按请求日志汇总近 30 天花费。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    String? after, afterId, currency;
    final costs = <String>[];
    var complete = false;
    for (var page = 0; page < 10; page++) {
      var url = 'https://api.aiand.com/logs?range=30days&limit=100';
      if (after != null && afterId != null) {
        url +=
            '&after=${Uri.encodeQueryComponent(after)}&after_id=${Uri.encodeQueryComponent(afterId)}';
      }
      final r = await sendRequest(
        ctx,
        displayName,
        Uri.parse(url),
        headers: bearer(account),
        timeout: const Duration(seconds: 15),
      );
      if (r.statusCode == 402) {
        throw ProviderException('ai& 组织余额已用完，请到 console.aiand.com 充值', statusCode: 402);
      }
      final json = asMap(checkStatus(displayName, r).json);
      final rows = asList(json?['data']);
      if (rows == null) throw ProviderException('ai& 日志数据无法识别');
      after = asString(json!['next_after']);
      afterId = asString(json['next_after_id']);
      for (final row in rows.map(asMap).whereType<Map<String, Object?>>()) {
        final cost = asString(row['cost']);
        final code = asString(row['currency'])?.trim().toUpperCase();
        if (cost == null || code == null || code.isEmpty) continue;
        currency ??= code;
        if (code == currency) costs.add(cost);
      }
      if (json['has_more'] != true) {
        complete = true;
        break;
      }
      if (after == null || afterId == null) break;
    }
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [
        if (currency != null)
          spendRow(
            'aiand-30d',
            sumDecimalStrings(costs),
            label: complete ? '近 30 天花费' : '近 30 天花费（不完整）',
            currency: currency,
          ),
      ],
    );
  }
}

// --------------------------------------------------------------------- Groq

String _rate(double v) => v.toStringAsFixed(v >= 100 ? 0 : (v >= 10 ? 1 : 2));

class GroqProvider extends _Keyed {
  @override
  String get id => 'groq';
  @override
  String get displayName => 'Groq';
  @override
  int get brandColor => 0xFFF56844;
  @override
  List<String> get keyEnv => const ['GROQ_API_KEY'];
  @override
  String get setupHint =>
      'Groq 的 API Key，通过官方 Prometheus 指标接口查看最近 5 分钟的请求 / token 速率（Groq 不公开额度余量）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    Future<double> query(String promql) async {
      final json = await fetchJsonObject(
        ctx,
        displayName,
        Uri.https('api.groq.com', '/v1/metrics/prometheus/api/v1/query', {'query': promql}),
        headers: bearer(account),
      );
      final result = asList(asMap(json['data'])?['result']);
      if (json['status'] != 'success' || result == null) throw ProviderException('Groq 指标数据无法识别');
      var total = 0.0;
      for (final s in result.map(asMap)) {
        final v = asList(s?['value']);
        final n = v != null && v.length == 2 ? _num(v[1]) : null;
        if (n == null || n < 0 || !n.isFinite) throw ProviderException('Groq 指标数据无法识别');
        total += n;
      }
      return total;
    }

    final rates = await Future.wait([
      query('sum(model_project_id_status_code:requests:rate5m)'),
      query('sum(model_project_id:tokens_in:rate5m)'),
      query('sum(model_project_id:tokens_out:rate5m)'),
      query('sum(model_project_id:prompt_cache_hits:rate5m)'),
    ]);
    final cache = rates[3] * 60;
    return snapshot(
      account,
      ctx,
      plan: 'Prometheus 指标',
      source: 'api-key',
      extras: {
        '请求速率': '${_rate(rates[0] * 60)} 次/分钟',
        'Token 速率': '${_rate((rates[1] + rates[2]) * 60)} tok/分钟',
        if (cache > 0) '缓存命中': '${_rate(cache)} 次/分钟',
      },
    );
  }
}
