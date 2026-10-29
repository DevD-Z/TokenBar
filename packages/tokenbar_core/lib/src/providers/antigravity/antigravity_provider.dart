import 'dart:convert';

import '../../models/account.dart';
import '../../models/oauth_credential.dart';
import '../../models/rate_window.dart';
import '../../models/usage_snapshot.dart';
import '../../util/json_utils.dart';
import '../provider.dart';

const String antigravityClientId = String.fromEnvironment('ANTIGRAVITY_CLIENT_ID');
const String antigravityClientSecret = String.fromEnvironment('ANTIGRAVITY_CLIENT_SECRET');

class AntigravityProvider extends UsageProvider {
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _loadCodeAssistUrl =
      'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist';
  static const _quotaUrl =
      'https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels';
  static const _quotaSummaryUrl =
      'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary';
  static const _userAgent = 'antigravity/hub/2.24.0 darwin/arm64';

  static const _metadata = {
    'ideType': 9,
    'platform': 2,
    'pluginType': 2,
  };

  @override
  String get id => 'antigravity';

  @override
  String get displayName => 'Antigravity';

  @override
  int get brandColor => 0xFFF59E0B;

  @override
  List<SourceType> get supportedSources => const [SourceType.oauth];

  @override
  String get setupHint =>
      'Sign in with Google OAuth to read Antigravity quota directly from Google Cloud Code.';

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    if (antigravityClientId.isEmpty || antigravityClientSecret.isEmpty) {
      throw ProviderException(
        'Antigravity OAuth is not configured in this build',
        hint: 'Set ANTIGRAVITY_CLIENT_ID and ANTIGRAVITY_CLIENT_SECRET when building TokenBar',
      );
    }

    var credential = OAuthCredential.decode(account.secret);
    if (credential == null) {
      throw ProviderException('Antigravity OAuth credential not found', hint: 'Reconnect Antigravity');
    }

    if (credential.expiresWithin(ctx.now(), const Duration(minutes: 5))) {
      credential = await _refresh(account, credential, ctx);
    }

