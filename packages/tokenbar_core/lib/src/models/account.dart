/// How an account's data is obtained.
enum SourceType {
  /// Reuse a local CLI login (Codex auth.json, Claude credentials, ...).
  localCli,

  /// A user-supplied API key / token.
  apiKey;

  static SourceType parse(String? value) =>
      SourceType.values.firstWhere((s) => s.name == value, orElse: () => SourceType.localCli);
}

class AccountConfig {
  const AccountConfig({
    required this.id,
    required this.providerId,
    required this.label,
    this.sourceType = SourceType.localCli,
    this.homeDir,
    this.secret,
    this.enabled = true,
    this.options = const {},
  });

  final String id;
  final String providerId;
  final String label;
  final SourceType sourceType;

  /// Overrides the CLI home (CODEX_HOME / CLAUDE_CONFIG_DIR), enabling
  /// several logged-in accounts of the same provider on one machine.
  final String? homeDir;

  /// API key or token. Never serialized by [toJson]; apps keep it in secure
  /// storage and inject it at runtime.
  final String? secret;
  final bool enabled;
  final Map<String, String> options;

  AccountConfig copyWith({
    String? label,
    SourceType? sourceType,
    String? homeDir,
    bool clearHomeDir = false,
    String? secret,
    bool clearSecret = false,
    bool? enabled,
    Map<String, String>? options,
  }) => AccountConfig(
    id: id,
    providerId: providerId,
    label: label ?? this.label,
    sourceType: sourceType ?? this.sourceType,
    homeDir: clearHomeDir ? null : (homeDir ?? this.homeDir),
    secret: clearSecret ? null : (secret ?? this.secret),
    enabled: enabled ?? this.enabled,
    options: options ?? this.options,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'providerId': providerId,
    'label': label,
    'sourceType': sourceType.name,
    if (homeDir != null) 'homeDir': homeDir,
    'enabled': enabled,
    if (options.isNotEmpty) 'options': options,
  };

  factory AccountConfig.fromJson(Map<String, Object?> json) => AccountConfig(
    id: json['id'] as String,
    providerId: json['providerId'] as String,
    label: json['label'] as String? ?? json['providerId'] as String,
    sourceType: SourceType.parse(json['sourceType'] as String?),
    homeDir: json['homeDir'] as String?,
    secret: json['secret'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    options: ((json['options'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
  );
}
