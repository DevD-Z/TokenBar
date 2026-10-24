import '../../models/account.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../common.dart';
import '../fields.dart';
import '../http_support.dart';
import '../provider.dart';

({List<RateWindow> windows, String? plan}) parseElevenLabsSubscription(Map<String, Object?> json) {
  final count = json['character_count'];
  final limit = json['character_limit'];
  if (count is! int || limit is! int) throw ProviderException('ElevenLabs 返回数据格式无法识别');
  final windows = [
    quotaWindow(
      'elevenlabs-credits',
      'Credits',
      usedPercent: limit > 0 ? pct(count < 0 ? 0 : count, limit) : 0,
      resetsAt: epochSeconds(asInt(json['next_character_count_reset_unix'])),
    ),
  ];
  void slot(String id, String label, String usedKey, String limitKey) {
    final used = asInt(json[usedKey]);
    final max = asInt(json[limitKey]);
    if (used != null && max != null && max > 0) {
      windows.add(quotaWindow(id, label, usedPercent: pct(used, max)));
    }
  }

  slot('elevenlabs-voice-slots', '声音槽位', 'voice_slots_used', 'voice_limit');
  slot(
    'elevenlabs-professional-voices',
    '专业声音',
    'professional_voice_slots_used',
    'professional_voice_limit',
  );

  final tier = asString(json['tier'])?.replaceAll('_', ' ').toLowerCase();
  final status = asString(json['status']);
  String? plan;
  if (tier != null) {
    plan = tier
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
    if (status != null && status.toLowerCase() != 'active') plan = '$plan · $status';
  } else {
    plan = status;
  }
  return (windows: windows, plan: plan);
}

class ElevenLabsProvider extends UsageProvider {
  @override
  String get id => 'elevenlabs';

  @override
  String get displayName => 'ElevenLabs';

  @override
  int get brandColor => 0xFF3A3A38;

  @override
  List<SourceType> get supportedSources => const [SourceType.apiKey];

  @override
  String get setupHint => 'ElevenLabs API Key（需要 user_read 权限），查询字符额度和声音槽位。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.apiKey(envVars: ['ELEVENLABS_API_KEY', 'XI_API_KEY']),
  ];

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final key = FieldValues.of(this, account).secret;
    final result = parseElevenLabsSubscription(
      await fetchJsonObject(
        ctx,
        displayName,
        Uri.parse('https://api.elevenlabs.io/v1/user/subscription'),
        headers: {'xi-api-key': key.trim()},
        authHint: '检查 API Key 是否有效，并且具有 user_read 权限',
        timeout: const Duration(seconds: 15),
      ),
    );
    return snapshot(account, ctx, plan: result.plan, source: 'api-key', windows: result.windows);
  }
}
