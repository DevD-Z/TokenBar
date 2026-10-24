import 'dart:convert';
import 'dart:math' as math;

import '../../util/json_utils.dart';

/// Codex session-log parsing (`~/.codex/sessions/**/rollout-*.jsonl`), only numbers and the
/// model name are read — never prompts, file paths or any conversation content.
///
/// Semantics follow CodexBar's `CostUsageScanner` (native Codex logs) in
/// `third_party/CodexBar/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift`:
///
/// * `event_msg` lines with `payload.type == "token_count"` carry `payload.info` with
///   `last_token_usage` (this request) and `total_token_usage` (cumulative for the thread),
///   each `{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}`.
///   `input_tokens` includes the cached reads; reasoning is a subset of output.
/// * The model comes from the latest `turn_context` line (`payload.model`, then
///   `model_name`, then the same keys inside `payload.info`); an explicitly empty value
///   clears it. Without a turn context the token_count record's own model fields are used
///   (`info.model`, `info.model_name`, `payload.model`, `model`), else `unknown`.
/// * Deltas come from `last_token_usage`, cross-checked against the cumulative totals:
///   exact re-emitted snapshots are skipped, a snapshot that regresses by about one recent
///   increment is stale and skipped, a counter drop latches "interleaved" mode in which
///   only growth above the high watermark is counted (CodexBar's `CodexTotalsTracker`).
/// * Simplification for forks: the first `session_meta` of a file naming a parent
///   (`forked_from_id` / `parent_session_id`) marks events older than its `timestamp` as
///   inherited history. They still feed the counters but are not reported. CodexBar
///   additionally resolves the parent file's baseline; subagent ordinals and paginated
///   continuation files are not handled here.

/// Token counters of one `*_token_usage` object (all clamped to >= 0).
class CodexTotals {
  const CodexTotals({
    required this.input,
    required this.cached,
    required this.output,
    this.reasoning,
  });

  final int input;
  final int cached;
  final int output;
  final int? reasoning;

  static const zero = CodexTotals(input: 0, cached: 0, output: 0);

  /// Parses a `last_token_usage` / `total_token_usage` object; null when it is not a map.
  static CodexTotals? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    int integer(String key) {
      final value = map[key];
      return value is num && value.isFinite ? math.max(0, value.toInt()) : 0;
    }

    final output = integer('output_tokens');
    final reasoningRaw = map['reasoning_output_tokens'];
    return CodexTotals(
      input: integer('input_tokens'),
      cached: math.max(integer('cached_input_tokens'), integer('cache_read_input_tokens')),
      output: output,
      reasoning: reasoningRaw is num && reasoningRaw.isFinite
          ? math.min(math.max(0, reasoningRaw.toInt()), output)
          : null,
    );
  }

  bool get isZero => input == 0 && cached == 0 && output == 0;

  bool sameCounters(CodexTotals? other) =>
      other != null && input == other.input && cached == other.cached && output == other.output;

  bool atLeast(CodexTotals other) =>
      input >= other.input && cached >= other.cached && output >= other.output;

  bool atMost(CodexTotals other) =>
      input <= other.input && cached <= other.cached && output <= other.output;

  CodexTotals plus(CodexTotals other) => CodexTotals(
    input: input + other.input,
    cached: cached + other.cached,
    output: output + other.output,
    reasoning: _both(reasoning, other.reasoning, (a, b) => a + b),
  );

  CodexTotals min(CodexTotals other) => CodexTotals(
    input: math.min(input, other.input),
    cached: math.min(cached, other.cached),
    output: math.min(output, other.output),
    reasoning: _both(reasoning, other.reasoning, math.min),
  );

  CodexTotals max(CodexTotals other) => CodexTotals(
    input: math.max(input, other.input),
    cached: math.max(cached, other.cached),
    output: math.max(output, other.output),
    reasoning: switch ((reasoning, other.reasoning)) {
      (final a?, final b?) => math.max(a, b),
      (final a?, null) => a,
      (null, final b?) => b,
      (null, null) => null,
    },
  );

  static int? _both(int? a, int? b, int Function(int, int) f) =>
      (a == null || b == null) ? null : f(a, b);
}

/// Tokens a single `token_count` event added, ready for aggregation.
class CodexTokenDelta {
  const CodexTokenDelta({
    required this.time,
    required this.model,
    required this.input,
    required this.cached,
    required this.output,
  });

  final DateTime time;
  final String model;

  /// Whole prompt, cached reads included.
  final int input;
  final int cached;
  final int output;

  /// Tokens as Codex reports `total_tokens`: input + output (cached is a subset of input,
  /// reasoning a subset of output).
  int get tokens => input + output;
}

/// Model name used when a token_count has no model evidence at all (CodexBar's
/// `codexUnattributedModel`).
const codexUnknownModel = 'unknown';

/// Line-by-line parser for one session file. Feed lines in file order with [addLine];
/// it returns the delta that line contributed, or null.
class CodexSessionParser {
  static const _seenLimit = 64;

  String? _currentModel;
  bool _sawSessionMeta = false;
  DateTime? _inheritedBefore;

