import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

/// DeepInfra checklist + monthly usage. Negative balance = prepaid funds.
UsageSnapshot parseDeepInfra(
  UsageSnapshot base,
  Map<String, Object?> checklist,
  Map<String, Object?> usage,
) {
  final stripe = checklist['stripe_balance'];
  final recentRaw = checklist['recent'];
  if (stripe is! num || recentRaw is! num) throw ProviderException('DeepInfra 账单数据格式无法识别');
  final recent = recentRaw < 0 ? 0.0 : recentRaw.toDouble();
  final balance = stripe + recent;
  final limit = asDouble(checklist['limit']);
  final suspended = checklist['suspended'] == true;
  final months = asList(usage['months']) ?? const [];
  final lastMonth = months.isEmpty ? null : asMap(months.last);
  final monthCost = lastMonth == null
      ? recent
      : ((asDouble(lastMonth['total_cost']) ?? 0) / 100).clamp(0, double.infinity);
  final reason = asString(checklist['suspend_reason']);
  return UsageSnapshot(
    accountId: base.accountId,
    providerId: base.providerId,
    fetchedAt: base.fetchedAt,
    source: 'api-key',
    windows: [
      if (limit != null && limit > 0)
        quotaWindow('deepinfra-limit', '消费上限', usedPercent: pct(recent, limit)),
    ],
    credits: [
      balance > 0
          ? spendRow('deepinfra-owed', balance.toDouble(), label: '待支付')
          : balanceRow('deepinfra-balance', -balance.toDouble(), label: '可用余额'),
      spendRow('deepinfra-month', monthCost.toDouble(), label: '本月花费', limit: limit),
    ],
    extras: {if (suspended) '状态': reason == null ? '已暂停' : '已暂停：$reason'},
  );
}

class DeepInfraProvider extends UsageProvider {
  @override
  String get id => 'deepinfra';

  @override
  String get displayName => 'DeepInfra';

  @override
  int get brandColor => 0xFF2A3275;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => 'deepinfra.com 的 API Token，查询余额、本月花费和消费上限。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(envVars: ['DEEPINFRA_API_KEY', 'DEEPINFRA_TOKEN']),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final key = FieldValues.of(this, account).secret;
    final headers = {'Authorization': 'Bearer ${bareToken(key)}'};
    Future<Map<String, Object?>> get(String path) => fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('https://api.deepinfra.com$path'),
      headers: headers,
      timeout: const Duration(seconds: 30),
    );
    final results = await Future.wait([
      get('/payment/checklist?compute_owed=true'),
      get('/payment/usage?from=current'),
    ]);
    return parseDeepInfra(snapshot(account, ctx), results[0], results[1]);
  }
}
