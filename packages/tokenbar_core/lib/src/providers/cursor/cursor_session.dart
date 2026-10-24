import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';
import 'cursor_usage_parser.dart';

/// A cursor.com session expressed as the `Cookie` header to send.
class CursorSession {
  const CursorSession({
    required this.cookieHeader,
    required this.source,
    this.expiresAt,
    this.email,
  });

  final String cookieHeader;

  /// `app` (Cursor desktop login), `cli` (cursor-agent) or `manual`.
  final String source;
  final DateTime? expiresAt;
  final String? email;

  bool isExpired(DateTime now) =>
      expiresAt != null && expiresAt!.isBefore(now.toUtc().add(const Duration(seconds: 60)));

  /// Builds a session from a Cursor access token (JWT).
  static CursorSession? fromAccessToken(String token, {required String source}) {
    final claims = decodeJwtPayload(token);
    final userId = cursorUserIdFromJwt(claims);
    if (userId == null) return null;
    return CursorSession(
      cookieHeader: 'WorkosCursorSessionToken=$userId%3A%3A$token',
      source: source,
      expiresAt: epochSeconds(asInt(claims?['exp'])),
      email: asString(claims?['email']),
    );
  }

  /// Accepts a full `Cookie:` header, a `WorkosCursorSessionToken` value
  /// (`user::jwt`, URL-encoded or not), or a bare access token.
  static CursorSession? fromManual(String input) {
    var text = input.trim();
    if (text.toLowerCase().startsWith('cookie:')) text = text.substring(7).trim();
    if (text.isEmpty) return null;
    if (text.contains('=')) {
      final known = [
        'WorkosCursorSessionToken',
        '__Secure-next-auth.session-token',
        'next-auth.session-token',
      ];
      final hasSession = text.split(';').any((c) => known.contains(c.split('=').first.trim()));
      return hasSession ? CursorSession(cookieHeader: text, source: 'manual') : null;
    }
    final decoded = Uri.decodeComponent(text);
    if (decoded.contains('::')) {
      final token = decoded.split('::').last;
      return CursorSession(
        cookieHeader: 'WorkosCursorSessionToken=${Uri.encodeComponent(decoded)}',
        source: 'manual',
        expiresAt: epochSeconds(asInt(decodeJwtPayload(token)?['exp'])),
      );
    }
    final session = fromAccessToken(decoded, source: 'manual');
    return session;
  }
}

/// Cursor desktop keeps its login in a VS Code-style SQLite state DB.
String? cursorStateDbPath([String? userDataDir]) {
  final dir = userDataDir ?? _defaultUserDataDir();
  return dir == null ? null : platform.joinPath(dir, 'User', 'globalStorage', 'state.vscdb');
}

String? _defaultUserDataDir() {
  if (platform.isWindows) {
    final appData = platform.envVar('APPDATA');
    return appData == null ? null : platform.joinPath(appData, 'Cursor');
  }
  final home = platform.homeDirectory();
  if (platform.isMacOS) {
    return home == null
        ? null
        : platform.joinPath(home, 'Library', 'Application Support', 'Cursor');
  }
  final xdg = platform.envVar('XDG_CONFIG_HOME');
  final config = (xdg != null && xdg.startsWith('/'))
      ? xdg
      : (home == null ? null : platform.joinPath(home, '.config'));
  return config == null ? null : platform.joinPath(config, 'Cursor');
}

/// Loads the local Cursor login without modifying anything: Cursor desktop
/// first, then `cursor-agent`'s auth.json. Expired tokens are reported, not
/// refreshed.
Future<CursorSession?> loadLocalCursorSession({String? userDataDir}) async {
  final dbPath = cursorStateDbPath(userDataDir);
  if (dbPath != null) {
    final token = await platform.readSqliteText(
      dbPath,
      'SELECT value FROM ItemTable WHERE key = ?',
      ['cursorAuth/accessToken'],
    );
    final session = token == null
        ? null
        : CursorSession.fromAccessToken(token.trim(), source: 'app');
    if (session != null) return session;
  }
  final agent = await _cursorAgentAuthPath();
  if (agent != null) {
    final json = decodeJsonObject(await platform.readTextFile(agent) ?? '');
    final token = asString(json?['accessToken']);
    if (token != null) return CursorSession.fromAccessToken(token, source: 'cli');
  }
  return null;
}

Future<String?> _cursorAgentAuthPath() async {
  final home = platform.homeDirectory();
  if (home == null) return null;
  final xdg = platform.envVar('XDG_CONFIG_HOME');
  final config = (xdg != null && xdg.startsWith('/')) ? xdg : platform.joinPath(home, '.config');
  return platform.joinPath(config, 'cursor', 'auth.json');
}
