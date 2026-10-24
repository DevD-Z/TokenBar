import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

abstract class _SingleKeyProvider extends UsageProvider {
  List<String> get keyEnv;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  List<ProviderField> get fields => [ProviderField.apiKey(envVars: keyEnv)];

  Map<String, String> bearer(AccountConfig account) => {
    'Authorization': 'Bearer ${bareToken(FieldValues.of(this, account).secret)}',
  };
}

UsageSnapshot parseTavily(UsageSnapshot base, Map<String, Object?> json) {
  final account = asMap(json['account']);
  final key = asMap(json['key']);
  final planUsage = asInt(account?['plan_usage']);
  final planLimit = asInt(account?['plan_limit']);
  final keyUsage = asInt(key?['usage']);
  if (planUsage == null ||
      planLimit == null ||
      keyUsage == null ||
      !(key?.containsKey('limit') ?? false)) {
    throw ProviderException('Tavily 返回了无法识别的额度数据');
  }
  final keyLimit = asInt(key!['limit']);
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    plan: asString(account!['current_plan']) ?? 'API key',
    source: 'api-key',
    windows: [
      if (planLimit > 0)
        quotaWindow('tavily-plan', '套餐 Credits', usedPercent: pct(planUsage, planLimit)),
      if (keyLimit != null && keyLimit > 0)
        quotaWindow('tavily-key', '当前 Key', usedPercent: pct(keyUsage, keyLimit)),
    ],
    extras: {
      '套餐用量': '$planUsage / $planLimit credits',
      'Key 用量': keyLimit == null ? '$keyUsage credits（不限）' : '$keyUsage / $keyLimit credits',
      if (account['paygo_usage'] != null) '按量付费': '${account['paygo_usage']} credits',
    },
  );
}

class TavilyProvider extends _SingleKeyProvider {
  @override
  String get id => 'tavily';
  @override
  String get displayName => 'Tavily';
  @override
  int get brandColor => 0xFF78B0A1;
  @override
  List<String> get keyEnv => const ['TAVILY_API_KEY'];
  @override
  String get setupHint => 'app.tavily.com 的 API Key，查询套餐与 Key 的 credits 用量（接口限流 10 次 / 10 分钟）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.tavily.com/usage'),
      headers: bearer(account),
    );
    return parseTavily(snapshot(account, ctx), json);
  }
}

class LinkupProvider extends _SingleKeyProvider {
  @override
  String get id => 'linkup';
  @override
  String get displayName => 'Linkup';
  @override
  int get brandColor => 0xFF202020;
  @override
  List<String> get keyEnv => const ['LINKUP_API_KEY'];
  @override
  String get setupHint => 'app.linkup.so 的 API Key，查询预付 credits 余额（美元）。';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final json = await fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.linkup.so/v1/credits/balance'),
      headers: bearer(account),
    );
    final balance = json['balance'];
    if (balance is! num || !balance.isFinite) throw ProviderException('Linkup 返回了无法识别的余额');
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [balanceRow('linkup-balance', balance.toDouble(), label: 'Credits 余额')],
    );
  }
}