  CodexTotals? _counted; // previousTotals
  CodexTotals? _rawBaseline;
  bool _sawDivergent = false;
  CodexTotals? _watermark;
  final List<CodexTotals> _seen = [];
  bool _interleaved = false;

  /// Cheap pre-filter; lines that cannot be relevant are never JSON-decoded.
  static bool isRelevantLine(String line) =>
      line.contains('"token_count"') ||
      line.contains('"turn_context"') ||
      line.contains('"session_meta"');

  CodexTokenDelta? addLine(String line) {
    if (!isRelevantLine(line)) return null;
    final Map<String, Object?>? obj;
    try {
      obj = asMap(jsonDecode(line));
    } on FormatException {
      return null;
    }
    if (obj == null) return null;
    final payload = asMap(obj['payload']);
    switch (obj['type']) {
      case 'session_meta':
        _onSessionMeta(obj, payload);
        return null;
      case 'turn_context':
        _onTurnContext(payload);
        return null;
      case 'event_msg':
        if (payload == null || payload['type'] != 'token_count') return null;
        return _onTokenCount(obj, payload);
    }
    return null;
  }

  void _onSessionMeta(Map<String, Object?> obj, Map<String, Object?>? payload) {
    // Only the first session_meta is the file's own identity; copied ancestor prefixes
    // can contain many more.
    if (_sawSessionMeta) return;
    _sawSessionMeta = true;
    String? parent;
    for (final key in const [
      'forked_from_id',
      'forkedFromId',
      'parent_session_id',
      'parentSessionId',
    ]) {
      parent = asString(payload?[key]);
      if (parent != null) break;
    }
    if (parent == null) return;
    final stamp = asString(payload?['timestamp']) ?? asString(obj['timestamp']);
    _inheritedBefore = stamp == null ? null : DateTime.tryParse(stamp);
  }

  void _onTurnContext(Map<String, Object?>? payload) {
    if (payload == null) return;
    final info = asMap(payload['info']);
    var sawCandidate = false;
    String? model;
    for (final candidate in [
      payload['model'],
      payload['model_name'],
      info?['model'],
      info?['model_name'],
    ]) {
      if (candidate is! String) continue;
      sawCandidate = true;
      final trimmed = candidate.trim();
      if (trimmed.isNotEmpty) {
        model = trimmed;
        break;
      }
    }
    // Omitted fields keep the previous model; an explicitly blank one clears it.
    if (model != null) {
      _currentModel = model;
    } else if (sawCandidate) {
      _currentModel = null;
    }
  }

  CodexTokenDelta? _onTokenCount(Map<String, Object?> obj, Map<String, Object?> payload) {
    final info = asMap(payload['info']);
    final stamp = asString(obj['timestamp']);
    if (info == null || stamp == null) return null;
    final time = DateTime.tryParse(stamp);
    if (time == null) return null;
    final last = CodexTotals.fromJson(info['last_token_usage']);
    final total = CodexTotals.fromJson(info['total_token_usage']);
    final model =
        _currentModel ??
        asString(info['model']) ??
        asString(info['model_name']) ??
        asString(payload['model']) ??
        asString(obj['model']) ??
        codexUnknownModel;

    final delta = _apply(last, total);
    if (delta == null || delta.isZero) return null;
    final cutoff = _inheritedBefore;
    if (cutoff != null && time.isBefore(cutoff)) return null;
    return CodexTokenDelta(
      time: time,
      model: model,
      input: delta.input,
      cached: math.min(delta.cached, delta.input),
      output: delta.output,
    );
  }

  /// Port of CodexBar's non-fork `handleTokenCount` delta accounting. Returns the delta of
  /// this event (null when the event is skipped as re-emitted / stale / empty).
  CodexTotals? _apply(CodexTotals? last, CodexTotals? total) {
    if (total != null) {
      if (_seen.any(total.sameCounters)) return null;
      final staleBaseline = _watermark ?? _rawBaseline;
      if (staleBaseline != null &&
          _looksLikeStaleRegression(total, staleBaseline, last ?? CodexTotals.zero)) {
        return null;
      }
      final mark = _watermark;
      if (mark != null &&
          (total.input < mark.input || total.cached < mark.cached || total.output < mark.output)) {
        _interleaved = true;
      }
    }
    final watermarkBaseline = _watermark ?? _rawBaseline;

    CodexTotals delta;
    if (last != null) {
      delta = last;
      if (total != null) {
        if (_interleaved) {
          delta = _postLatchEventDelta(watermarkBaseline, _counted, total, delta);
        } else {
          final totalDelta = _totalDelta(watermarkBaseline, total);
          if (_shouldPreferTotalDelta(watermarkBaseline, total, totalDelta, last)) {
            delta = totalDelta;
          }
        }
        _commit(delta, total);
      } else {
        final counted = (_counted ?? _zeroLike(delta)).plus(delta);
        _counted = counted;
        _rawBaseline = counted;
        _watermark = _watermark == null ? counted : _watermark!.max(counted);
      }
    } else if (total != null) {
      delta = _interleaved
          ? _containedTotalDelta(watermarkBaseline, _counted, total)
          : _sawDivergent
          ? _divergentTotalDelta(watermarkBaseline, _counted, total)
          : _totalDelta(watermarkBaseline, total);
      _commit(delta, total);
    } else {
      return null;
    }

    if (total != null) _commitObserved(total);
    return delta;
  }

