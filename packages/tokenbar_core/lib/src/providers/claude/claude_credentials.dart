import 'dart:convert';

import '../../platform/platform.dart' as platform;
import '../../util/json_utils.dart';

/// `claudeAiOauth` entry written by Claude Code.
class ClaudeCredentials {
  const ClaudeCredentials({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scopes = const [],
    this.subscriptionType,
    this.rateLimitTier,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;
  final String? subscriptionType;
  final String? rateLimitTier;

  bool isExpired(DateTime now) {
    final exp = expiresAt;
    return exp != null && !now.isBefore(exp);
  }

  bool get hasProfileScope => scopes.isEmpty || scopes.contains('user:profile');

  static ClaudeCredentials? parse(String text) {
    final root = decodeJsonObject(text);
    final oauth = asMap(root?['claudeAiOauth']);
    if (oauth == null) return null;
    final access = asString(oauth['accessToken']);
    if (access == null) return null;
    final expiresMs = asDouble(oauth['expiresAt']);
    return ClaudeCredentials(
      accessToken: access,
      refreshToken: asString(oauth['refreshToken']),
      expiresAt: expiresMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresMs.toInt(), isUtc: true),
      scopes: (asList(oauth['scopes']) ?? const []).whereType<String>().toList(),
      subscriptionType: asString(oauth['subscriptionType']),
      rateLimitTier: asString(oauth['rateLimitTier']),
    );
  }

  /// Returns [original] with the OAuth tokens replaced, preserving every
  /// other field Claude Code stores in the same file.
  String mergeInto(String original) {
    final root = decodeJsonObject(original) ?? <String, Object?>{};
    final oauth = Map<String, Object?>.from(asMap(root['claudeAiOauth']) ?? const {});
    oauth['accessToken'] = accessToken;
    if (refreshToken != null) oauth['refreshToken'] = refreshToken;
    if (expiresAt != null) {
      oauth['expiresAt'] = expiresAt!.millisecondsSinceEpoch;
    }
    root['claudeAiOauth'] = oauth;
    return const JsonEncoder.withIndent('  ').convert(root);
  }
}

/// Where a credential was read from.
enum ClaudeCredentialSource { file, keychain }

class LoadedClaudeCredentials {
  const LoadedClaudeCredentials(this.credentials, this.source, this.path, this.raw);

  final ClaudeCredentials credentials;
  final ClaudeCredentialSource source;
  final String? path;
  final String raw;
}

/// Claude config dir: explicit override, `$CLAUDE_CONFIG_DIR`, `~/.claude`.
String? resolveClaudeConfigDir(String? override) {
  if (override != null && override.trim().isNotEmpty) return override.trim();
  final env = platform.envVar('CLAUDE_CONFIG_DIR');
  if (env != null) return env;
  final home = platform.homeDirectory();
  return home == null ? null : platform.joinPath(home, '.claude');
}

const claudeKeychainService = 'Claude Code-credentials';

/// Loads Claude Code OAuth credentials: the credentials file first, then (on
/// macOS, default profile only) the `Claude Code-credentials` Keychain item.
Future<LoadedClaudeCredentials?> loadClaudeCredentials(String? homeOverride) async {
  final dir = resolveClaudeConfigDir(homeOverride);
  if (dir != null) {
    final path = platform.joinPath(dir, '.credentials.json');
    final text = await platform.readTextFile(path);
    if (text != null) {
      final creds = ClaudeCredentials.parse(text);
      if (creds != null) {
        return LoadedClaudeCredentials(creds, ClaudeCredentialSource.file, path, text);
      }
    }
  }
  final usesDefaultProfile =
      (homeOverride == null || homeOverride.trim().isEmpty) &&
      platform.envVar('CLAUDE_CONFIG_DIR') == null;
  if (platform.isMacOS && usesDefaultProfile) {
    final out = await platform.runProcess('/usr/bin/security', const [
      'find-generic-password',
      '-s',
      claudeKeychainService,
      '-w',
    ], timeout: const Duration(seconds: 20));
    if (out != null && out.exitCode == 0) {
      final text = out.stdout.trim();
      final creds = ClaudeCredentials.parse(text);
      if (creds != null) {
        return LoadedClaudeCredentials(creds, ClaudeCredentialSource.keychain, null, text);
      }
    }
  }
  return null;
}
