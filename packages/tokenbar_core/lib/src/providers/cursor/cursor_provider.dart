import 'dart:async';
import 'dart:convert';

import '../../models/account.dart';
import '../../models/usage_snapshot.dart';
import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import '../fields.dart';
import '../provider.dart';
import 'cursor_session.dart';
import 'cursor_usage_parser.dart';

/// Cursor plan usage from cursor.com's dashboard API, authenticated with the
/// local Cursor login (read-only) or a pasted cursor.com cookie.
class CursorProvider extends UsageProvider {
  static const _baseUrl = 'https://cursor.com';
  static final Map<String, String?> _emailByCookie = {};

  @override
  String get id => 'cursor';

  @override
  String get displayName => 'Cursor';

  @override
  int get brandColor => 0xFF5E6AD2;

  @override
  List<SourceType> get supportedSources => const [SourceType.localCli, SourceType.apiKey];

  @override
  String get setupHint =>
      '本机模式读取 Cursor 桌面端的登录状态（只读，不刷新令牌）。'
      '手动模式：浏览器登录 cursor.com，在开发者工具里复制请求的 Cookie（含 WorkosCursorSessionToken）粘贴进来，手机也能用。';

  @override
  List<ProviderField> get fields => const [
    ProviderField.cookie(
      label: 'cursor.com Cookie',
      hint: 'WorkosCursorSessionToken=...',
      help: '浏览器登录 cursor.com → 开发者工具 → 网络 → 任一请求的 Cookie 请求头',
    ),
  ];

  @override
  String get manualSourceLabel => '手动粘贴 Cookie';

  @override
  String get localSourceLabel => '本机 Cursor 登录';

  @override
  String? validateManual(FieldValues values) {
    final secret = values[ProviderField.secretKey];
    if (secret == null || CursorSession.fromManual(secret) != null) return null;
    return '无法识别：需要包含 WorkosCursorSessionToken 的 Cookie';
  }

  @override
  Future<bool> hasLocalLogin(AccountConfig account) async =>
      platform.localAccessSupported &&
      await loadLocalCursorSession(userDataDir: account.homeDir) != null;

  @override
  Future<UsageSnapshot> fetch(AccountConfig account, FetchContext ctx) async {
    final session = await _session(account);
    if (session.isExpired(ctx.now())) {
      throw ProviderException(
        'Cursor 登录已过期',
        hint: session.source == 'manual' ? '重新复制 cursor.com 的 Cookie' : '打开 Cursor 让它自动续期登录',
        statusCode: 401,
      );
    }
    final results = await Future.wait([
      _get('/api/usage-summary', session, ctx),
      _email(session, ctx),
    ]);
    final usage = parseCursorUsageSummary(results[0] as Map<String, Object?>);
    return UsageSnapshot(
      accountId: account.id,
      providerId: id,
      fetchedAt: ctx.now(),
      plan: usage.plan,
      email: (results[1] as String?) ?? session.email,
      source: switch (session.source) {
        'app' => 'cursor-app',
        'cli' => 'cursor-agent',
        _ => 'cookie',
      },
      windows: usage.windows,
      credits: usage.credits,
    );
  }

  Future<CursorSession> _session(AccountConfig account) async {
    if (account.sourceType == SourceType.apiKey) {
      final secret = FieldValues.of(this, account)[ProviderField.secretKey];
      if (secret == null) {
        throw ProviderException('未填写 Cursor Cookie', hint: '在账户设置中粘贴 cursor.com 的 Cookie');
      }
      final session = CursorSession.fromManual(secret);
      if (session == null) {
        throw ProviderException('无法识别的 Cursor Cookie', hint: '需要包含 WorkosCursorSessionToken');
      }
      return session;
    }
    if (!platform.localAccessSupported) {
      throw ProviderException('此平台无法读取本机 Cursor 登录', hint: '改用"手动粘贴 Cookie"方式');
    }
    final session = await loadLocalCursorSession(userDataDir: account.homeDir);
    if (session == null) {
      throw ProviderException('未找到 Cursor 登录', hint: '打开 Cursor 桌面端并登录，或改用手动粘贴 Cookie');
    }
    return session;
  }

  Future<Map<String, Object?>> _get(String path, CursorSession session, FetchContext ctx) async {
    final response = await ctx.client
        .get(
          Uri.parse('$_baseUrl$path'),
          headers: {'Accept': 'application/json', 'Cookie': session.cookieHeader},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ProviderException(
        'Cursor 拒绝了登录凭证 (HTTP ${response.statusCode})',
        hint: session.source == 'manual' ? '重新复制 cursor.com 的 Cookie' : '在 Cursor 中重新登录',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw ProviderException(
        'Cursor 接口错误 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final json = decodeJsonObject(utf8.decode(response.bodyBytes));
    if (json == null) throw ProviderException('Cursor 接口返回了无效数据');
    return json;
  }

  Future<String?> _email(CursorSession session, FetchContext ctx) async {
    if (_emailByCookie.containsKey(session.cookieHeader)) {
      return _emailByCookie[session.cookieHeader];
    }
    String? email;
    try {
      email = asString((await _get('/api/auth/me', session, ctx))['email']);
    } catch (_) {
      email = null;
    }
    return _emailByCookie[session.cookieHeader] = email;
  }
}
