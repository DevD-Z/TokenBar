import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

final _slugPattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// Account slugs from `/v1/accounts` (`accounts/foo` -> `foo`).
Set<String> parseFireworksSlugs(Map<String, Object?> json) {
  final slugs = <String>{};
  for (final a
      in (asList(json['accounts']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
    final raw = asString(a['accountId']) ?? asString(a['id']) ?? asString(a['name']);
    final slug = raw?.split('/').last.trim();
    if (slug != null && _slugPattern.hasMatch(slug) && slug != '.' && slug != '..') slugs.add(slug);
  }
  return slugs;
}

/// Total of rated line items in the first item's currency.
({double total, String currency})? parseFireworksSpend(Map<String, Object?> json) {
  String? currency;
  var total = 0.0;
  for (final item
      in (asList(json['lineItems']) ?? const []).map(asMap).whereType<Map<String, Object?>>()) {
    final cost = asMap(item['totalCost']);
    final units = double.tryParse(asString(cost?['units']) ?? '');
    final nanos = asInt(cost?['nanos']);
    final code = asString(cost?['currencyCode']);
    if (units == null || nanos == null || code == null || !units.isFinite) continue;
    currency ??= code;
    if (code == currency) total += units + nanos / 1e9;
  }
  return currency == null ? null : (total: total, currency: currency);
}

class FireworksProvider extends UsageProvider {
  static const _host = 'https://api.fireworks.ai';

  @override
  String get id => 'fireworks';

  @override
  String get displayName => 'Fireworks AI';

  @override
  int get brandColor => 0xFFF25B1C;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => 'app.fireworks.ai 的 API Key，查询近 30 天花费。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(envVars: ['FIREWORKS_API_KEY', 'FIREWORKS_KEY']),
    ProviderField(
      key: 'accountSlug',
      label: '账户 slug',
      kind: FieldKind.text,
      required: false,
      help: '留空自动识别；Key 能访问多个账户时需要填写',
      envVars: ['FIREWORKS_ACCOUNT_SLUG'],
    ),
  ];

  @override
  String? validateManual(FieldValues values) {
    final slug = values['accountSlug'];
    return slug == null || _slugPattern.hasMatch(slug) ? null : '账户 slug 只能包含字母、数字、点、下划线和连字符';
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final headers = {'Authorization': 'Bearer ${bareToken(values.secret)}'};
    Future<Map<String, Object?>> get(String pathAndQuery) => fetchJsonObject(
      ctx,
      displayName,
      Uri.parse('$_host$pathAndQuery'),
      headers: headers,
      authHint: 'Fireworks 拒绝了 API Key，请在 app.fireworks.ai 重新创建',
      timeout: const Duration(seconds: 15),
    );

    var slug = values['accountSlug'];
    if (slug == null) {
      final slugs = <String>{};
      String? token;
      final seen = <String>{};
      for (var i = 0; i < 100; i++) {
        final page = await get(
          '/v1/accounts${token == null ? '' : '?pageToken=${Uri.encodeQueryComponent(token)}'}',
        );
        slugs.addAll(parseFireworksSlugs(page));
        token = asString(page['nextPageToken']);
        if (token == null || !seen.add(token)) break;
      }
      if (slugs.isEmpty) throw ProviderException('这个 Fireworks Key 没有可访问的账户');
      if (slugs.length > 1) {
        throw ProviderException(
          '这个 Key 能访问多个账户：${(slugs.toList()..sort()).join(', ')}',
          hint: '在账户设置中填写账户 slug',
        );
      }
      slug = slugs.single;
    }
    final now = ctx.now().toUtc();
    String iso(DateTime t) => '${t.toIso8601String().split('.').first.replaceAll('Z', '')}Z';
    final summary = await get(
      '/v1/accounts/${Uri.encodeComponent(slug)}/billing/summary'
      '?startTime=${Uri.encodeQueryComponent(iso(now.subtract(const Duration(days: 30))))}'
      '&endTime=${Uri.encodeQueryComponent(iso(now))}',
    );
    final spend = parseFireworksSpend(summary);
    return snapshot(
      account,
      ctx,
      plan: slug,
      source: 'api-key',
      credits: [
        spendRow(
          'fireworks-spend',
          spend?.total ?? 0,
          label: '近 30 天花费',
          currency: spend?.currency ?? 'USD',
        ),
      ],
    );
  }
}
