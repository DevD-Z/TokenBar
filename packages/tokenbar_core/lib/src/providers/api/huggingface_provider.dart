import '../../models/account.dart';
import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

/// Month-to-date inference spend (nano-USD) -> billable credits row.
Credits parseHuggingFaceUsage(Map<String, Object?> json) {
  final ip = asMap(asMap(json['usage'])?['inferenceProviders']);
  final used = asDouble(ip?['usedNanoUsd']);
  final included = asDouble(ip?['includedNanoUsd']);
  if (used == null || included == null) throw ProviderException('Hugging Face 账单数据格式已变化');
  final billable = (used - included) / 1e9;
  final limit = (asDouble(ip?['limitNanoUsd']) ?? 0) / 1e9;
  return spendRow(
    'huggingface-inference',
    billable < 0 ? 0 : billable,
    limit: limit,
    label: '本月推理花费',
  );
}

/// ZeroGPU seconds quota -> window, or null when there is no quota.
RateWindow? parseHuggingFaceZeroGpu(Map<String, Object?> json) {
  final base = asDouble(json['base']);
  final current = asDouble(json['current']);
  if (base == null || base <= 0 || current == null) return null;
  final consumed = (base - current).clamp(0, base);
  return quotaWindow(
    'huggingface-zerogpu',
    'ZeroGPU',
    usedPercent: pct(consumed, base),
    resetsAt: parseFlexibleDate(json['resetsAt']),
  );
}

class HuggingFaceProvider extends UsageProvider {
  static const _host = 'https://huggingface.co';

  @override
  String get id => 'huggingface';

  @override
  String get displayName => 'Hugging Face';

  @override
  int get brandColor => 0xFFFFD21E;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint =>
      '需要带 Billing 读取权限的 Access Token（classic read token 或细粒度 token 勾选 Billing read）。桌面端会读取 `hf auth login` 保存的 token。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(
      label: 'Access Token',
      hint: 'hf_...',
      required: false,
      help: '桌面端留空时读取 hf auth login 保存的 token',
      envVars: ['HF_TOKEN', 'HUGGING_FACE_HUB_TOKEN'],
    ),
  ];

  @override
  Future<SourceType?> detectLocalSetup(AccountConfig candidate) async =>
      FieldValues.envValue(fields.first) != null || await _tokenFile() != null
      ? SourceType.apiKey
      : null;

  static Future<String?> _tokenFile() async {
    if (!platform.localAccessSupported) return null;
    final home = platform.homeDirectory();
    final explicit = platform.envVar('HF_TOKEN_PATH');
    final hfHome = platform.envVar('HF_HOME');
    final xdg = platform.envVar('XDG_CACHE_HOME');
    final path = explicit != null
        ? (explicit.startsWith('~') && home != null ? '$home${explicit.substring(1)}' : explicit)
        : hfHome != null
        ? platform.joinPath(hfHome, 'token')
        : xdg != null
        ? platform.joinPath(xdg, 'huggingface', 'token')
        : home == null
        ? null
        : platform.joinPath(home, '.cache', 'huggingface', 'token');
    if (path == null) return null;
    final text = await platform.readTextFile(path);
    final line = text?.split(RegExp(r'\r?\n')).first.trim();
    return (line == null || line.isEmpty) ? null : line;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final values = FieldValues.of(this, account);
    final token = values[ProviderField.secretKey] ?? await _tokenFile();
    if (token == null) {
      throw ProviderException(
        '未填写 Hugging Face Token',
        hint: '在账户设置中填写、设置 HF_TOKEN，或运行 hf auth login',
      );
    }
    final headers = {'Authorization': 'Bearer ${bareToken(token)}', 'User-Agent': ctx.userAgent};
    final now = ctx.now().toUtc();
    final start = startOfUtcMonth(now).millisecondsSinceEpoch ~/ 1000;
    final usage = parseHuggingFaceUsage(
      await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse(
          '$_host/api/settings/billing/usage-v2?startDate=$start&endDate=${now.millisecondsSinceEpoch ~/ 1000}',
        ),
        headers: headers,
        authHint: 'Token 需要 Billing 读取权限',
        timeout: const Duration(seconds: 15),
      ),
    );
    Future<Map<String, Object?>?> optional(String path) async {
      try {
        final r = await sendRequest(
          ctx,
          displayName,
          Uri.parse('$_host$path'),
          headers: headers,
          timeout: const Duration(seconds: 3),
        );
        return r.ok ? asMap(r.json) : null;
      } on ProviderException {
        return null;
      }
    }

    final extra = await Future.wait([
      optional('/api/spaces/zero-gpu/quota'),
      optional('/api/whoami-v2'),
    ]);
    final gpu = extra[0] == null ? null : parseHuggingFaceZeroGpu(extra[0]!);
    final who = extra[1];
    final isPro = who?['isPro'];
    return snapshot(
      account,
      ctx,
      email: asString(who?['email']),
      plan: isPro is bool ? (isPro ? 'PRO' : 'Free') : null,
      source: 'api-key',
      windows: [?gpu],
      credits: [usage],
    );
  }
}
