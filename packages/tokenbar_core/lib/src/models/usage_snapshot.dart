import 'credits.dart';
import 'rate_window.dart';

/// Result of one fetch for one account. Either carries data or an error.
class UsageSnapshot {
  const UsageSnapshot({
    required this.accountId,
    required this.providerId,
    required this.fetchedAt,
    this.accountLabel,
    this.plan,
    this.email,
    this.source,
    this.windows = const [],
    this.credits = const [],
    this.extras = const {},
    this.error,
    this.errorHint,
    this.origin,
  });

  factory UsageSnapshot.failure({
    required String accountId,
    required String providerId,
    required DateTime fetchedAt,
    required String error,
    String? errorHint,
    String? accountLabel,
    String? source,
  }) => UsageSnapshot(
    accountId: accountId,
    providerId: providerId,
    fetchedAt: fetchedAt,
    accountLabel: accountLabel,
    source: source,
    error: error,
    errorHint: errorHint,
  );

  final String accountId;
  final String providerId;
  final DateTime fetchedAt;
  final String? accountLabel;
  final String? plan;
  final String? email;

  /// How the data was obtained: `oauth`, `cli-rpc`, `api-key`, `remote`.
  final String? source;
  final List<RateWindow> windows;
  final List<Credits> credits;

  /// Free-form provider facts worth showing (e.g. rate-limit tier).
  final Map<String, String> extras;
  final String? error;
  final String? errorHint;

  /// Device/collector name that produced this snapshot (for synced data).
  final String? origin;

  bool get hasError => error != null;
  bool get hasData => windows.isNotEmpty || credits.isNotEmpty;

  RateWindow? window(String id) {
    for (final w in windows) {
      if (w.id == id) return w;
    }
    return null;
  }

  RateWindow? get session => window(RateWindow.sessionId);
  RateWindow? get weekly => window(RateWindow.weeklyId);

  /// The most constrained window (lowest remaining) – drives tray/widget.
  RateWindow? get tightestWindow {
    RateWindow? best;
    for (final w in windows) {
      if (best == null || w.remainingPercent < best.remainingPercent) best = w;
    }
    return best;
  }

  /// For a failed fetch, keeps [previous]'s data (and its timestamp) while
  /// surfacing this error, so a transient failure does not blank the UI.
  UsageSnapshot retainingDataFrom(UsageSnapshot? previous) {
    if (!hasError || previous == null || !previous.hasData) return this;
    return UsageSnapshot(
      accountId: accountId,
      providerId: providerId,
      fetchedAt: previous.fetchedAt,
      accountLabel: accountLabel ?? previous.accountLabel,
      plan: previous.plan,
      email: previous.email,
      source: previous.source,
      windows: previous.windows,
      credits: previous.credits,
      extras: previous.extras,
      error: error,
      errorHint: errorHint,
      origin: origin ?? previous.origin,
    );
  }

  UsageSnapshot copyWith({String? accountLabel, String? origin, String? email, String? plan}) =>
      UsageSnapshot(
        accountId: accountId,
        providerId: providerId,
        fetchedAt: fetchedAt,
        accountLabel: accountLabel ?? this.accountLabel,
        plan: plan ?? this.plan,
        email: email ?? this.email,
        source: source,
        windows: windows,
        credits: credits,
        extras: extras,
        error: error,
        errorHint: errorHint,
        origin: origin ?? this.origin,
      );

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'providerId': providerId,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    if (accountLabel != null) 'accountLabel': accountLabel,
    if (plan != null) 'plan': plan,
    if (email != null) 'email': email,
    if (source != null) 'source': source,
    'windows': windows.map((w) => w.toJson()).toList(),
    if (credits.isNotEmpty) 'credits': credits.map((c) => c.toJson()).toList(),
    if (extras.isNotEmpty) 'extras': extras,
    if (error != null) 'error': error,
    if (errorHint != null) 'errorHint': errorHint,
    if (origin != null) 'origin': origin,
  };

  factory UsageSnapshot.fromJson(Map<String, Object?> json) => UsageSnapshot(
    accountId: json['accountId'] as String,
    providerId: json['providerId'] as String,
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    accountLabel: json['accountLabel'] as String?,
    plan: json['plan'] as String?,
    email: json['email'] as String?,
    source: json['source'] as String?,
    windows: ((json['windows'] as List?) ?? const [])
        .map((e) => RateWindow.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
    credits: ((json['credits'] as List?) ?? const [])
        .map((e) => Credits.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
    extras: ((json['extras'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
    error: json['error'] as String?,
    errorHint: json['errorHint'] as String?,
    origin: json['origin'] as String?,
  );
}
