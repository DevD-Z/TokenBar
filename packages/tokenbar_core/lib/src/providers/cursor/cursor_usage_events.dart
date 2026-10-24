import 'dart:math' as math;

import '../../util/json_utils.dart';
import '../common.dart' show moneyText;

/// One row of `POST https://cursor.com/api/dashboard/get-filtered-usage-events`.
///
/// Field names follow CodexBar's `CursorUsageEvent` / `CursorEventTokenUsage` in
/// `third_party/CodexBar/Sources/CodexBarCore/Providers/Cursor/CursorUsageEventsFetcher.swift`:
/// `timestamp` is Unix milliseconds encoded as a string, `model` is the model id,
/// `tokenUsage` holds the four token counters and `chargedCents` is what the plan
/// actually deducts (in cents).
class CursorUsageEvent {
  const CursorUsageEvent({
    required this.timestampMs,
    required this.model,
    required this.tokens,
    this.chargedCents,
  });

  final int? timestampMs;
  final String model;

  /// Input + output + cache write + cache read tokens.
  final int tokens;

  /// Cursor-metered amount in cents; null when the event omits it or it is invalid.
  final double? chargedCents;

  @override
  bool operator ==(Object other) =>
      other is CursorUsageEvent &&
      other.timestampMs == timestampMs &&
      other.model == model &&
      other.tokens == tokens &&
      other.chargedCents == chargedCents;

  @override
  int get hashCode => Object.hash(timestampMs, model, tokens, chargedCents);
}

/// Per-model totals for one billing cycle, derived only from the events payload.
class CursorModelUsage {
  const CursorModelUsage({
    required this.model,
    required this.events,
    required this.tokens,
    this.chargedUsd,
  });

  final String model;
  final int events;
  final int tokens;

  /// Cursor-metered spend in USD. Null when any event of this model lacks `chargedCents`,
  /// so a partial sum is never shown as the real total.
  final double? chargedUsd;
}

/// Parsed page envelope: Cursor's authoritative `totalUsageEventsCount` (when valid) and
/// every raw event on the page, including rows that lack a timestamp (they still count
/// toward pagination).
typedef CursorUsageEventsPage = ({int? total, List<CursorUsageEvent> events});

const _knownPageKeys = {'totalUsageEventsCount', 'usageEventsDisplay'};

/// Parses one events page. Returns null for responses that are not a recognised
/// envelope (error bodies, malformed counts, non-object rows), so an error can never
/// masquerade as "no usage".
CursorUsageEventsPage? parseCursorUsageEventsPage(Map<String, Object?> json) {
  if (json.isEmpty) return (total: 0, events: const []);
  if (json.keys.any((k) => !_knownPageKeys.contains(k))) return null;
  final rawTotal = json['totalUsageEventsCount'];
  final total = asInt(rawTotal);
  if (total != null && total < 0) return null;
  if (rawTotal != null && total == null && rawTotal is! String) return null;
  final rows = asList(json['usageEventsDisplay']);
  if (rows == null) {
    // The count-only envelope `{"totalUsageEventsCount": N}` is an empty page.
    if (json.length == 1 && total != null) return (total: total, events: const []);
    return null;
  }
  final events = <CursorUsageEvent>[];
  for (final row in rows) {
    final map = asMap(row);
    if (map == null) return null;
    events.add(_parseEvent(map));
  }
  return (total: total, events: events);
}

CursorUsageEvent _parseEvent(Map<String, Object?> json) {
  final usage = asMap(json['tokenUsage']);
  var tokens = 0;
  for (final key in const ['inputTokens', 'outputTokens', 'cacheWriteTokens', 'cacheReadTokens']) {
    final value = asInt(usage?[key]);
    if (value != null && value > 0) tokens += value;
  }
  final charged = asDouble(json['chargedCents']);
  return CursorUsageEvent(
    timestampMs: asInt(json['timestamp']),
    model: asString(json['model']) ?? 'unknown',
    tokens: tokens,
    chargedCents: (charged != null && charged.isFinite && charged >= 0) ? charged : null,
  );
}

