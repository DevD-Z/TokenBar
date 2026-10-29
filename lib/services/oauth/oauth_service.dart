import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:tokenbar_core/tokenbar_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'oauth_callback.dart';

class OAuthLoginException implements Exception {
  OAuthLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OAuthService {
  OAuthService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _codex = _OAuthConfig(
    providerId: 'codex',
    clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
    authorizeUrl: 'https://auth.openai.com/oauth/authorize',
    tokenUrl: 'https://auth.openai.com/oauth/token',
    scopes: ['openid', 'profile', 'email', 'offline_access'],
    fixedPort: 1455,
    callbackPath: '/auth/callback',
  );

  static const _claude = _OAuthConfig(
    providerId: 'claude',
    clientId: '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
    authorizeUrl: 'https://claude.ai/oauth/authorize',
    tokenUrl: 'https://api.anthropic.com/v1/oauth/token',
    scopes: ['org:create_api_key', 'user:profile', 'user:inference'],
    callbackPath: '/callback',
  );

  static const _antigravity = _OAuthConfig(
    providerId: 'antigravity',
    clientId: antigravityClientId,
    clientSecret: antigravityClientSecret,
    authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    scopes: [
      'https://www.googleapis.com/auth/cloud-platform',
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/userinfo.profile',
      'https://www.googleapis.com/auth/cclog',
      'https://www.googleapis.com/auth/experimentsandconfigs',
    ],
    callbackPath: '/callback',
    usesPkce: false,
  );

  Future<OAuthCredential> signIn(String providerId) async {
    final config = switch (providerId) {
      'codex' => _codex,
      'claude' => _claude,
      'antigravity' => _antigravity,
      _ => throw OAuthLoginException('OAuth is not supported for $providerId'),
    };

    if (config.clientId.isEmpty) {
      throw OAuthLoginException('$providerId OAuth client ID is not configured in this build');
    }
    if (providerId == 'antigravity' && (config.clientSecret?.isEmpty ?? true)) {
      throw OAuthLoginException(
        'Antigravity OAuth is not configured. Set ANTIGRAVITY_CLIENT_ID and '
        'ANTIGRAVITY_CLIENT_SECRET when building TokenBar.',
      );
    }

    final pkce = _generatePkce();
    OAuthCallbackServer? callback;
    try {
      callback = await OAuthCallbackServer.bind(
        port: config.fixedPort,
        path: config.callbackPath,
      );
      final redirectUri = callback.redirectUri;
      final authorizationUri = _authorizationUri(config, redirectUri, pkce);

      var opened = await launchUrl(
        authorizationUri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (!opened) {
        opened = await launchUrl(authorizationUri, mode: LaunchMode.externalApplication);
      }
      if (!opened) throw OAuthLoginException('Unable to open the OAuth sign-in page');

      final callbackUri = await callback.waitForCallback();
      final error = callbackUri.queryParameters['error'];
      if (error != null) {
        final description = callbackUri.queryParameters['error_description'];
        throw OAuthLoginException(description == null ? 'OAuth failed: $error' : description);
      }

      var code = callbackUri.queryParameters['code'] ?? '';
      var returnedState = callbackUri.queryParameters['state'];
      if (code.contains('#')) {
        final parts = code.split('#');
        code = parts.first;
        if (returnedState == null && parts.length > 1) returnedState = parts[1];
      }
      if (code.isEmpty) throw OAuthLoginException('OAuth callback did not include a code');
      if (returnedState != pkce.state) {
        throw OAuthLoginException('OAuth state verification failed');
      }

      var credential = await _exchange(
        config,
        code,
        redirectUri,
        pkce.codeVerifier,
        pkce.state,
      );

      if (providerId == 'claude') {
        final email = await _claudeEmail(credential.accessToken);
        if (email != null) credential = credential.copyWith(email: email);
      } else if (providerId == 'antigravity') {
        final email = await _googleEmail(credential.accessToken);
        if (email != null) credential = credential.copyWith(email: email);
      }
      return credential;
    } on UnsupportedError catch (e) {
      throw OAuthLoginException(e.message ?? 'OAuth is not available on this platform');
    } finally {
      await callback?.close();
    }
  }

  Uri _authorizationUri(_OAuthConfig config, Uri redirectUri, _Pkce pkce) {
    final params = <String, String>{
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': redirectUri.toString(),
      'scope': config.scopes.join(' '),
      'state': pkce.state,
      if (config.usesPkce) 'code_challenge': pkce.codeChallenge,
      if (config.usesPkce) 'code_challenge_method': 'S256',
    };
    if (config.providerId == 'codex') {
      params.addAll(const {
        'id_token_add_organizations': 'true',
        'codex_cli_simplified_flow': 'true',
        'originator': 'codex_cli_rs',
      });
    } else if (config.providerId == 'claude') {
      params['code'] = 'true';
    } else if (config.providerId == 'antigravity') {
      params.addAll(const {
        'access_type': 'offline',
        'prompt': 'consent',
      });
    }
    return Uri.parse(config.authorizeUrl).replace(queryParameters: params);
  }

  Future<OAuthCredential> _exchange(
    _OAuthConfig config,
    String code,
    Uri redirectUri,
    String codeVerifier,
    String state,
  ) async {
    late http.Response response;
    if (config.providerId == 'claude') {
      response = await _client
          .post(
            Uri.parse(config.tokenUrl),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({
              'grant_type': 'authorization_code',
              'client_id': config.clientId,
              'code': code,
              'redirect_uri': redirectUri.toString(),
              'code_verifier': codeVerifier,
              'state': state,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } else {
      response = await _client
          .post(
            Uri.parse(config.tokenUrl),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Accept': 'application/json',
            },
            body: {
              'grant_type': 'authorization_code',
              'client_id': config.clientId,
              if (config.clientSecret?.isNotEmpty == true) 'client_secret': config.clientSecret!,
              'code': code,
              'redirect_uri': redirectUri.toString(),
              if (config.usesPkce) 'code_verifier': codeVerifier,
            },
          )
          .timeout(const Duration(seconds: 30));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthLoginException('OAuth token exchange failed (HTTP ${response.statusCode})');
    }
    final json = jsonDecode(response.body);
    if (json is! Map) throw OAuthLoginException('OAuth token response was invalid');
    final data = json.cast<String, Object?>();
    final accessToken = data['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw OAuthLoginException('OAuth token response did not include an access token');
    }

    final expiresIn = _asInt(data['expires_in']);
    final idToken = data['id_token'] as String?;
    final idClaims = idToken == null ? null : _decodeJwtPayload(idToken);
    final accessClaims = _decodeJwtPayload(accessToken);
    final claims = idClaims ?? accessClaims;
    final auth = claims?['https://api.openai.com/auth'];
    final authMap = auth is Map ? auth.cast<String, Object?>() : const <String, Object?>{};

    return OAuthCredential(
      accessToken: accessToken,
      refreshToken: data['refresh_token'] as String?,
      idToken: idToken,
      expiresAt: expiresIn == null
          ? null
          : DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
      scope: data['scope'] is String ? data['scope'] as String : null,
      email:
          idClaims?['email'] as String? ??
          accessClaims?['email'] as String? ??
          accessClaims?['preferred_username'] as String?,
      accountId:
          authMap['chatgpt_account_id'] as String? ??
          idClaims?['account_id'] as String? ??
          accessClaims?['account_id'] as String?,
      plan:
          authMap['chatgpt_plan_type'] as String? ??
          idClaims?['plan_type'] as String? ??
          accessClaims?['plan_type'] as String?,
    );
  }

  Future<String?> _claudeEmail(String accessToken) async {
    try {
      final response = await _client
          .get(
            Uri.parse('https://api.anthropic.com/api/oauth/profile'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Accept': 'application/json',
              'anthropic-beta': 'oauth-2025-04-20',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map) return null;
      return parseClaudeProfileEmail(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<String?> _googleEmail(String accessToken) async {
    try {
      final response = await _client
          .get(
            Uri.parse('https://www.googleapis.com/oauth2/v1/userinfo?alt=json'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Accept': 'application/json',
              'x-request-source': 'local',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map) return null;
      final email = json['email'];
      return email is String && email.trim().isNotEmpty ? email.trim() : null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

class _OAuthConfig {
  const _OAuthConfig({
    required this.providerId,
    required this.clientId,
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.scopes,
    required this.callbackPath,
    this.clientSecret,
    this.fixedPort,
    this.usesPkce = true,
  });

  final String providerId;
  final String clientId;
  final String? clientSecret;
  final String authorizeUrl;
  final String tokenUrl;
  final List<String> scopes;
  final String callbackPath;
  final int? fixedPort;
  final bool usesPkce;
}

class _Pkce {
  const _Pkce(this.codeVerifier, this.codeChallenge, this.state);

  final String codeVerifier;
  final String codeChallenge;
  final String state;
}

_Pkce _generatePkce() {
  final verifier = _randomBase64Url(32);
  final challenge = base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
  return _Pkce(verifier, challenge, _randomBase64Url(32));
}

String _randomBase64Url(int bytes) {
  final random = Random.secure();
  final data = List<int>.generate(bytes, (_) => random.nextInt(256), growable: false);
  return base64Url.encode(data).replaceAll('=', '');
}

int? _asInt(Object? value) => value is int ? value : value is num ? value.toInt() : null;

Map<String, Object?>? _decodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final normalized = base64Url.normalize(parts[1]);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final json = jsonDecode(decoded);
    return json is Map ? json.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}