    try {
      return await _load(account, credential, ctx);
    } on ProviderException catch (e) {
      if ((e.statusCode == 401 || e.statusCode == 403) && credential.refreshToken != null) {
        final refreshed = await _refresh(account, credential, ctx);
        return _load(account, refreshed, ctx);
      }
      rethrow;
    }
  }

  Future<OAuthCredential> _refresh(
    AccountConfig account,
    OAuthCredential credential,
    FetchContext ctx,
  ) async {
    final refreshToken = credential.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw ProviderException(
        'Antigravity OAuth session expired',
        hint: 'Reconnect Antigravity',
        statusCode: 401,
      );
    }

    final response = await ctx.client
        .post(
          Uri.parse(_tokenUrl),
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'client_id': antigravityClientId,
            'client_secret': antigravityClientSecret,
          },
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderException(
        'Antigravity OAuth refresh failed (HTTP ${response.statusCode})',
        hint: 'Reconnect Antigravity',
        statusCode: response.statusCode,
      );
    }

    final json = decodeJsonObject(response.body);
    final access = asString(json?['access_token']);
    if (json == null || access == null) {
      throw ProviderException('Antigravity OAuth refresh returned invalid data');
    }

    final expiresIn = asInt(json['expires_in']) ?? 3600;
    final refreshed = credential.copyWith(
      accessToken: access,
      refreshToken: asString(json['refresh_token']) ?? refreshToken,
      expiresAt: ctx.now().toUtc().add(Duration(seconds: expiresIn)),
      scope: asString(json['scope']) ?? credential.scope,
    );
    await ctx.onOAuthCredentialUpdated?.call(account, refreshed);
    return refreshed;
  }

  Future<UsageSnapshot> _load(
    AccountConfig account,
    OAuthCredential credential,
    FetchContext ctx,
  ) async {
    final subscription = await _subscriptionInfo(credential.accessToken, ctx);
    final project = _projectId(subscription);
    final plan =
        asString(asMap(subscription?['currentTier'])?['name']) ??
        asString(asMap(subscription?['paidTier'])?['name']) ??
        'Antigravity';

    final windows = <RateWindow>[];

    final weekly = await _postJson(
      ctx,
      Uri.parse(_quotaSummaryUrl),
      credential.accessToken,
      {if (project != null) 'project': project},
      tolerateForbidden: true,
    );
    if (weekly != null) windows.addAll(parseAntigravityQuotaSummary(weekly));

    final models = await _postJson(
      ctx,
      Uri.parse(_quotaUrl),
      credential.accessToken,
      {if (project != null) 'project': project},
      tolerateForbidden: true,
    );
    if (models != null) {
      final image = parseAntigravityImageQuota(models);
      if (image != null) windows.add(image);
    }

    if (windows.isEmpty) {
      throw ProviderException(
        'Antigravity quota API returned no usable quota data',
        hint: 'The account may need Antigravity / Google Cloud Code access enabled',
      );
    }

    return UsageSnapshot(
      accountId: account.id,
      providerId: id,
      fetchedAt: ctx.now(),
      plan: plan,
      email: credential.email,
      source: 'oauth',
      windows: windows,
      extras: {if (project != null) 'projectId': project},
    );
  }

  Future<Map<String, Object?>?> _subscriptionInfo(String accessToken, FetchContext ctx) async {
    try {
      return await _postJson(
        ctx,
        Uri.parse(_loadCodeAssistUrl),
        accessToken,
        const {
          'metadata': _metadata,
          'mode': 1,
        },
        tolerateForbidden: true,
      );
    } on ProviderException {
      return null;
    }
  }

  Future<Map<String, Object?>?> _postJson(
    FetchContext ctx,
    Uri uri,
    String accessToken,
    Map<String, Object?> body, {
    bool tolerateForbidden = false,
  }) async {
    final response = await ctx.client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'User-Agent': _userAgent,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Client-Name': 'antigravity',
            'X-Client-Version': '2.24.0',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 401 || response.statusCode == 403) {
      if (tolerateForbidden && response.statusCode == 403) return null;
      throw ProviderException(
        'Antigravity authorization failed (HTTP ${response.statusCode})',
        hint: 'Reconnect Antigravity',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderException(
        'Antigravity API error HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final json = decodeJsonObject(utf8.decode(response.bodyBytes));
    if (json == null) throw ProviderException('Antigravity returned invalid JSON');
    return json;
  }

  static String? _projectId(Map<String, Object?>? subscription) {
    if (subscription == null) return null;
    final raw = subscription['cloudaicompanionProject'];
    if (raw is String) return raw.trim().isEmpty ? null : raw.trim();
    return asString(asMap(raw)?['id']);
  }
}

List<RateWindow> parseAntigravityQuotaSummary(Map<String, Object?> data) {
  final summary = asMap(data['quotaSummary']);
  final groups = asList(data['groups']) ?? asList(summary?['groups']) ?? const [];
  final windows = <RateWindow>[];

  void addWindow({
    required String id,
    required String label,
    required Object? rawFraction,
    required Object? resetTime,
    required int minutes,
  }) {
    final remaining = asDouble(rawFraction);
    if (remaining == null || !remaining.isFinite) return;
    windows.add(
      RateWindow(
        id: id,
        label: label,
        usedPercent: ((1 - remaining) * 100).clamp(0, 100).toDouble(),
        resetsAt: _parseGoogleReset(resetTime),
        windowMinutes: minutes,
      ),
    );
  }

  bool already(String id) => windows.any((w) => w.id == id);

  for (final rawGroup in groups) {
    final group = asMap(rawGroup);
    if (group == null) continue;
    final groupName = (asString(group['displayName']) ?? '').toLowerCase();
    final isGemini = groupName.contains('gemini');
    final isClaude = groupName.contains('claude') || groupName.contains('gpt');
    if (!isGemini && !isClaude) continue;

    for (final rawBucket in asList(group['buckets']) ?? const []) {
      final bucket = asMap(rawBucket);
      if (bucket == null) continue;
      final window = (asString(bucket['window']) ?? '').toLowerCase();
      final text =
          '${asString(bucket['bucketId']) ?? ''} ${asString(bucket['displayName']) ?? ''}'
              .toLowerCase();
      final weekly = window == 'weekly' || text.contains('weekly');
      final session =
          window == '5h' ||
          window == 'daily' ||
          text.contains('five hour') ||
          text.contains('5h') ||
          text.contains('daily');
      if (!weekly && !session) continue;
      if (weekly && bucket['disabled'] == true) continue;

      final fraction = bucket['disabled'] == true ? 0 : bucket['remainingFraction'];
      if (isGemini) {
        final id = weekly ? 'antigravity-gemini-weekly' : 'antigravity-gemini-session';
        if (!already(id)) {
          addWindow(
            id: id,
            label: weekly ? 'Gemini (Weekly)' : 'Gemini (5h)',
            rawFraction: fraction,
            resetTime: bucket['resetTime'],
            minutes: weekly ? 10080 : 300,
          );
        }
      } else if (isClaude) {
        final id = weekly ? 'antigravity-claude-gpt-weekly' : 'antigravity-claude-gpt-session';
        if (!already(id)) {
          addWindow(
            id: id,
            label: weekly ? 'Claude & GPT (Weekly)' : 'Claude & GPT (5h)',
            rawFraction: fraction,
            resetTime: bucket['resetTime'],
            minutes: weekly ? 10080 : 300,
          );
        }
      }
    }
  }
  return windows;
}

RateWindow? parseAntigravityImageQuota(Map<String, Object?> data) {
  final models = asMap(data['models']);
  final info = asMap(models?['gemini-3.1-flash-image']);
  final quota = asMap(info?['quotaInfo']);
  final remaining = asDouble(quota?['remainingFraction']);
  if (quota == null || remaining == null) return null;
  return RateWindow(
    id: 'antigravity-gemini-3.1-flash-image',
    label: 'Gemini 3.1 Flash Image',
    usedPercent: ((1 - remaining) * 100).clamp(0, 100).toDouble(),
    resetsAt: _parseGoogleReset(quota['resetTime']),
    windowMinutes: 300,
  );
}

DateTime? _parseGoogleReset(Object? raw) {
  final text = asString(raw);
  if (text == null) return null;
  return DateTime.tryParse(text)?.toUtc();
}
