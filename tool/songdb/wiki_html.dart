/// bemaniwiki（PukiWiki）HTML の最小限パース補助。
///
/// WHY: 依存追加を最小化するため html パッケージ等は使わず、対象ページ
/// （PM HC の旧曲/新曲リスト）の style_table に必要な範囲だけを
/// 自前スキャナで処理する（設計確認レポート
/// docs/song_db_design_confirmation_report_2026-11-22.md §4「HTML 直パース・markdown 経由回避」）。
///
/// 前提: テーブルセル内にネストした table は存在しない（実データ検証済み）。
library;

/// テーブルセル（<td>/<th>）の生情報。
class HtmlCell {
  const HtmlCell(this.text, this.colSpan, this.rowSpan, this.style);

  /// 装飾タグ除去・エンティティ復号・空白正規化済みのセル内テキスト。
  final String text;

  final int colSpan;
  final int rowSpan;

  /// 背景色判定（消滅曲 #ddd / 旧曲譜面追加行 #EEE7FF）用の style 生値。
  final String style;

  bool get hasGreyBackground =>
      style.toLowerCase().contains('background-color:#ddd');

  bool get hasPurpleBackground =>
      style.toLowerCase().contains('background-color:#eee7ff');
}

/// 展開済みグリッドの 1 行（列位置正・テキスト正）。
typedef GridRow = List<String>;

/// `<tag ...> ... </tag>` 本文を順に返す（非ネスト前提・PukiWiki は閉じタグ必須）。
List<String> tagBodies(String html, String tag) {
  final open = RegExp('<$tag(\\s[^>]*)?>');
  final result = <String>[];
  var from = 0;
  while (true) {
    final m = open.firstMatch(html.substring(from));
    if (m == null) {
      return result;
    }
    final bodyStart = from + m.end;
    final close = html.indexOf('</$tag>', bodyStart);
    if (close < 0) {
      return result;
    }
    result.add(html.substring(bodyStart, close));
    from = close + ('</$tag>'.length);
  }
}

/// `<table ...> ... </table>` 本文を順に返す。
List<String> tableBodies(String html) => tagBodies(html, 'table');

/// 1 行本文からセル（<td>/<th>）を生パースする。
List<HtmlCell> parseCells(String trBody) {
  // WHY: 閉じタグは「開きタグ直後」ではなくセル本文の後に来る。matchAsPrefix
  // （直後限定）を使うと空セルしか取れず、内容のあるセルの raw が行末まで
  // 伸びて後続セルを吸い込む（実機データで確認した不具合・2026-11-22）。
  // 開き/閉じの全マッチを先に収集し、 tandem 走査で対応付ける（セルのネスト前提なし）。
  final cells = <HtmlCell>[];
  final opens = _cellOpenPattern.allMatches(trBody).toList();
  final closes = _cellClosePattern.allMatches(trBody).toList();
  var closeIdx = 0;
  for (final m in opens) {
    final tagEnd = trBody.indexOf('>', m.start);
    if (tagEnd < 0) {
      continue;
    }
    while (closeIdx < closes.length && closes[closeIdx].start <= tagEnd) {
      closeIdx++;
    }
    final raw = closeIdx < closes.length
        ? trBody.substring(tagEnd + 1, closes[closeIdx].start)
        : trBody.substring(tagEnd + 1);
    cells.add(
      HtmlCell(
        stripMarkup(raw),
        _intAttr(trBody, m.start, 'colspan'),
        _intAttr(trBody, m.start, 'rowspan'),
        _styleAttr(trBody, m.start),
      ),
    );
  }
  return cells;
}

final _cellOpenPattern = RegExp('<t[dh]\\b[^>]*>', caseSensitive: false);
final _cellClosePattern = RegExp('</t[dh]\\b[^>]*>', caseSensitive: false);

/// 開始タグ内の属性値を整数で返す（範囲外は 1 に丸め）。
int _intAttr(String s, int tagStart, String name) {
  final tagEnd = s.indexOf('>', tagStart);
  if (tagEnd < 0) {
    return 1;
  }
  final m = RegExp(
    '$name="?(\\d+)',
    caseSensitive: false,
  ).firstMatch(s.substring(tagStart, tagEnd));
  final v = int.tryParse(m?.group(1) ?? '') ?? 1;
  return v < 1 ? 1 : (v > 12 ? 12 : v);
}

String _styleAttr(String s, int tagStart) {
  final tagEnd = s.indexOf('>', tagStart);
  if (tagEnd < 0) {
    return '';
  }
  final m = RegExp(
    'style="([^"]*)"',
    caseSensitive: false,
  ).firstMatch(s.substring(tagStart, tagEnd));
  return m?.group(1) ?? '';
}

class _CarriedSpan {
  const _CarriedSpan(this.text, this.rowsLeft);

  final String text;
  final int rowsLeft;
}

