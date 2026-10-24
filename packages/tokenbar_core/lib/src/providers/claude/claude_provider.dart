import 'dart:async';
import 'dart:convert';

import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import '../provider.dart';
import 'claude_credentials.dart';
import 'claude_usage_parser.dart';

/// Claude subscription limits via Claude Code's OAuth token.
class ClaudeProvider extends UsageProvider {
  static const _baseUrl = 'https://api.anthropic.com';
  static const _betaHeader = 'oauth-2025-04-20';
  static const _fallbackVersion = '2.1.0';
  static const _tokenEndpoint = 'https://platform.claude.com/v1/oauth/token';

  /// Claude Code's public OAuth client id (not a secret).
  static const _clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';

  static final Map<String, DateTime> _blockedUntil = {};
  static final Map<String, String?> _emailByToken = {};
  static String? _cachedVersion;

  @override
  String get id => 'claude';

  @override
  String get displayName => 'Claude';

  @override
  int get brandColor => 0xFFD97757;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli];

  @override
  String get localSourceLabel => '本机 Claude Code 登录';

  @override
  String get setupHint =>
      '读取本机 Claude Code 登录（~/.claude/.credentials.json，macOS 为钥匙串）。'
      '先运行 `claude` 并登录 Pro/Max 账户。多账户可指定不同的 CLAUDE_CONFIG_DIR。';

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async =>
      platform.localAccessSupported && await loadClaudeCredentials(account.homeDir) != null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    if (!platform.localAccessSupported) {
      throw ProviderException('此平台无法读取本机 Claude 登录', hint: '请在电脑端或采集器上添加该账户，并通过服务器同步查看');
    }
    final blocked = _blockedUntil[account.id];
    if (blocked != null && ctx.now().isBefore(blocked)) {
      throw ProviderException(
        'Claude 用量接口限流中',
        hint: '将于 ${blocked.toLocal()} 后重试',
        statusCode: 429,
      );
    }

    final loaded = await loadClaudeCredentials(account.homeDir);
    if (loaded == null) {
      throw ProviderException('未找到 Claude Code 登录凭证', hint: '运行 `claude` 并完成登录');
    }
    var creds = loaded.credentials;
    if (!creds.hasProfileScope) {
      throw ProviderException(
        'Claude 令牌缺少 user:profile 权限，无法读取用量',
        hint: '`claude setup-token` 生成的令牌不支持用量查询，请用 `claude` 正常登录',
      );
    }
    if (creds.isExpired(ctx.now())) {
      creds = await _refreshIfAllowed(loaded, ctx);
    }

    final usage = await _fetchUsage(account, creds.accessToken, ctx);
    final parsed = parseClaudeOAuthUsage(usage);
    final email = await _email(creds.accessToken, ctx);
    return UsageSnapshot(
      accountId: account.id,
      providerId: id,
      fetchedAt: ctx.now(),
      plan: claudePlanName(creds.subscriptionType, creds.rateLimitTier),
      email: email,
      source: 'oauth',
      windows: parsed.windows,
      credits: parsed.credits,
      extras: {if (creds.rateLimitTier != null) 'rateLimitTier': creds.rateLimitTier!},
    );
  }

  Future<ClaudeCredentials> _refreshIfAllowed(
    LoadedClaudeCredentials loaded,
    FetchContext ctx,
  ) async {
    final refreshToken = loaded.credentials.refreshToken;
    final canWriteBack = loaded.source == ClaudeCredentialSource.file && loaded.path != null;
    if (!ctx.allowClaudeTokenRefresh || refreshToken == null || !canWriteBack) {
      throw ProviderException(
        'Claude 访问令牌已过期',
        hint:
            '运行一次 `claude` 让 Claude Code 自动刷新登录'
            '${canWriteBack ? '，或在设置中开启"允许 TokenBar 刷新 Claude 令牌"' : ''}',
        statusCode: 401,
      );
    }
    final response = await ctx.client
        .post(
          Uri.parse(_tokenEndpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'client_id': _clientId,
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw ProviderException(
        'Claude 令牌刷新失败 (HTTP ${response.statusCode})',
        hint: '运行 `claude` 重新登录',
        statusCode: response.statusCode,
      );
    }
    final json = decodeJsonObject(response.body);
    final access = asString(json?['access_token']);
    if (json == null || access == null) {
      throw ProviderException('Claude 令牌刷新返回了无效数据');
    }
    final expiresIn = asInt(json['expires_in']) ?? 3600;
    final old = loaded.credentials;
    final refreshed = ClaudeCredentials(
      accessToken: access,
      refreshToken: asString(json['refresh_token']) ?? refreshToken,
      expiresAt: ctx.now().toUtc().add(Duration(seconds: expiresIn)),
      scopes: old.scopes,
      subscriptionType: old.subscriptionType,
      rateLimitTier: old.rateLimitTier,
    );
    // Refresh tokens rotate: persist immediately so Claude Code keeps working.
    final latest = await platform.readTextFile(loaded.path!) ?? loaded.raw;
    await platform.writeTextFileAtomic(loaded.path!, refreshed.mergeInto(latest));
    return refreshed;
  }

  Future<Map<String, Object?>> _fetchUsage(
    AccountConfig account,
    String accessToken,
    FetchContext ctx,
  ) async {
    final version = await _claudeVersion();
    final response = await ctx.client
        .get(
          Uri.parse('$_baseUrl/api/oauth/usage'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'anthropic-beta': _betaHeader,
            'User-Agent': 'claude-code/$version',
          },
        )
        .timeout(const Duration(seconds: 30));

    switch (response.statusCode) {
      case 200:
        _blockedUntil.remove(account.id);
        final json = decodeJsonObject(utf8.decode(response.bodyBytes));
        if (json == null) throw ProviderException('Claude 用量接口返回了无效数据');
        return json;
      case 401:
        throw ProviderException('Claude OAuth 令牌无效', hint: '运行 `claude` 重新登录', statusCode: 401);
      case 429:
        final retry = _retryAfter(response.headers['retry-after'], ctx.now());
        _blockedUntil[account.id] = retry;
        throw ProviderException(
          'Claude 用量接口被限流',
          hint: '将于 ${retry.toLocal()} 后自动重试',
          statusCode: 429,
        );
      default:
        final body = response.body.replaceAll(RegExp(r'\s+'), ' ').trim();
        throw ProviderException(
          'Claude 接口错误 HTTP ${response.statusCode}: '
          '${body.length > 200 ? '${body.substring(0, 200)}…' : body}',
          statusCode: response.statusCode,
        );
    }
  }

  Future<String?> _email(String accessToken, FetchContext ctx) async {
    if (_emailByToken.containsKey(accessToken)) return _emailByToken[accessToken];
    String? email;
    try {
      final response = await ctx.client
          .get(
            Uri.parse('$_baseUrl/api/oauth/profile'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Accept': 'application/json',
              'anthropic-beta': _betaHeader,
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final json = decodeJsonObject(utf8.decode(response.bodyBytes));
        email = json == null ? null : parseClaudeProfileEmail(json);
      }
    } catch (_) {
      email = null;
    }
    _emailByToken[accessToken] = email;
    return email;
  }

  static Future<String> _claudeVersion() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;
    var version = _fallbackVersion;
    final exe = await platform.findExecutable('claude');
    if (exe != null) {
      final out = await platform.runProcess(exe, const ['--version']);
      final token = out?.stdout.trim().split(RegExp(r'\s+')).first;
      if (out != null &&
          out.exitCode == 0 &&
          token != null &&
          RegExp(r'^\d+\.\d+').hasMatch(token)) {
        version = token;
      }
    }
    return _cachedVersion = version;
  }

  static DateTime _retryAfter(String? header, DateTime now) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds != null && seconds >= 0) return now.add(Duration(seconds: seconds));
    return now.add(const Duration(minutes: 5));
  }
}
