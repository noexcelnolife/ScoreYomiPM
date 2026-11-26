/// extractTables のデバッグ用スクリプト（開発時の一時ツール）。
///
/// 使い方: `dart run tool/songdb/debug_extract.dart <page.html>`
/// page 内の table/heading 出現状況と extractTables の結果を出力する。
library;

import 'dart:convert';
import 'dart:io';

import 'wiki_sections.dart';

void main(List<String> args) {
  final page = File(args[0]).readAsStringSync(encoding: utf8);
  stdout.writeln('page: ${page.length} chars');
  stdout.writeln("<table 出現数: ${'<table'.allMatches(page).length}");
  stdout.writeln('</table> 出現数: ${'</table>'.allMatches(page).length}');

  final hrx = RegExp(
    r'<h([234])\b[^>]*>([\s\S]*?)</h\1>',
    caseSensitive: false,
  );
  for (final m in hrx.allMatches(page)) {
    final norm = normalizedHeading(m.group(2)!);
    stdout.writeln('h${m.group(1)}: "$norm"');
  }

  final tables = extractTables(page);
  stdout.writeln('extractTables: ${tables.length} 件');
  for (final t in tables) {
    stdout.writeln('  section=${t.sectionKey} rows=${t.rawRows.length}');
  }
}