/// Joins paginated pages the way CodexBar's `CursorUsageEventsFetcher.fetchAllEvents` does.
///
/// The endpoint has no event id, so when the raw count exceeds Cursor's authoritative
/// total, exact duplicates at adjacent page boundaries are removed (only as many as the
/// surplus proves). Returns null when the pages cannot be reconciled with the total.
List<CursorUsageEvent>? reconcileCursorEventPages(
  List<List<CursorUsageEvent>> pages,
  int? expectedTotal,
) {
  final raw = [for (final page in pages) ...page];
  if (expectedTotal == null) return raw;
  if (raw.length < expectedTotal) return null;
  if (raw.length == expectedTotal) return raw;

  var removalsRemaining = raw.length - expectedTotal;
  final reconciled = <CursorUsageEvent>[...pages.first];
  for (var i = 1; i < pages.length; i++) {
    final overlap = _boundaryOverlap(pages[i - 1], pages[i]);
    final removal = math.min(overlap, removalsRemaining);
    reconciled.addAll(pages[i].skip(removal));
    removalsRemaining -= removal;
  }
  if (removalsRemaining != 0 || reconciled.length != expectedTotal) return null;
  return reconciled;
}

/// Longest suffix of [previous] that equals a prefix of [current].
int _boundaryOverlap(List<CursorUsageEvent> previous, List<CursorUsageEvent> current) {
  final limit = math.min(previous.length, current.length);
  for (var count = limit; count >= 1; count--) {
    final offset = previous.length - count;
    var same = true;
    for (var k = 0; k < count; k++) {
      if (previous[offset + k] != current[k]) {
        same = false;
        break;
      }
    }
    if (same) return count;
  }
  return 0;
}

/// Groups events by model. Events without a valid timestamp are ignored. Sorted by
/// Cursor-metered spend, then tokens, then name, so the biggest consumers come first.
List<CursorModelUsage> summarizeCursorModelUsage(Iterable<CursorUsageEvent> events) {
  final byModel = <String, _ModelAccumulator>{};
  for (final event in events) {
    final ts = event.timestampMs;
    if (ts == null || ts <= 0) continue;
    final acc = byModel.putIfAbsent(event.model, _ModelAccumulator.new);
    acc.add(event);
  }
  final rows = [for (final entry in byModel.entries) entry.value.build(entry.key)];
  rows.sort((a, b) {
    final byUsd = (b.chargedUsd ?? -1).compareTo(a.chargedUsd ?? -1);
    if (byUsd != 0) return byUsd;
    final byTokens = b.tokens.compareTo(a.tokens);
    if (byTokens != 0) return byTokens;
    return a.model.compareTo(b.model);
  });
  return rows;
}

class _ModelAccumulator {
  int events = 0;
  int tokens = 0;
  double cents = 0;
  bool chargedComplete = true;

  void add(CursorUsageEvent event) {
    events += 1;
    tokens += event.tokens;
    final charged = event.chargedCents;
    if (charged == null) {
      chargedComplete = false;
    } else {
      cents += charged;
    }
  }

  CursorModelUsage build(String model) => CursorModelUsage(
    model: model,
    events: events,
    tokens: tokens,
    chargedUsd: chargedComplete ? cents / 100 : null,
  );
}

/// Detail-page rows (label → value) for per-model usage in the current billing cycle.
///
/// [models] is null when the events could not be fully fetched; the row then says so
/// instead of showing numbers that might be partial. Only counts, tokens and metered
/// spend are shown: Cursor publishes no per-model limit, so no per-model percentage is
/// invented.
Map<String, String> cursorModelExtras(List<CursorModelUsage>? models, {int maxRows = 10}) {
  const header = '按模型用量';
  if (models == null) {
    return {header: '暂不可用（事件数据未能完整获取）'};
  }
  if (models.isEmpty) {
    return {header: '本计费周期暂无用量记录'};
  }
  final totalEvents = models.fold<int>(0, (sum, m) => sum + m.events);
  final totalTokens = models.fold<int>(0, (sum, m) => sum + m.tokens);
  final spendKnown = models.every((m) => m.chargedUsd != null);
  final totalUsd = spendKnown ? models.fold<double>(0, (sum, m) => sum + m.chargedUsd!) : null;
  final extras = <String, String>{header: _summaryText(totalEvents, totalTokens, totalUsd)};
  for (final m in models.take(maxRows)) {
    extras['模型 ${m.model}'] = _summaryText(m.events, m.tokens, m.chargedUsd);
  }
  final rest = models.skip(maxRows).toList();
  if (rest.isNotEmpty) {
    final restEvents = rest.fold<int>(0, (sum, m) => sum + m.events);
    extras['其余 ${rest.length} 个模型'] = '$restEvents 次请求';
  }
  return extras;
}

String _summaryText(int events, int tokens, double? usd) {
  final parts = <String>['$events 次请求', '${_compactCount(tokens)} tokens'];
  if (usd != null) parts.add(moneyText(usd, 'USD'));
  return parts.join(' · ');
}

String _compactCount(int n) {
  if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}
