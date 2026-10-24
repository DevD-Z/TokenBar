import 'dart:convert';
import 'dart:io';

import 'package:tokenbar_core/tokenbar_core.dart';

/// File-backed storage: `latest.json` + monthly JSONL history files.
class SnapshotStore {
  SnapshotStore(this.dataDir, {this.retention = const Duration(days: 90)}) {
    Directory(_historyDir).createSync(recursive: true);
    final file = File(_latestPath);
    if (file.existsSync()) {
      try {
        final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        for (final entry in json.entries) {
          _latest[entry.key] = UsageSnapshot.fromJson((entry.value as Map).cast<String, Object?>());
        }
      } catch (_) {
        // Corrupt file: start fresh rather than refusing to boot.
      }
    }
  }

  final String dataDir;
  final Duration retention;
  final Map<String, UsageSnapshot> _latest = {};

  String get _latestPath => '$dataDir${Platform.pathSeparator}latest.json';
  String get _historyDir => '$dataDir${Platform.pathSeparator}history';

  List<UsageSnapshot> latest() {
    final list = _latest.values.toList()..sort((a, b) => a.accountId.compareTo(b.accountId));
    return list;
  }

  Future<void> put(Iterable<UsageSnapshot> snapshots) async {
    final points = <UsagePoint>[];
    for (final s in snapshots) {
      _latest[s.accountId] = s.retainingDataFrom(_latest[s.accountId]);
      final p = UsagePoint.fromSnapshot(s);
      if (p != null) points.add(p);
    }
    await _writeLatest();
    if (points.isNotEmpty) await _appendHistory(points);
  }

  Future<void> remove(String accountId) async {
    _latest.remove(accountId);
    await _writeLatest();
  }

  Future<List<UsagePoint>> history({String? accountId, DateTime? since}) async {
    final from = since ?? DateTime.now().toUtc().subtract(const Duration(days: 7));
    final result = <UsagePoint>[];
    final dir = Directory(_historyDir);
    if (!dir.existsSync()) return result;
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jsonl'))
            .where((f) => _monthOf(f.path).compareTo(_monthKey(from)) >= 0)
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final p = UsagePoint.fromJson(jsonDecode(line) as Map<String, Object?>);
          if (p.at.isBefore(from)) continue;
          if (accountId != null && p.accountId != accountId) continue;
          result.add(p);
        } catch (_) {}
      }
    }
    return result;
  }

  Future<void> _writeLatest() async {
    final json = {for (final e in _latest.entries) e.key: e.value.toJson()};
    final tmp = File('$_latestPath.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(_latestPath);
  }

  Future<void> _appendHistory(List<UsagePoint> points) async {
    final now = DateTime.now().toUtc();
    final file = File('$_historyDir${Platform.pathSeparator}${_monthKey(now)}.jsonl');
    await file.writeAsString(
      '${points.map((p) => jsonEncode(p.toJson())).join('\n')}\n',
      mode: FileMode.append,
      flush: true,
    );
    _prune(now);
  }

  void _prune(DateTime now) {
    final cutoff = _monthKey(now.subtract(retention + const Duration(days: 31)));
    for (final f in Directory(_historyDir).listSync().whereType<File>()) {
      if (f.path.endsWith('.jsonl') && _monthOf(f.path).compareTo(cutoff) < 0) {
        f.deleteSync();
      }
    }
  }

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String _monthOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.replaceAll('.jsonl', '');
  }
}
