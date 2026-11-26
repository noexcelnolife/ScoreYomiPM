/// 指定テキストを含むグリッド行をダンプするデバッグスクリプト（開発時の一時ツール）。
///
/// 使い方: `dart run tool/songdb/debug_rows.dart <page.html> <section> <検索語>`
library;

import 'dart:convert';
import 'dart:io';

import 'wiki_sections.dart';

void main(List<String> args) {
  final page = File(args[0]).readAsStringSync(encoding: utf8);
  final target = args[1];
  final query = args[2].toLowerCase();
  for (final table in extractTables(page)) {
    if (table.sectionKey != target) {
      continue;
    }
    for (var i = 0; i < table.rawRows.length; i++) {
      final row = table.rawRows[i];
      final hit = row.cells.any((c) => c.text.toLowerCase().contains(query));
      if (!hit) {
        continue;
      }
      final marks = row.cells
          .map(
            (c) =>
                '${c.hasGreyBackground ? "灰" : ""}${c.hasPurpleBackground ? "紫" : ""}',
          )
          .join();
      stdout.writeln('--- rawRow#$i [$marks]');
      for (var j = 0; j < row.cells.length; j++) {
        final c = row.cells[j];
        stdout.writeln(
          '  [$j] cs=${c.colSpan} rs=${c.rowSpan} ${c.hasGreyBackground ? "灰" : ""}'
          '${c.hasPurpleBackground ? "紫" : ""} "${c.text}"',
        );
      }
      stdout.writeln('  grid: ${table.grid[i]}');
    }
  }
}
