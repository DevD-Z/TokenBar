import 'dart:convert';

import 'package:tokenbar_core/tokenbar_core.dart';

import 'history_file.dart';

/// Local usage history. Full resolution for 2 days, hourly up to 90 days.
class HistoryStore {
  HistoryStore._(this._file, this._points);

  /// Memory-only history (demo mode); nothing is written to disk.
  HistoryStore.demo(List<UsagePoint> points) : _file = null, _points = [...points];

  static const retention = Duration(days: 90);
  static const fullResolution = Duration(days: 2);

  final HistoryFile? _file;
  final List<UsagePoint> _points;
  DateTime _lastCompaction = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<HistoryStore> open() async {
    final file = await HistoryFile.open();
    final points = <UsagePoint>[];
    for (final line in await file.readLines()) {
      if (line.trim().isEmpty) continue;
      try {
        points.add(UsagePoint.fromJson(jsonDecode(line) as Map<String, Object?>));
      } catch (_) {}
    }
    final store = HistoryStore._(file, points);
    await store._compact(DateTime.now());
    return store;
  }

  List<UsagePoint> query(String accountId, DateTime since) =>
      _points.where((p) => p.accountId == accountId && !p.at.isBefore(since)).toList();

  Future<void> add(Iterable<UsageSnapshot> snapshots) async {
    final points = snapshots.map(UsagePoint.fromSnapshot).whereType<UsagePoint>().toList();
    if (points.isEmpty) return;
    _points.addAll(points);
    await _file?.append(points.map((p) => jsonEncode(p.toJson())).toList());
    final now = DateTime.now();
    if (now.difference(_lastCompaction) > const Duration(hours: 6)) {
      await _compact(now);
    }
  }

  Future<void> removeAccount(String accountId) async {
    _points.removeWhere((p) => p.accountId == accountId);
    await _file?.rewrite(_points.map((p) => jsonEncode(p.toJson())).toList());
  }

  Future<void> _compact(DateTime now) async {
    _lastCompaction = now;
    final cutoff = now.subtract(retention);
    final recentCutoff = now.subtract(fullResolution);
    final old = _points.where((p) => p.at.isAfter(cutoff) && p.at.isBefore(recentCutoff)).toList();
    final recent = _points.where((p) => !p.at.isBefore(recentCutoff)).toList();
    final compacted = [...downsample(old, const Duration(hours: 1)), ...recent];
    if (compacted.length == _points.length) return;
    _points
      ..clear()
      ..addAll(compacted);
    await _file?.rewrite(_points.map((p) => jsonEncode(p.toJson())).toList());
  }
}
