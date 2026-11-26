/// ページ HTML から「見出し直後の table」を抽出し、既知セクションに分類する。
///
/// WHY: bemaniwiki の旧曲/新曲リストページは「h3 見出し → style_table」の繰り返しで、
/// 見出し配下の最初の table が曲リスト本体。備考セクション（CS初出別リスト等）の
/// table は誤って取り込まないよう、直前の見出しで分類し既知キー以外は捨てる
/// （設計レポート §2.1）。
library;

import 'wiki_html.dart';

/// セクションキー。
/// ac: 旧曲リスト・AC版カテゴリ / cs: 家庭用(CS) / ee: ee'MALL /
/// new-main: 新曲リストの曲・難易度表 / new-notes: 新曲リストのキャラ・総ノーツ数表。
class WikiTable {
  WikiTable(this.sectionKey, this.heading, this.rawRows, this.grid);

  final String? sectionKey;
  final String heading;
  final List<HtmlRow> rawRows;
  final List<GridRow> grid;
}

const Map<String, String> _sectionByHeading = <String, String>{
  '楽曲リスト': 'ac',
  "pop'nmusic家庭用(CS)": 'cs',
  "ee'MALL": 'ee',
  '曲名、アーティスト、BPM、難易度': 'new-main',
  'キャラ・総ノーツ数': 'new-notes',
};

/// 見出しテキストを分類キーに正規化する（†・[ ↑ ] 装飾と空白を除去）。
String normalizedHeading(String rawHeadingHtml) {
  // WHY: PukiWiki の見出しアンカーは「†」を実体参照 &dagger; で出力するため、
  // タグ除去後に実体参照をデコードしてから † を除去する。デコードしないと
  // 「楽曲リスト&dagger;」のまま分類キーと一致しない（実機確認 2026-11-22）。
  var text = decodeEntities(stripMarkup(rawHeadingHtml));
  text = text.replaceAll('†', '').replaceAll('↑', '');
  text = text.replaceAll('[', '').replaceAll(']', '');
  return text.replaceAll(RegExp(r'\s+'), '');
}

/// ページ HTML から既知セクションの table のみを抽出する。
List<WikiTable> extractTables(String page) {
  final headings = _headingSpans(page);
  final result = <WikiTable>[];
  for (final span in _tableSpans(page)) {
    final heading = _nearestHeadingBefore(headings, span.$1);
    if (heading == null) {
      continue;
    }
    final normalized = normalizedHeading(heading.$2);
    final sectionKey = _sectionByHeading[normalized];
    if (sectionKey == null) {
      continue;
    }
    final rawRows = rowsOf(span.$2);
    result.add(WikiTable(sectionKey, normalized, rawRows, expandGrid(rawRows)));
  }
  return result;
}

typedef _Span = (int, String);

/// h2/h3/h4 見出しの (本文終了位置, 生本文) 一覧。
List<_Span> _headingSpans(String page) {
  final result = <_Span>[];
  final open = RegExp(r'<h[234]\b[^>]*>', caseSensitive: false);
  var from = 0;
  while (true) {
    final m = open.firstMatch(page.substring(from));
    if (m == null) {
      return result;
    }
    final bodyStart = from + m.end;
    final level = page.substring(from + m.start, from + m.end);
    // WHY: 終了タグは「</h3>」のように h+レベル数字。level[1]='h'、level[2]='3'。
    // レベル数字のみ（</3>）を探すと常に -1 になり見出しが 1 件も取れない
    // （実機データで確認した不具合・2026-11-22）。
    final closeTag = '</${level[1]}${level[2]}>';
    final close = page.indexOf(closeTag, bodyStart);
    if (close < 0) {
      return result;
    }
    result.add((close, page.substring(bodyStart, close)));
    from = close + closeTag.length;
  }
}

/// table の (開始位置, 生本文) 一覧（ネスト対応の深さスタック走査）。
List<_Span> _tableSpans(String page) {
  final open = RegExp('<table\\b[^>]*>', caseSensitive: false);
  final close = RegExp('</table>', caseSensitive: false);
  final events = <(int, String)>[];
  for (final m in open.allMatches(page)) {
    events.add((m.start, 'o'));
  }
  for (final m in close.allMatches(page)) {
    events.add((m.start, 'c'));
  }
  events.sort((a, b) => a.$1.compareTo(b.$1));
  final result = <_Span>[];
  final stack = <int>[];
  var bodyStart = -1;
  for (final e in events) {
    if (e.$2 == 'o') {
      if (stack.isEmpty) {
        bodyStart = e.$1;
      }
      stack.add(e.$1);
    } else {
      if (stack.isEmpty) {
        continue;
      }
      stack.removeLast();
      if (stack.isEmpty) {
        final openTagEnd = page.indexOf('>', bodyStart);
        result.add((bodyStart, page.substring(openTagEnd + 1, e.$1)));
      }
    }
  }
  return result;
}

_Span? _nearestHeadingBefore(List<_Span> headings, int position) {
  _Span? best;
  for (final h in headings) {
    if (h.$1 < position) {
      best = h;
    }
  }
  return best;
}