  CodexTotals _zeroLike(CodexTotals sample) =>
      CodexTotals(input: 0, cached: 0, output: 0, reasoning: sample.reasoning == null ? null : 0);

  void _commit(CodexTotals delta, CodexTotals rawBaseline) {
    final previous = _counted ?? _zeroLike(delta);
    final next = previous.plus(delta);
    _counted = next;
    _rawBaseline = rawBaseline;
    if (!rawBaseline.sameCounters(next)) _sawDivergent = true;
  }

  void _commitObserved(CodexTotals total) {
    _watermark = _watermark == null ? total : _watermark!.max(total);
    if (!_seen.any(total.sameCounters)) {
      _seen.add(total);
      if (_seen.length > _seenLimit) _seen.removeRange(0, _seen.length - _seenLimit);
    }
  }

  // ---- delta helpers (CodexBar `codexTotalDelta` & friends) ----

  static int _clamp(int value) => value < 0 ? 0 : value;

  static CodexTotals _totalDelta(CodexTotals? baseline, CodexTotals current) {
    final b = baseline ?? CodexTotals.zero;
    final int? reasoning = baseline == null
        ? current.reasoning
        : (current.reasoning == null || b.reasoning == null)
        ? null
        : _clamp(current.reasoning! - b.reasoning!);
    return CodexTotals(
      input: _clamp(current.input - b.input),
      cached: _clamp(current.cached - b.cached),
      output: _clamp(current.output - b.output),
      reasoning: reasoning,
    );
  }

  static CodexTotals _divergentTotalDelta(
    CodexTotals? rawBaseline,
    CodexTotals? countedBaseline,
    CodexTotals current,
  ) {
    final raw = rawBaseline ?? CodexTotals.zero;
    final counted = countedBaseline ?? CodexTotals.zero;
    int component(int r, int c, int cur) => cur >= r ? _clamp(cur - r) : _clamp(cur - c);
    int? optional(int? r, int? c, int? cur) =>
        (r == null || c == null || cur == null) ? null : component(r, c, cur);
    return CodexTotals(
      input: component(raw.input, counted.input, current.input),
      cached: component(raw.cached, counted.cached, current.cached),
      output: component(raw.output, counted.output, current.output),
      reasoning: optional(raw.reasoning, counted.reasoning, current.reasoning),
    );
  }

  static CodexTotals _containedTotalDelta(
    CodexTotals? watermark,
    CodexTotals? counted,
    CodexTotals current,
  ) {
    final water = watermark ?? CodexTotals.zero;
    final done = counted ?? CodexTotals.zero;
    int component(int w, int c, int cur) =>
        cur >= w ? _clamp(cur - math.max(w, c)) : _clamp(cur - c);
    int? optional(int? w, int? c, int? cur) =>
        (w == null || c == null || cur == null) ? null : component(w, c, cur);
    return CodexTotals(
      input: component(water.input, done.input, current.input),
      cached: component(water.cached, done.cached, current.cached),
      output: component(water.output, done.output, current.output),
      reasoning: optional(water.reasoning, done.reasoning, current.reasoning),
    );
  }

  static CodexTotals _postLatchEventDelta(
    CodexTotals? watermark,
    CodexTotals? counted,
    CodexTotals current,
    CodexTotals adjustedLast,
  ) => adjustedLast.min(_containedTotalDelta(watermark, counted, current));

  /// CodexBar's `codexShouldPreferTotalDelta`: only while the counted and raw counters
  /// have never diverged, and when the cumulative growth is not larger than `last`.
  bool _shouldPreferTotalDelta(
    CodexTotals? rawBaseline,
    CodexTotals currentTotal,
    CodexTotals totalDelta,
    CodexTotals lastDelta,
  ) {
    if (_sawDivergent || rawBaseline == null) return false;
    return currentTotal.atLeast(rawBaseline) && totalDelta.atMost(lastDelta);
  }

  static bool _looksLikeStaleRegression(
    CodexTotals current,
    CodexTotals previous,
    CodexTotals last,
  ) {
    final reasoningRegressed =
        current.reasoning != null &&
        previous.reasoning != null &&
        current.reasoning! < previous.reasoning!;
    if (!(current.input < previous.input ||
        current.cached < previous.cached ||
        current.output < previous.output ||
        reasoningRegressed)) {
      return false;
    }
    int sum(CodexTotals t) => t.input + t.output + t.cached + (t.reasoning ?? 0);
    final previousTotal = sum(previous);
    final currentTotal = sum(current);
    final lastTotal = sum(last);
    if (previousTotal <= 0 || currentTotal <= 0 || lastTotal <= 0) return false;
    return currentTotal * 100 >= previousTotal * 98 ||
        currentTotal + lastTotal * 2 >= previousTotal;
  }
}
