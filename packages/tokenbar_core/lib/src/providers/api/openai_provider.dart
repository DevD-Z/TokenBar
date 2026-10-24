import '../../models/account.dart';
import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

/// Sum of `results[].amount.value` (USD) across cost buckets.
double sumOpenAiCosts(Iterable<Map<String, Object?>> pages) {
  var total = 0.0;
  for (final page in pages) {
    for (final bucket
        in (asList(page['data']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
      for (final r
          in (asList(bucket['results']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
        total += asDouble(asMap(r['amount'])?['value']) ?? 0;
      }
    }
  }
  return total;
}

/// Legacy `credit_grants` balance: window + credits row.
({RateWindow window, Credits credits}) parseOpenAiCreditGrants(
  Map<String, Object?> json,
  DateTime now,
) {
  final granted = json['total_granted'];
  final used = json['total_used'];
  final available = json['total_available'];
  if (granted is! num || used is! num || available is! num) {
    throw ProviderException('OpenAI 余额数据格式无法识别');
  }
  DateTime? expires;
  final grants = asList(asMap(json['grants'])?['data']) ?? const [];
  for (final g in grants.map(asMap).whereType<Map<String, Object?>>()) {
    final at = epochSeconds(asInt(g['expires_at']));
    if (at != null && at.isAfter(now) && (expires == null || at.isBefore(expires))) expires = at;
  }
  final usedPercent = granted > 0 ? used / granted * 100 : (available > 0 ? 0.0 : 100.0);
  return (
    window: quotaWindow(
      'openai-credits',
      'API 额度',
      usedPercent: usedPercent.toDouble(),
      resetsAt: expires,
    ),
    credits: Credits(
      id: 'openai-credits',
      label: 'API 额度',
      used: used < 0 ? 0 : used.toDouble(),
      limit: granted < 0 ? 0 : granted.toDouble(),
      balance: available.toDouble(),
      currency: 'USD',
      resetsAt: expires,
    ),
  );
}

class OpenAiProvider extends UsageProvider {
  static const _host = 'https://api.openai.com';
  static const historyDays = 30;

  @override
  String get id => 'openai';

  @override
  String get displayName => 'OpenAI API';

  @override
  int get brandColor => 0xFF0F826E;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '使用组织 Admin API Key（sk-admin-...）查询近 30 天花费；普通 Key 会尝试旧版余额接口。'
      '在 platform.openai.com → Settings → Admin keys 创建。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: 'Admin API Key',
      hint: 'sk-admin-...',
      envVars: ['OPENAI_ADMIN_KEY', 'OPENAI_API_KEY'],
    ),
    ProviderField(
      key: 'projectId',
      label: '项目 ID',
      kind: FieldKind.text,
      required: false,
      hint: 'proj_...',
      help: '只统计某个项目的花费',
      envVars: ['OPENAI_PROJECT_ID'],
    ),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final key = bareToken(values.secret);
    final project = values['projectId'];
    final headers = {'Authorization': 'Bearer $key'};
    try {
      final total = await _costs(ctx, headers, project);
      return snapshot(
        account,
        ctx,
        plan: project == null ? 'Admin API' : 'Admin API: $project',
        source: 'admin-api',
        credits: [spendRow('openai-spend', total, label: '近 $historyDays 天花费')],
      );
    } on ProviderException catch (usageError) {
      if (project != null && key.startsWith('sk-admin')) rethrow;
      try {
        final grants = parseOpenAiCreditGrants(
          await fetchJsonObject(
            ctx,
            displayName,
            Uri.parse('$_host/v1/dashboard/billing/credit_grants'),
            headers: headers,
            authHint: '查询用量需要组织 Admin API Key；项目 Key 无法读取组织用量',
          ),
          ctx.now(),
        );
        return snapshot(
          account,
          ctx,
          source: 'billing-api',
          windows: [grants.window],
          credits: [grants.credits],
        );
      } on ProviderException {
        if (usageError.statusCode == 401 || usageError.statusCode == 403) {
          throw ProviderException(
            usageError.message,
            hint: '查询用量需要组织 Admin API Key（sk-admin-...）',
            statusCode: usageError.statusCode,
          );
        }
        rethrow;
      }
    }
  }

  Future<double> _costs(FetchContext ctx, Map<String, String> headers, String? project) async {
    final now = ctx.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: historyDays - 1));
    final pages = <Map<String, Object?>>[];
    String? page;
    final seen = <String>{};
    for (var i = 0; i < 100; i++) {
      final query = [
        'start_time=${start.millisecondsSinceEpoch ~/ 1000}',
        'end_time=${start.add(const Duration(days: historyDays)).millisecondsSinceEpoch ~/ 1000}',
        'bucket_width=1d',
        'limit=$historyDays',
        'group_by=line_item',
        if (project != null) 'project_ids=${Uri.encodeQueryComponent(project)}',
        if (page != null) 'page=${Uri.encodeQueryComponent(page)}',
      ].join('&');
      final json = await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('$_host/v1/organization/costs?$query'),
        headers: headers,
        authHint: '需要组织 Admin API Key（sk-admin-...）',
      );
      pages.add(json);
      final next = asString(json['next_page']);
      if (json['has_more'] != true || next == null || !seen.add(next)) break;
      page = next;
    }
    return sumOpenAiCosts(pages);
  }
}
