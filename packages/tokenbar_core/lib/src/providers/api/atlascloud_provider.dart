import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

double parseAtlasCloudBalance(Map<String, Object?> json) {
  final available = asMap(json['available']);
  final value = available?['value'];
  if (json['object'] != 'balance' ||
      json['scope'] != 'account' ||
      available?['currency'] != 'usd' ||
      value is! String ||
      !RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(value)) {
    throw ProviderException('Atlas Cloud 返回了无法识别的余额');
  }
  return double.parse(value);
}

class AtlasCloudProvider extends UsageProvider {
  @override
  String get id => 'atlascloud';

  @override
  String get displayName => 'Atlas Cloud';

  @override
  int get brandColor => 0xFF5975F5;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => '需要有账户余额读取权限的 Atlas Cloud API Key（所有者或财务角色）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(envVars: ['ATLASCLOUD_API_KEY']),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final key = FieldValues.of(this, account).secret;
    final balance = parseAtlasCloudBalance(
      await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('https://api.atlascloud.ai/public/v1/balance'),
        headers: {'Authorization': 'Bearer ${bareToken(key)}'},
        timeout: const Duration(seconds: 15),
      ),
    );
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [balanceRow('atlascloud-balance', balance, label: '可用余额')],
    );
  }
}
