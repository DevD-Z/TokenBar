import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

final _decimal = RegExp(r'^-?\d+(?:\.\d+)?$');

({double balance, double used}) parseVercelCredits(Map<String, Object?> json) {
  final balance = json['balance'];
  final used = json['total_used'];
  if (balance is! String ||
      used is! String ||
      !_decimal.hasMatch(balance) ||
      !_decimal.hasMatch(used)) {
    throw ProviderException('Vercel AI Gateway 返回了无法识别的余额');
  }
  return (balance: double.parse(balance), used: double.parse(used));
}

/// The active personal budget of [userId], or null when none is configured.
Map<String, Object?>? pickVercelBudget(List<Map<String, Object?>> budgets, String userId) {
  final matches = budgets.where((b) {
    final scope = asString(b['scopeId']);
    return b['scopeType'] == 'user' &&
        (scope == userId || scope == 'usr_$userId') &&
        b['active'] == true &&
        b['archived'] != true;
  }).toList();
  final custom = matches.where((b) => b['source'] != 'default').toList();
  final effective = custom.isNotEmpty ? custom : matches;
  if (effective.length > 1) throw ProviderException('Vercel 返回了多个个人预算，无法确定');
  return effective.firstOrNull;
}

RateWindow vercelBudgetWindow(Map<String, Object?> budget, DateTime now) {
  final limit = asDouble(budget['limitAmount']) ?? 0;
  final spent = asDouble(budget['currentSpend']) ?? 0;
  final u = now.toUtc();
  final (DateTime? reset, int? minutes) = switch (budget['refreshPeriod']) {
    'daily' => (nextUtcDay(u), 1440),
    'weekly' => (DateTime.utc(u.year, u.month, u.day + (8 - u.weekday)), 10080),
    'monthly' => (nextUtcMonth(u), nextUtcMonth(u).difference(startOfUtcMonth(u)).inMinutes),
    _ => (null, null),
  };
  return quotaWindow(
    'vercel-budget',
    '个人预算',
    usedPercent: pct(spent, limit),
    resetsAt: reset,
    windowMinutes: minutes,
  );
}

class VercelProvider extends UsageProvider {
  @override
  String get id => 'vercel';

  @override
  String get displayName => 'Vercel AI Gateway';

  @override
  int get brandColor => 0xFF111111;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '团队余额：填 AI Gateway API Key。个人预算：改填 Vercel Access Token + 团队 ID（填了 Token 时优先显示个人预算）。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: 'AI Gateway API Key',
      required: false,
      envVars: ['AI_GATEWAY_API_KEY'],
    ),
    ProviderField(
      key: 'accessToken',
      label: 'Vercel Access Token',
      required: false,
      help: '用于查询个人预算',
      envVars: ['VERCEL_ACCESS_TOKEN'],
    ),
    ProviderField(
      key: 'teamId',
      label: '团队 ID',
      kind: FieldKind.text,
      required: false,
      envVars: ['VERCEL_TEAM_ID'],
    ),
  ];

  @override
  String? validateManual(FieldValues values) {
    if (values['accessToken'] != null) {
      final team = values['teamId'];
      if (team == null) return '使用 Access Token 时需要填写团队 ID';
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(team)) return '团队 ID 格式无效';
      return null;
    }
    return values[ProviderField.secretKey] == null
        ? '请填写 AI Gateway API Key，或 Access Token + 团队 ID'
        : null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final token = values['accessToken'];
    if (token != null) return _budget(account, ctx, bareToken(token), values.require('teamId'));
    final key = values[ProviderField.secretKey];
    if (key == null) throw ProviderException('未填写 Vercel AI Gateway API Key', hint: '在账户设置中填写');
    final credits = parseVercelCredits(
      await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('https://ai-gateway.vercel.sh/v1/credits'),
        headers: {'Authorization': 'Bearer ${bareToken(key)}'},
      ),
    );
    return snapshot(
      account,
      ctx,
      source: 'api-key',
      credits: [
        balanceRow('vercel-balance', credits.balance, label: '团队余额'),
        spendRow('vercel-used', credits.used, label: '累计花费'),
      ],
    );
  }

  Future<UsageSnapshot> _budget(
    AccountConfig account,
    FetchContext ctx,
    String token,
    String team,
  ) async {
    final headers = {'Authorization': 'Bearer $token'};
    final user = asMap(
      (await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('https://api.vercel.com/v2/user'),
        headers: headers,
      ))['user'],
    );
    final userId = asString(user?['id']);
    if (userId == null) throw ProviderException('Vercel 返回了无法识别的用户信息');
    final budgets = <Map<String, Object?>>[];
    String? cursor;
    final seen = <String>{};
    for (var i = 0; i < 20; i++) {
      final page = await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse(
          'https://api.vercel.com/ai-gateway/budgets/list?teamId=${Uri.encodeQueryComponent(team)}'
          '&scopeType=user&limit=200${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
        ),
        headers: headers,
      );
      budgets.addAll(
        (asList(page['budgets']) ?? const []).map(asMap).whereType<Map<String, Object?>>(),
      );
      cursor = asString(page['nextCursor']);
      if (cursor == null || !seen.add(cursor)) break;
    }
    final budget = pickVercelBudget(budgets, userId);
    final email = asString(user?['email']);
    if (budget == null) {
      return snapshot(
        account,
        ctx,
        email: email,
        source: 'access-token',
        extras: const {'个人预算': '未设置'},
      );
    }
    final limit = asDouble(budget['limitAmount']) ?? 0;
    final spent = asDouble(budget['currentSpend']) ?? 0;
    final window = vercelBudgetWindow(budget, ctx.now());
    return snapshot(
      account,
      ctx,
      email: email,
      plan: team,
      source: 'access-token',
      windows: [window],
      credits: [
        spendRow('vercel-budget', spent, limit: limit, label: '个人预算', resetsAt: window.resetsAt),
      ],
    );
  }
}
