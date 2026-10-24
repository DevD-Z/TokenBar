import '../../models/credits.dart';
import '../../models/rate_window.dart';
import '../../util/json_utils.dart';

class ClaudeParsedUsage {
  const ClaudeParsedUsage(this.windows, this.credits);

  final List<RateWindow> windows;
  final List<Credits> credits;
}

const _weeklyMinutes = 7 * 24 * 60;

/// Parses `GET https://api.anthropic.com/api/oauth/usage`.
ClaudeParsedUsage parseClaudeOAuthUsage(Map<String, Object?> json) {
  RateWindow? make(String key, String id, String label, int minutes) {
    final map = asMap(json[key]);
    if (map == null) return null;
    final utilization = map['utilization'];
    if (utilization is! num) return null;
    return RateWindow(
      id: id,
      label: label,
      usedPercent: utilization.toDouble(),
      resetsAt: DateTime.tryParse(asString(map['resets_at']) ?? ''),
      windowMinutes: minutes,
    );
  }

  final windows = <RateWindow>[
    ?make('five_hour', RateWindow.sessionId, '5-hour', 300),
    ?make('seven_day', RateWindow.weeklyId, 'Weekly', _weeklyMinutes),
    ?make('seven_day_opus', 'weekly_opus', 'Opus weekly', _weeklyMinutes),
    ?make('seven_day_sonnet', 'weekly_sonnet', 'Sonnet weekly', _weeklyMinutes),
  ];

  final credits = <Credits>[];
  final extra = asMap(json['extra_usage']);
  if (extra != null && asBool(extra['is_enabled']) == true) {
    final used = asDouble(extra['used_credits']);
    final limit = asDouble(extra['monthly_limit']);
    if (used != null && limit != null) {
      // OAuth extra usage amounts are reported in cents.
      credits.add(
        Credits(
          id: 'claude-extra-usage',
          label: 'Extra usage',
          used: used / 100,
          limit: limit / 100,
          currency: asString(extra['currency']) ?? 'USD',
        ),
      );
    }
  }
  return ClaudeParsedUsage(windows, credits);
}

/// Email from `GET /api/oauth/profile`.
String? parseClaudeProfileEmail(Map<String, Object?> json) {
  final account = asMap(json['account']);
  return asString(pick(account ?? const {}, ['email_address', 'emailAddress', 'email'])) ??
      asString(pick(json, ['email_address', 'emailAddress', 'email']));
}

/// Human plan name from credential metadata, e.g. `max` + `default_claude_max_20x`.
String? claudePlanName(String? subscriptionType, String? rateLimitTier) {
  final sub = subscriptionType?.toLowerCase();
  if (sub == null) return null;
  final tier = rateLimitTier?.toLowerCase() ?? '';
  final multiplier = RegExp(r'(\d+)x').firstMatch(tier)?.group(1);
  final base = switch (sub) {
    'max' => 'Max',
    'pro' => 'Pro',
    'team' => 'Team',
    'enterprise' => 'Enterprise',
    'free' => 'Free',
    _ => sub[0].toUpperCase() + sub.substring(1),
  };
  return multiplier != null && sub == 'max' ? '$base ${multiplier}x' : base;
}
