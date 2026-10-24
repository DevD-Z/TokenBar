import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

class DeepSeekBalance {
  DeepSeekBalance({
    required this.available,
    required this.currency,
    required this.total,
    this.granted,
    this.toppedUp,
  });

  final bool available;
  final String currency;
  final double total;
  final double? granted;
  final double? toppedUp;
}

/// Currency preference used by CodexBar: USD with a positive total, any
/// positive total, USD, then the first entry.
T? _preferCurrency<T>(List<T> items, String Function(T) currency, double Function(T) total) {
  if (items.isEmpty) return null;
  return items.where((i) => currency(i) == 'USD' && total(i) > 0).firstOrNull ??
      items.where((i) => total(i) > 0).firstOrNull ??
      items.where((i) => currency(i) == 'USD').firstOrNull ??
      items.first;
}

DeepSeekBalance parseDeepSeekBalance(Map<String, Object?> json) {
  final infos = (asList(json['balance_infos']) ?? const [])
      .map(asMap)
      .whereType<Map<String, Object?>>()
      .toList();
  final pick = _preferCurrency(
    infos,
    (i) => (asString(i['currency']) ?? '').toUpperCase(),
    (i) => asDouble(i['total_balance']) ?? 0,
  );
  if (pick == null) return DeepSeekBalance(available: false, currency: 'USD', total: 0);
  return DeepSeekBalance(
    available: asBool(json['is_available']) ?? false,
    currency: (asString(pick['currency']) ?? 'USD').toUpperCase(),
    total: asDouble(pick['total_balance']) ?? 0,
    granted: asDouble(pick['granted_balance']),
    toppedUp: asDouble(pick['topped_up_balance']),
  );
}

DeepSeekBalance parseDeepSeekUserSummary(Map<String, Object?> json) {
  final data = asMap(json['data']);
  if (asInt(json['code']) != 0 || data == null || asInt(data['biz_code']) != 0) {
    throw ProviderException('DeepSeek 平台会话无效', hint: '重新复制 platform.deepseek.com 的 userToken');
  }
  final biz = asMap(data['biz_data']) ?? const {};
  final paid = <String, double>{};
  final bonus = <String, double>{};
  void sum(Object? wallets, Map<String, double> into) {
    for (final w in (asList(wallets) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
      final cur = (asString(w['currency']) ?? 'CNY').toUpperCase();
      into[cur] = (into[cur] ?? 0) + (asDouble(w['balance']) ?? 0);
    }
  }

  sum(biz['normal_wallets'], paid);
  sum(biz['bonus_wallets'], bonus);
  final currencies = {...paid.keys, ...bonus.keys}.toList()..sort();
  double total(String c) => (paid[c] ?? 0) + (bonus[c] ?? 0);
  final cur = _preferCurrency(currencies, (c) => c, total) ?? 'USD';
  return DeepSeekBalance(
    available: total(cur) > 0,
    currency: cur,
    total: total(cur),
    granted: bonus[cur] ?? 0,
    toppedUp: paid[cur] ?? 0,
  );
}

class DeepSeekProvider extends UsageProvider {
  @override
  String get id => 'deepseek';

  @override
  String get displayName => 'DeepSeek';

  @override
  int get brandColor => 0xFF4D6BFE;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => '在 platform.deepseek.com 创建 API Key，查询账户余额。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      envVars: ['DEEPSEEK_API_KEY', 'DEEPSEEK_KEY'],
      required: false,
      hint: 'sk-...',
    ),
    ProviderField(
      key: 'platformToken',
      label: '平台 userToken',
      required: false,
      help: '不填 API Key 时使用：platform.deepseek.com 登录后浏览器 localStorage 中的 userToken',
      envVars: ['DEEPSEEK_PLATFORM_TOKEN', 'DEEPSEEK_USER_TOKEN'],
    ),
  ];

  @override
  String get manualSourceLabel => 'API Key';

  @override
  String? validateManual(FieldValues values) =>
      values[ProviderField.secretKey] == null && values['platformToken'] == null
      ? '请填写 API Key 或平台 userToken'
      : null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final key = values[ProviderField.secretKey];
    final token = values['platformToken'];
    DeepSeekBalance balance;
    String source;
    if (key != null) {
      balance = parseDeepSeekBalance(
        await fetchJsonObject(
          ctx,
          displayName,
          Uri.parse('https://api.deepseek.com/user/balance'),
          headers: {'Authorization': 'Bearer ${bareToken(key)}'},
          authHint: '检查 DeepSeek API Key',
          timeout: const Duration(seconds: 15),
        ),
      );
      source = 'api-key';
    } else if (token != null) {
      balance = parseDeepSeekUserSummary(
        await fetchJsonObject(
          ctx,
          displayName,
          Uri.parse('https://platform.deepseek.com/api/v0/users/get_user_summary'),
          headers: {'Authorization': 'Bearer ${bareToken(token)}', 'x-client-platform': 'web'},
          authHint: '重新复制 platform.deepseek.com 的 userToken',
          timeout: const Duration(seconds: 15),
        ),
      );
      source = 'web';
    } else {
      throw ProviderException('未填写 DeepSeek API Key', hint: '在账户设置中填写，或设置环境变量 DEEPSEEK_API_KEY');
    }
    return snapshot(
      account,
      ctx,
      source: source,
      credits: [
        balanceRow('deepseek-balance', balance.total, currency: balance.currency),
        if (balance.toppedUp != null)
          balanceRow('deepseek-paid', balance.toppedUp!, label: '充值余额', currency: balance.currency),
        if (balance.granted != null)
          balanceRow(
            'deepseek-granted',
            balance.granted!,
            label: '赠送余额',
            currency: balance.currency,
          ),
      ],
      extras: {
        if (balance.total <= 0)
          '状态': '余额为 0，请到 platform.deepseek.com 充值'
        else if (!balance.available)
          '状态': '余额暂不可用于 API 调用',
      },
    );
  }
}