/// 行リストを colspan/rowspan 展開済みテキストマトリクスへ変換する。
///
/// WHY: (1) アーティストセルの rowspan=2（例: Ado の「うっせぇわ」「踊」2 行連結）で
/// 後続行が列ずれするため HTML 表の標準グリッド展開を行う。(2) genre==title 行の
/// colspan=2 は両列に同テキストを複製し、title 取り扱いを通常行と統一する
/// （設計レポート §2.2）。rowspan 継続列には元セルのテキストを引き継ぐ。
List<GridRow> expandGrid(List<HtmlRow> rows) {
  final carried = <int, _CarriedSpan>{};
  final grid = <GridRow>[];
  for (final row in rows) {
    final occupied = carried.keys.toSet();
    final line = <String>[];
    final added = <int, _CarriedSpan>{};
    var col = 0;
    for (final cell in row.cells) {
      while (occupied.contains(col)) {
        col++;
      }
      final w = cell.colSpan;
      final h = cell.rowSpan;
      for (var c = col; c < col + w; c++) {
        while (line.length <= c) {
          line.add('');
        }
        line[c] = cell.text;
      }
      if (h > 1) {
        for (var c = col; c < col + w; c++) {
          added[c] = _CarriedSpan(cell.text, h - 1);
        }
      }
      col += w;
    }
    // WHY: rowspan 継続列はセル走査でスキップされるため、ここで元セルのテキストを
    // 複写する（例: artist rowspan=2 の 2 行目にも artist を入れる。設計レポート §2.2）。
    // 空埋め後の上書きは安全（この行のセルは継続列に書き込まないため）。
    carried.forEach((c, span) {
      while (line.length <= c) {
        line.add('');
      }
      line[c] = span.text;
    });
    grid.add(line);
    final next = <int, _CarriedSpan>{};
    carried.forEach((c, span) {
      if (span.rowsLeft > 1) {
        next[c] = _CarriedSpan(span.text, span.rowsLeft - 1);
      }
    });
    added.forEach((c, span) {
      next[c] = span;
    });
    carried
      ..clear()
      ..addAll(next);
  }
  return grid;
}

/// 行からセル（<tr ...> ... </tr> 生本文）を抽出して HtmlRow 化する一連処理。
List<HtmlRow> rowsOf(String tableBody) {
  final rows = <HtmlRow>[];
  for (final tr in tagBodies(tableBody, 'tr')) {
    rows.add(HtmlRow(parseCells(tr)));
  }
  return rows;
}

class HtmlRow {
  const HtmlRow(this.cells);

  final List<HtmlCell> cells;

  /// colspan 合計（カテゴリ行検出に使用）。
  int get totalColSpan =>
      cells.fold(0, (sum, c) => sum + (c.colSpan < 1 ? 1 : c.colSpan));
}

/// 塗りタグ（span/strong/ins/font/br 等）を剥がしてテキストだけにする。
///
/// - `<a id="notetext_N">*N</a>`（脚注参照）は丸ごと除去
/// - それ以外の `<a>` はタグだけ剥がし内側テキストを残す（カテゴリ行の ▼/△ など）
/// - `<br>` は空白へ置換（BPM「139 (57-139)」等の区切りにする）
String stripMarkup(String html) {
  var s = html.replaceAll(_commentPattern, '');
  s = s.replaceAll(_notetextAnchorPattern, '');
  s = s.replaceAll(_tagPattern, ' ');
  return decodeEntities(s).replaceAll(_wsPattern, ' ').trim();
}

final _commentPattern = RegExp('<!--.*?-->', dotAll: true);
// WHY: <a ...>要素</a> の終端探索に非貪欲 .* を用いる。セル内に「</a>」を含む
// 生テキストは実データに存在しない（曲名等はエンティティ化される）。
final _notetextAnchorPattern = RegExp(
  r'<a\b[^>]*id="notetext[^"]*"[^>]*>.*?</a>',
  dotAll: true,
);
final _tagPattern = RegExp('<[^>]+>');
final _wsPattern = RegExp(' +');

/// &#9418; などの数値参照と基本エンティティを復号する。
String decodeEntities(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s[i] != '&') {
      out.write(s[i]);
      i++;
      continue;
    }
    final semi = s.indexOf(';', i);
    if (semi < 0 || semi - i > 10) {
      out.write(s[i]);
      i++;
      continue;
    }
    final body = s.substring(i + 1, semi);
    if (body.startsWith('#x')) {
      out.writeCharCode(int.tryParse(body.substring(2), radix: 16) ?? 0x26);
    } else if (body.startsWith('#')) {
      out.writeCharCode(int.tryParse(body.substring(1)) ?? 0x26);
    } else {
      const named = <String, String>{
        'amp': '&',
        'lt': '<',
        'gt': '>',
        'quot': '"',
        'apos': "'",
        // WHY: PukiWiki の見出しアンカーは「†」を &dagger; で出力する（実機確認
        // 2026-11-22）。未対応だと normalizedHeading の † 除去が効かず分類が失敗する。
        'dagger': '†',
      };
      out.write(named[body] ?? '&$body;');
    }
    i = semi + 1;
  }
  return out.toString();
}
