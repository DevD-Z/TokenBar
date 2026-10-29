import 'dart:async';
import 'dart:convert';

import '../../models/account.dart';
import '../../models/model_usage.dart';
import '../../models/oauth_credential.dart';
import '../../models/usage_snapshot.dart';
import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import '../provider.dart';
import 'codex_credentials.dart';
import 'codex_model_usage.dart';
import 'codex_usage_parser.dart';

/// Codex (ChatGPT plan) limits.
///
/// Order follows CodexBar: OAuth API using `auth.json`, then the
/// `codex app-server` JSON-RPC when the token is stale or rejected. TokenBar
/// never refreshes or rewrites `auth.json` itself: rotating the refresh token
/// outside the CLI would sign the CLI out.
class CodexProvider extends UsageProvider {
  @override
  String get id => 'codex';

  @override
  String get displayName => 'Codex';

  @override
  int get brandColor => 0xFF10A37F;

  @override
  List<SourceType> get supportedSources => const [SourceType.oauth, SourceType.localCli];

  @override
  String get localSourceLabel => '本机 Codex CLI 登录';

  @override
  String get setupHint =>
      '推荐使用 OAuth 登录 ChatGPT/Codex；也可继续读取本机 Codex CLI 登录。'
      'OAuth 凭证只保存在 TokenBar 的系统安全存储中。';

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async {
    if (!platform.localAccessSupported) return false;
    final home = resolveCodexHome(account.homeDir);
    if (home == null) return false;
    final text = await platform.readTextFile(platform.joinPath(home, 'auth.json'));
    return text != null && CodexCredentials.parse(text) != null;
  }

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    if (account.sourceType == SourceType.oauth) {
      return _fetchOwnedOAuth(account, ctx);
    }
    if (!platform.localAccessSupported) {
      throw ProviderException('此平台无法读取本机 Codex 登录', hint: '请在电脑端或采集器上添加该账户，并通过服务器同步查看');
    }
    final home = resolveCodexHome(account.homeDir);
    if (home == null) throw ProviderException('无法确定 Codex 主目录');

    final authText = await platform.readTextFile(platform.joinPath(home, 'auth.json'));
    if (authText == null) {
      throw ProviderException(
        '未找到 Codex 登录凭证 ($home/auth.json)',
        hint: '运行 `codex login` 登录 ChatGPT 账户',
      );
    }
    final creds = CodexCredentials.parse(authText);
    if (creds == null) {
      throw ProviderException('auth.json 中没有可用的令牌', hint: '运行 `codex login`');
    }
    if (creds.isApiKey) {
      throw ProviderException(
        'Codex 当前使用 API Key 登录，没有 ChatGPT 套餐额度',
        hint: '使用 `codex login` 以 ChatGPT 账户登录',
      );
    }

    final configText = await platform.readTextFile(platform.joinPath(home, 'config.toml'));
    final baseUrl = configText == null ? null : parseChatGptBaseUrl(configText);

    ProviderException? oauthError;
    if (!creds.isExpired(ctx.now())) {
      try {
        return await _fetchOAuth(account, creds, baseUrl, ctx);
      } on ProviderException catch (e) {
        if (e.statusCode != 401 && e.statusCode != 403) rethrow;
        oauthError = e;
      }
    } else {
      oauthError = ProviderException(
        'Codex 访问令牌已过期',
        hint: '运行任意 codex 命令让 CLI 刷新登录，或执行 `codex login`',
        statusCode: 401,
      );
    }

