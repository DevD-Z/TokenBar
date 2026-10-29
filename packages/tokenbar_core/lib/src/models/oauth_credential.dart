import 'dart:convert';

/// OAuth credentials owned by TokenBar.
///
/// The encoded form is stored only in the platform secure store through
/// AccountConfig.secret. AccountConfig.toJson() never serializes it.
class OAuthCredential {
  const OAuthCredential({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.scope,
    this.email,
    this.accountId,
    this.plan,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final DateTime? expiresAt;
  final String? scope;
  final String? email;
  final String? accountId;
  final String? plan;

  bool expiresWithin(DateTime now, Duration lead) {
    final expires = expiresAt;
    return expires != null && !now.toUtc().add(lead).isBefore(expires.toUtc());
  }

  OAuthCredential copyWith({
    String? accessToken,
    String? refreshToken,
    bool clearRefreshToken = false,
    String? idToken,
    bool clearIdToken = false,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    String? scope,
    String? email,
    String? accountId,
    String? plan,
  }) => OAuthCredential(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: clearRefreshToken ? null : (refreshToken ?? this.refreshToken),
    idToken: clearIdToken ? null : (idToken ?? this.idToken),
    expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
    scope: scope ?? this.scope,
    email: email ?? this.email,
    accountId: accountId ?? this.accountId,
    plan: plan ?? this.plan,
  );

  String encode() => jsonEncode({
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (idToken != null) 'idToken': idToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (scope != null) 'scope': scope,
    if (email != null) 'email': email,
    if (accountId != null) 'accountId': accountId,
    if (plan != null) 'plan': plan,
  });

  static OAuthCredential? decode(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final map = json.cast<String, Object?>();
      final accessToken = map['accessToken'];
      if (accessToken is! String || accessToken.isEmpty) return null;
      return OAuthCredential(
        accessToken: accessToken,
        refreshToken: map['refreshToken'] as String?,
        idToken: map['idToken'] as String?,
        expiresAt: DateTime.tryParse(map['expiresAt'] as String? ?? ''),
        scope: map['scope'] as String?,
        email: map['email'] as String?,
        accountId: map['accountId'] as String?,
        plan: map['plan'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
