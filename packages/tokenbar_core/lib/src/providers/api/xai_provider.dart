import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

/// Prepaid balance from `total.val`: signed cents on an inverted ledger.
double parseXaiBalance(Map<String, Object?> json) {
  final val = asString(asMap(json['total'])?['val']);
  if (val == null || !RegExp(r'^-?\d+(\.\d+)?$').hasMatch(val)) {
    throw ProviderException('xAI 账单数据无法解析：余额不是金额');
  }
  return -double.parse(val) / 100;
}

/// `coreInvoice.amountAfterVat` in signed integer cents, or null.
double? parseXaiInvoiceCents(Map<String, Object?> json) {
  final raw = asString(asMap(json['coreInvoice'])?['amountAfterVat']);
  if (raw == null || !RegExp(r'^-?\d+$').hasMatch(raw)) return null;
  final cents = int.tryParse(raw);
  if (cents == null || cents.abs() > 9007199254740991) return null;
  return cents / 100;
}

class XaiProvider extends UsageProvider {
  @override
  String get id => 'xai';

  @override
  String get displayName => 'xAI';

  @override
  int get brandColor => 0xFF8E8E93;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '需要 xAI Console → Settings → Management Keys 创建的管理密钥（推理 API Key 不行）和团队 ID。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(label: 'Management API Key', envVars: ['XAI_MANAGEMENT_API_KEY']),
    ProviderField(
      key: 'teamId',
      label: '团队 ID',
      kind: FieldKind.text,
      help: 'xAI Console 地址栏或团队设置中可见',
      envVars: ['XAI_TEAM_ID'],
    ),
  ];

  @override
  String? validateManual(FieldValues values) {
    final team = values['teamId'];
    return team != null && (team.contains('/') || team == '.' || team == '..')
        ? '团队 ID 不能包含路径分隔符'
        : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final team = values.require('teamId');
    final root = 'https://management-api.x.ai/v1/billing/teams/${Uri.encodeComponent(team)}';
    final headers = {'Authorization': 'Bearer ${bareToken(values.secret)}'};
    final result = await sendRequest(
      ctx,
      displayName,
      Uri.parse('$root/prepaid/balance'),
      headers: headers,
    );
    if (result.statusCode == 404) {
      throw ProviderException('xAI 找不到这个团队 (HTTP 404)', hint: '检查团队 ID，以及管理密钥是否属于同一团队');
    }
    checkStatus(displayName, result, authHint: '需要 Management API Key，推理 API Key 不被接受');
    final balance = parseXaiBalance(asMap(result.json) ?? const {});
    double? live;
    try {
      final preview = await sendRequest(
        ctx,
        displayName,
        Uri.parse('$root/postpaid/invoice/preview'),
        headers: headers,
        timeout: const Duration(seconds: 5),
      );
      final cents = preview.ok ? parseXaiInvoiceCents(asMap(preview.json) ?? const {}) : null;
      if (cents != null) live = balance - cents;
    } on ProviderException {
      live = null;
    }
    return snapshot(
      account,
      ctx,
      plan: 'Management API',
      source: 'api-key',
      credits: [
        balanceRow('xai-prepaid', balance, label: '预付余额'),
        if (live != null) balanceRow('xai-live', live, label: '实时剩余（估算）'),
      ],
    );
  }
}