    if (ctx.allowCliFallback) {
      final rpc = await _fetchViaRpc(account, home, creds, ctx);
      if (rpc != null) return rpc;
    }
    throw oauthError;
  }

  /// Per-model token usage from the local session logs (desktop only; read-only, numbers
  /// and model names only). Null when this platform has no local file access, the log
  /// directory does not exist, or anything goes wrong.
  @override
  Future<ModelUsageSeries?> fetchModelUsage(
    AccountConfig account,
    FetchContext ctx, {
    required DateTime from,
    required DateTime to,
  }) async {
    if (account.sourceType != SourceType.localCli || !platform.localAccessSupported) return null;
    try {
      final home = resolveCodexHome(account.homeDir);
      if (home == null) return null;
      return await loadCodexModelUsage(home, from, to);
    } catch (_) {
      return null;
    }
  }

  Future<UsageSnapshot> _fetchOwnedOAuth(AccountConfig account, FetchContext ctx) async {
    var credential = OAuthCredential.decode(account.secret);
    if (credential == null) {
      throw ProviderException('未找到 TokenBar OAuth 凭证', hint: '请重新连接 ChatGPT / Codex');
    }

    if (credential.expiresWithin(ctx.now(), const Duration(minutes: 10))) {
      credential = await _refreshOwnedOAuth(account, credential, ctx);
    }

    final creds = CodexCredentials(
      accessToken: credential.accessToken,
      refreshToken: credential.refreshToken,
      idToken: credential.idToken,
      accountId: credential.accountId,
      expiresAt: credential.expiresAt,
      email: credential.email,
      planFromToken: credential.plan,
    );

    try {
      return await _fetchOAuth(account, creds, null, ctx);
    } on ProviderException catch (e) {
      if ((e.statusCode == 401 || e.statusCode == 403) && credential.refreshToken != null) {
        final refreshed = await _refreshOwnedOAuth(account, credential, ctx);
        final retryCreds = CodexCredentials(
          accessToken: refreshed.accessToken,
          refreshToken: refreshed.refreshToken,
          idToken: refreshed.idToken,
          accountId: refreshed.accountId,
          expiresAt: refreshed.expiresAt,
          email: refreshed.email,
          planFromToken: refreshed.plan,
        );
        return _fetchOAuth(account, retryCreds, null, ctx);
      }
      rethrow;
    }
  }

  Future<OAuthCredential> _refreshOwnedOAuth(
    AccountConfig account,
    OAuthCredential credential,
    FetchContext ctx,
  ) async {
    final refreshToken = credential.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw ProviderException(
        'Codex OAuth 登录已过期',
        hint: '请重新连接 ChatGPT / Codex',
        statusCode: 401,
      );
    }

    final response = await ctx.client
        .post(
          Uri.parse('https://auth.openai.com/oauth/token'),
          headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({
            'client_id': 'app_EMoamEEZ73f0CkXaXp7hrann',
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderException(
        'Codex OAuth 刷新失败 (HTTP ${response.statusCode})',
        hint: '请重新连接 ChatGPT / Codex',
        statusCode: response.statusCode,
      );
    }

    final json = decodeJsonObject(response.body);
    final access = asString(json?['access_token']);
    if (json == null || access == null) {
      throw ProviderException('Codex OAuth 刷新返回了无效数据');
    }

    final expiresIn = asInt(json['expires_in']) ?? 3600;
    final idToken = asString(json['id_token']) ?? credential.idToken;
    final refreshed = credential.copyWith(
      accessToken: access,
      refreshToken: asString(json['refresh_token']) ?? refreshToken,
      idToken: idToken,
      expiresAt: ctx.now().toUtc().add(Duration(seconds: expiresIn)),
    );
    await ctx.onOAuthCredentialUpdated?.call(account, refreshed);
    return refreshed;
  }

  Future<UsageSnapshot> _fetchOAuth(
    AccountConfig account,
    CodexCredentials creds,
    String? baseUrl,
    FetchContext ctx,
  ) async {
    final uri = codexUsageUri(baseUrl);
    final response = await ctx.client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            'User-Agent': ctx.userAgent,
            'Accept': 'application/json',
            if (creds.accountId != null) 'ChatGPT-Account-Id': creds.accountId!,
          },
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ProviderException(
        'Codex 令牌无效或已过期 (HTTP ${response.statusCode})',
        hint: '运行 `codex login` 重新登录',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw ProviderException(
        'Codex 接口错误 HTTP ${response.statusCode}: ${_short(response.body)}',
        statusCode: response.statusCode,
      );
    }
    final json = decodeJsonObject(utf8.decode(response.bodyBytes));
    if (json == null) throw ProviderException('Codex 接口返回了无效数据');
    final parsed = parseWhamUsage(json);
    return UsageSnapshot(
      accountId: account.id,
      providerId: id,
      fetchedAt: ctx.now(),
      plan: parsed.plan ?? creds.planFromToken,
      email: creds.email,
      source: 'oauth',
      windows: parsed.windows,
      credits: parsed.credits,
    );
  }

  Future<UsageSnapshot?> _fetchViaRpc(
    AccountConfig account,
    String home,
    CodexCredentials creds,
    FetchContext ctx,
  ) async {
    final exe = await platform.findExecutable('codex');
    if (exe == null) return null;
    platform.JsonRpcSession? session;
    try {
      session = await platform.startJsonRpcProcess(
        exe,
        const ['-s', 'read-only', '-a', 'never', 'app-server'],
        environment: {if (account.homeDir != null) 'CODEX_HOME': home},
      );
      await session.request(
        'initialize',
        params: {
          'clientInfo': {'name': 'tokenbar', 'version': '0.1.0'},
        },
        timeout: const Duration(seconds: 15),
      );
      session.notify('initialized');
      Map<String, Object?>? accountInfo;
      try {
        accountInfo = asMap(
          await session.request('account/read', timeout: const Duration(seconds: 5)),
        );
      } on platform.JsonRpcException {
        accountInfo = null;
      }
      final result = asMap(
        await session.request('account/rateLimits/read', timeout: const Duration(seconds: 10)),
      );
      if (result == null) return null;
      final parsed = parseRpcRateLimits(result, account: accountInfo);
      return UsageSnapshot(
        accountId: account.id,
        providerId: id,
        fetchedAt: ctx.now(),
        plan: parsed.plan ?? creds.planFromToken,
        email: parsed.email ?? creds.email,
        source: 'cli-rpc',
        windows: parsed.windows,
        credits: parsed.credits,
      );
    } catch (_) {
      // Any CLI failure keeps the original OAuth error as the user-facing one.
      return null;
    } finally {
      await session?.close();
    }
  }
}

String _short(String body) {
  final cleaned = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned.length > 200 ? '${cleaned.substring(0, 200)}…' : cleaned;
}
