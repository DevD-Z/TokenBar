/// Web: no persistent file; history is kept in memory for the session.
class HistoryFile {
  final List<String> _lines = [];

  static Future<HistoryFile> open() async => HistoryFile();

  Future<List<String>> readLines() async => List.of(_lines);

  Future<void> append(List<String> lines) async => _lines.addAll(lines);

  Future<void> rewrite(List<String> lines) async {
    _lines
      ..clear()
      ..addAll(lines);
  }
}
