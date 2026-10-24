import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// `<app support>/history.jsonl`.
class HistoryFile {
  HistoryFile._(this._file);

  final File _file;

  static Future<HistoryFile> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return HistoryFile._(File('${dir.path}${Platform.pathSeparator}history.jsonl'));
  }

  Future<List<String>> readLines() async => await _file.exists() ? _file.readAsLines() : <String>[];

  Future<void> append(List<String> lines) =>
      _file.writeAsString('${lines.join('\n')}\n', mode: FileMode.append, flush: true);

  Future<void> rewrite(List<String> lines) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(lines.isEmpty ? '' : '${lines.join('\n')}\n', flush: true);
    await tmp.rename(_file.path);
  }
}
