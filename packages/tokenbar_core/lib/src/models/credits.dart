/// A balance or spend figure (Codex credits, Claude extra usage, API balance).
class Credits {
  const Credits({
    required this.id,
    required this.label,
    this.balance,
    this.used,
    this.limit,
    this.currency,
    this.unlimited = false,
    this.resetsAt,
  });

  final String id;
  final String label;

  /// Remaining amount, when the provider reports a balance.
  final double? balance;

  /// Spent amount within [limit], when the provider reports a cap.
  final double? used;
  final double? limit;

  /// ISO currency code, or null for provider-specific units (credits).
  final String? currency;
  final bool unlimited;
  final DateTime? resetsAt;

  double? get usedPercent {
    final u = used;
    final l = limit;
    if (u == null || l == null || l <= 0) return null;
    return (u / l * 100).clamp(0, 100).toDouble();
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (balance != null) 'balance': balance,
    if (used != null) 'used': used,
    if (limit != null) 'limit': limit,
    if (currency != null) 'currency': currency,
    if (unlimited) 'unlimited': true,
    if (resetsAt != null) 'resetsAt': resetsAt!.toUtc().toIso8601String(),
  };

  factory Credits.fromJson(Map<String, Object?> json) => Credits(
    id: json['id'] as String,
    label: json['label'] as String? ?? json['id'] as String,
    balance: (json['balance'] as num?)?.toDouble(),
    used: (json['used'] as num?)?.toDouble(),
    limit: (json['limit'] as num?)?.toDouble(),
    currency: json['currency'] as String?,
    unlimited: json['unlimited'] as bool? ?? false,
    resetsAt: json['resetsAt'] == null ? null : DateTime.tryParse(json['resetsAt'] as String),
  );
}
