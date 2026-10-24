import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

class MoonshotBalance {
  MoonshotBalance(this.available, this.cash, this.voucher);

  final double available;
  final double cash;
  final double voucher;
}

MoonshotBalance parseMoonshotBalance(Map<String, Object?> json) {
  final data = asMap(json['data']);
  if (asInt(json['code']) != 0 || json['status'] != true || data == null) {
    throw ProviderException('Moonshot 接口错误: code ${json['code']}, scode ${json['scode']}');
  }
  double field(String k) {
    final v = data[k];
    if (v is! num) throw ProviderException('Moonshot 返回数据缺少 $k');
    return v.toDouble();
  }

  return MoonshotBalance(
    field('available_balance'),
    field('cash_balance'),
    field('voucher_balance'),
  );
}

class MoonshotProvider extends UsageProvider {
  @override
  String get id => 'moonshot';

  @override
  String get displayName => 'Moonshot / Kimi 开放平台';

  @override
  int get brandColor => 0xFF205DEB;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => 'platform.moonshot.cn / platform.moonshot.ai 的 API Key，查询账户余额。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(envVars: ['MOONSHOT_API_KEY', 'MOONSHOT_KEY']),
    ProviderField(
      key: 'region',
      label: '区域',
      kind: FieldKind.choice,
      defaultValue: 'china',
      choices: [
        FieldChoice('china', '中国站 api.moonshot.cn'),
        FieldChoice('international', '国际站 api.moonshot.ai'),
      ],
      envVars: ['MOONSHOT_REGION'],
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final china = values['region'] == 'china';
    final balance = parseMoonshotBalance(
      await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse(
          '${china ? 'https://api.moonshot.cn' : 'https://api.moonshot.ai'}/v1/users/me/balance',
        ),
        headers: {'Authorization': 'Bearer ${bareToken(values.secret)}'},
        authHint: '检查 API Key 与所选区域是否一致',
        timeout: const Duration(seconds: 15),
      ),
    );
    final currency = china ? 'CNY' : 'USD';
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [
        balanceRow('moonshot-balance', balance.available, label: '可用余额', currency: currency),
        balanceRow('moonshot-cash', balance.cash, label: '现金余额', currency: currency),
        balanceRow('moonshot-voucher', balance.voucher, label: '代金券余额', currency: currency),
      ],
      extras: {if (balance.cash < 0) '欠费': moneyText(balance.cash.abs(), currency)},
    );
  }
}
