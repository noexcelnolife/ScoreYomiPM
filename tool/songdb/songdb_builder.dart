/// wiki テーブル行 → 曲 DB エントリ（JSON）変換。
///
/// 設計: docs/song_db_design_confirmation_report_2026-11-22.md §5（SongEntry 写像）
/// とリード設計レビュー決定事項（タスク 01a20201 description 2026-11-22）に基づく。
///
/// - id は内容派生の決定的 ID: `hc-<section>-<sha1(normalizedKey) 先頭 10 桁>`
/// - normalizedKey は lib/ocr/song_title_normalizer.dart の normalizeSongTitle(title)
///   （同一関数・手打ち禁止。test/seed_data_consistency_test.dart と同一規約）
/// - セクション間同名は AC > CS > ee'MALL 優先で集約、新曲リスト側同名行は旧曲側へ集約
/// - normalizedKey 重複はハードゲート（[SongDbBuildException] → exit 非ゼロ）
/// - 消滅曲（灰 #ddd）と旧曲譜面追加行（紫 #EEE7FF）は除外・ログ
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

import 'wiki_html.dart';
import 'wiki_sections.dart';

/// 変換で回収した統計・警告（生成ログに出す）。
class BuildLog {
  final List<String> lines = <String>[];

  void add(String line) => lines.add(line);
}

/// 生成を続行できないデータ不整合。
class SongDbBuildException implements Exception {
  SongDbBuildException(this.message);

  final String message;

  @override
  String toString() => 'SongDbBuildException: $message';
}

/// セクションごとの想定論理列数（thead の列構成に一致）。
const Map<String, int> expectedWidths = <String, int>{
  'ac': 10,
  'cs': 10,
  'ee': 12,
  'new-main': 10,
  'new-notes': 8,
};

/// レベルセルの解析結果（[LP] フラグ込み）。`-`/`--` は欠損。
class LevelParse {
  const LevelParse(this.level, this.longPop);

  final int? level;
  final bool longPop;
}

/// レベルセル「[LP] 33」「44」「--」をパースする。
LevelParse parseLevelCell(String raw) {
  var s = raw;
  var longPop = false;
  if (s.contains('[LP]')) {
    longPop = true;
    s = s.replaceAll('[LP]', '');
  }
  s = s.trim();
  if (s.isEmpty || s == '-' || s == '--') {
    return LevelParse(null, longPop);
  }
  return LevelParse(int.tryParse(s), longPop);
}

/// NOTE セル「158(7)」→ 基礎値 158（丸括弧内はロングポップ数・破棄）。非整数は null。
int? noteBase(String raw) {
  final m = RegExp(r'^\s*(\d+)').firstMatch(raw);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// BPM「139 (57-139)※」→ min=57, max=139。整数が取れなければ両方 null。
BpmRange parseBpmRange(String raw) {
  final numbers = RegExp(r'\d+')
      .allMatches(raw)
      .map((m) => int.parse(m.group(0)!))
      .toList();
  if (numbers.isEmpty) {
    return const BpmRange(null, null);
  }
  numbers.sort();
  return BpmRange(numbers.first, numbers.last);
}

class BpmRange {
  const BpmRange(this.min, this.max);

  final int? min;
  final int? max;
}

/// バージョンカテゴリ行のテキスト（版名 + ▼/△ の記号付き → 版名のみ）。
String versionFromCategory(String cellText) {
  // WHY: bemaniwiki のカテゴリ行は letter-spacing 用の span 由来で
  // 版名や曲名の文字間にスペースが混入する（例「P M 7」「p ea ce」・実機確認
  // 2026-11-22）。単語区切りの本来の空白と区別できないため、
  // バージョン文字列からは空白をすべて除去して正規化する。
  return cellText
      .replaceAll(RegExp(r'[▲▼△＜＞]'), '')
      .replaceAll('/', '')
      .replaceAll(RegExp(r'\s'), '');
}

/// ノーツ表照合用の折りたたみ: 全角 ASCII（U+FF01–U+FF5E）を半角へ寄せる。
///
/// WHY: 新曲リストのノーツ表はタイトルに全角記号を使う行があり（例「ビビッド
/// ☆＋＊。キラキライム」対 メイン表「ビビッド ☆+*。キラキライム」、2026-11-22
/// 実機確認）、normalizeSongTitle は全角 ASCII を半角化しないため key が不一致に
/// なる。照合時だけ両側をこの折りたたみで比較する。DB の normalizedKey は
/// normalizeSongTitle(title) のまま（整合性テストの契約を壊さない）。
String foldFullWidthAscii(String s) => s.runes
    .map(
      (r) => r >= 0xFF01 && r <= 0xFF5E
          ? String.fromCharCode(r - 0xFEE0)
          : String.fromCharCode(r),
    )
    .join();

/// normalizedKey の SHA-1 先頭 10 桁（決定的 ID 用）。
String sha1Prefix(String normalizedKey) =>
    sha1.convert(utf8.encode(normalizedKey)).toString().substring(0, 10);

/// 行スニペット（ログ用・長すぎる場合は切り捨て）。
String brief(GridRow row) {
  final s = row.take(4).join(' | ');
  return s.length <= 60 ? s : '${s.substring(0, 57)}...';
}

class SongDbBuilder {
  SongDbBuilder(this.tables);

  final List<WikiTable> tables;
  final BuildLog log = BuildLog();
  final Map<String, Map<String, Object?>> _byKey =
      <String, Map<String, Object?>>{};
  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  final Map<String, int> _variantCounts = <String, int>{};

  /// new-main（新曲リスト本体）で作成されたエントリの normalizedKey。
  ///
  /// WHY: ノーツ表の適用範囲を新曲に限定するための目印（_applyNotes の WHY 参照）。
  final Set<String> _newMainKeys = <String>{};

  /// 全セクションを処理してエントリ配列（normalizedKey 昇順）を返す。
  List<Map<String, Object?>> build() {
    for (final key in const <String>['ac', 'cs', 'ee', 'new-main']) {
      final table = _tableOf(key);
      if (table == null) {
        throw SongDbBuildException('セクション $key のテーブルが見つかりません');
      }
      _processSongTable(table);
    }
    _applyNotes();
    // WHY: _entries は同名異曲を含む全エントリ（_byKey.values は key 毎に 1 件しか
    // 持たないため同名異曲が落ちる）。ソートは (normalizedKey, id) 昇順 — 同一キーの
    // 同名異曲は id タイブレークで全順序にする（非安定ソートでも seed 順が実行毎に
    // 不変になり、リポジトリ側の first-match 挙動が決定的になる）。
    final songs = _entries.toList()..sort(_byNormalizedKeyThenId);
    _validateResult(songs);
    log.add('[STAT] entries=${songs.length}');
    return songs;
  }

  /// (normalizedKey, id) 昇順の全順序比較。同名異曲の seed 内順序を実行毎に固定する。
  int _byNormalizedKeyThenId(Map<String, Object?> a, Map<String, Object?> b) {
    final byKey = (a['normalizedKey']! as String).compareTo(
      b['normalizedKey']! as String,
    );
    if (byKey != 0) {
      return byKey;
    }
    return (a['id']! as String).compareTo(b['id']! as String);
  }

  WikiTable? _tableOf(String sectionKey) {
    for (final t in tables) {
      if (t.sectionKey == sectionKey) {
        return t;
      }
    }
    return null;
  }

  /// thead 2 行分（ジャンル名…／B,Lv…／L,N,H,E…）を除外。
  bool _isHeaderRow(GridRow row) {
    if (row.isEmpty) {
      return false;
    }
    if (row[0].startsWith('ジャンル名')) {
      return true;
    }
    final bLv = row.length > 5 && row[4] == 'B' && row[5] == 'Lv';
    final lnhe = row.length > 6 && row[3] == 'L' && row[6] == 'E';
    return bLv || lnhe;
  }

  /// カテゴリ行: 単一セルで全幅 colspan（版名 + ▼/△ の記号付き 等）。
  bool _isCategoryRow(HtmlRow row, int width) =>
      row.cells.length == 1 &&
      row.totalColSpan >= width - 1 &&
      row.cells.first.text.isNotEmpty;

  /// 消滅曲（灰 #ddd）・旧曲譜面追加行（紫 #EEE7FF）の行除外。
  bool _isExcludedRow(HtmlRow row) {
    for (final cell in row.cells) {
      if (cell.hasGreyBackground || cell.hasPurpleBackground) {
        return true;
      }
    }
    return false;
  }

  void _processSongTable(WikiTable table) {
    final section = table.sectionKey!;
    final width = expectedWidths[section]!;
    var version = section == 'new-main' ? 'HC' : '';
    final seen = <String>{};
    var entryCount = 0;
    for (var i = 0; i < table.rawRows.length; i++) {
      final raw = table.rawRows[i];
      final grid = table.grid[i];
      if (_isHeaderRow(grid)) {
        continue;
      }
      if (_isCategoryRow(raw, width)) {
        if (section != 'new-main') {
          version = versionFromCategory(raw.cells.first.text);
        }
        continue;
      }
      if (_isExcludedRow(raw)) {
        log.add('[SKIP] $section 除外行(灰/紫): ${brief(grid)}');
        continue;
      }
      final entry = _entryFromRow(section, width, version, grid);
      if (entry == null) {
        continue;
      }
      final key = entry['normalizedKey']! as String;
      if (seen.contains(key)) {
        // WHY: 同一セクション内の同曲名はまず「実在の同名異曲」か「同一内容の重複行」
        // かを判別する（例: une fille dans la pluie はフレンチポップ/フレンチポップJ の
        // 別譜面・別キャラ行が実在、2026-11-22 確認）。同一内容なら破棄しても欠落に
        // ならない。別内容なら id の派生種だけ変えて別エントリとして保持する。
        // normalizedKey は seed 契約どおり normalizeSongTitle(title) のまま。
        // 判定順序: 同セクション重複は _byKey 判定より先（_byKey に同一セクションの
        // 先頭行が既に登録されており、後発判定だと同名異曲が集約 SKIP に飲まれる）。
        if (_isSameSongContent(key, entry)) {
          log.add('[SKIP] 重複行(同一内容): $key（${entry['genre']}）');
          continue;
        }
        final n = (_variantCounts[key] ?? 1) + 1;
        _variantCounts[key] = n;
        final idCode = section == 'new-main' ? 'new' : section;
        entry['id'] =
            'hc-$idCode-${sha1Prefix('$key|${entry['genre']}|${entry['artist'] ?? ''}|$n')}';
        log.add('[WARN] 同名異曲: $key（genre=${entry['genre']}）→ #$n として別エントリ保持');
        entryCount++;
      } else if (_byKey.containsKey(key)) {
        // 集約(既存優先): AC>CS>ee>new-main の優先で先勝ち（設計レポート §5）。
        log.add('[SKIP] 集約(既存優先): $key（${entry['version']} 側行を破棄）');
        continue;
      } else {
        seen.add(key);
        entryCount++;
      }
      if (section == 'new-main') {
        _newMainKeys.add(key);
      }
      _byKey[key] = entry;
      _entries.add(entry);
    }
    log.add('[STAT] section=$section entries=$entryCount');
  }

  /// 既出エントリと同一内容（genre/artist/BPM/levels/longVersionLevels/character 全一致）
  /// かどうか。同一内容なら同一曲の重複行として破棄してよい。
  bool _isSameSongContent(String key, Map<String, Object?> entry) {
    for (final e in _entries) {
      if (e['normalizedKey'] != key) {
        continue;
      }
      if (e['genre'] == entry['genre'] &&
          e['artist'] == entry['artist'] &&
          e['bpmMin'] == entry['bpmMin'] &&
          e['bpmMax'] == entry['bpmMax'] &&
          e['character'] == entry['character'] &&
          _stringIntMapEquals(e['levels'], entry['levels']) &&
          _stringIntMapEquals(
            e['longVersionLevels'],
            entry['longVersionLevels'],
          )) {
        return true;
      }
    }
    return false;
  }

  /// levels 等の `Map<String,int>?` を null 安全に比較する。
  bool _stringIntMapEquals(Object? a, Object? b) {
    if (a == null && b == null) {
      return true;
    }
    if (a is Map<String, int> && b is Map<String, int>) {
      return a.length == b.length &&
          a.entries.every((e) => b[e.key] == e.value);
    }
    return false;
  }

  /// 1 行をエントリへ。不正行はログして null（Bad 行スキップ+ログ）。
  Map<String, Object?>? _entryFromRow(
    String section,
    int width,
    String version,
    GridRow grid,
  ) {
    final row = _fixMissingArtist(section, grid);
    if (row.length < width) {
      log.add('[WARN] $section 列数不足(${row.length}/$width): ${brief(grid)}');
      return null;
    }
    final genre = row[0];
    final title = row[1].isEmpty ? genre : row[1];
    if (genre.isEmpty || title.isEmpty) {
      log.add('[WARN] $section 空タイトル行: ${brief(grid)}');
      return null;
    }
    final normalizedKey = normalizeSongTitle(title);
    if (normalizedKey.isEmpty) {
      log.add('[WARN] $section normalizedKey 空行: $title');
      return null;
    }
    final idCode = section == 'new-main' ? 'new' : section;
    return _entryJson(idCode, width, version, row, title, normalizedKey);
  }

  /// 家庭用 CS の 9 列行（アーティストセル欠落）を列位置補正する。
  ///
  /// WHY: wiki の CS セクションにはアーティストセル欠落の 9 列行が実在し
  /// （例「君と微笑みと・・・」）、そのままでは BPM が artist 列へずれる。
  /// row[2] が BPM 形式なら artist を空で挿入する（リード承認: 9列/12列ゆらぎ処理）。
  /// rowspan 継続中の行はグリッド展開で 10 列になるため誤適用されない。
  GridRow _fixMissingArtist(String section, GridRow grid) {
    if (section != 'cs' || grid.length != 9 || !_bpmLike(grid[2])) {
      return grid;
    }
    return <String>[grid[0], grid[1], '', ...grid.sublist(2)];
  }

  bool _bpmLike(String s) {
    final cleaned = s.replaceAll('[LP]', '').replaceAll(' ', '');
    if (cleaned.isEmpty) {
      return false;
    }
    return RegExp(r'^[0-9\-（）()※~〜]+$').hasMatch(cleaned);
  }

  Map<String, Object?> _entryJson(
    String idCode,
    int width,
    String version,
    GridRow row,
    String title,
    String normalizedKey,
  ) {
    // WHY: levels は値が取れた譜面キーのみ出力する疎マップにする。
    // SongEntry.fromJson は null 値を int.tryParse("null") ?? 0 で「レベル 0」に
    // 変換してしまうため、null を入れてはいけない（seed 契約・同一規約テスト）。
    final levels = <String, int>{};
    final longVersionLevels = <String, int>{};
    // 列位置: 3=BPM, 4=入門譜面ボタン数, 5..8=入門Lv/N/H/EX。
    const chartKeys = <String>['LIGHT', 'NORMAL', 'HYPER', 'EX'];
    for (var i = 0; i < chartKeys.length; i++) {
      final parsed = parseLevelCell(row[5 + i]);
      // WHY: parsed.level は public フィールドのため Dart の型昇格が効かない。
      // ローカル変数に受けると null チェック後に非 null として扱える。
      final lv = parsed.level;
      if (lv != null) {
        levels[chartKeys[i]] = lv;
      } else if (_hasNumberLikeText(row[5 + i])) {
        log.add('[WARN] レベル非整数: $title [${chartKeys[i]}] "${row[5 + i]}"');
      }
      if (parsed.longPop && lv != null) {
        longVersionLevels[chartKeys[i]] = lv;
      }
    }
    final bpm = parseBpmRange(row[3]);
    final character = row[width - 1];
    return <String, Object?>{
      'id': 'hc-$idCode-${sha1Prefix(normalizedKey)}',
      'title': title,
      'normalizedKey': normalizedKey,
      'genre': row[0],
      if (row.length > 2 && row[2].isNotEmpty) 'artist': row[2],
      'levels': levels,
      'totalNotes': null,
      'version': version,
      if (bpm.min != null) ...<String, Object?>{
        'bpmRaw': row[3],
        'bpmMin': bpm.min,
        'bpmMax': bpm.max,
      },
      if (longVersionLevels.isNotEmpty) 'longVersionLevels': longVersionLevels,
      if (character.isNotEmpty) 'character': character,
    };
  }

  bool _hasNumberLikeText(String s) {
    final cleaned = s.replaceAll('[LP]', '').trim();
    return cleaned.isNotEmpty &&
        cleaned != '-' &&
        cleaned != '--' &&
        int.tryParse(cleaned) == null;
  }

  /// 総ノーツ数表（new-notes）を反映: noteCounts と totalNotes = max(noteCounts)。
  ///
  /// WHY: リード決定事項「totalNotes = max(noteCounts) を必ず埋める（VR-1 が即機能）」。
  /// 適用先は new-main 由来エントリに限定する。ノーツ表は新曲リストの「キャラ・総
  /// ノーツ数」表であり、旧曲カバー行（covered by 〜）のノーツ数が同名の旧曲エントリ
  /// に誤適用されるのを防ぐため（実機確認 2026-11-22: Homesick Pt.2&3 旧曲にカバー版の
  /// 1098 ノーツが付与された）。旧曲側にはノーツ数ソースが無いため totalNotes は null。
  void _applyNotes() {
    final table = _tableOf('new-notes');
    if (table == null) {
      log.add('[WARN] 総ノーツ数テーブルが見つかりません（totalNotes は全件 null のまま）');
      return;
    }
    var applied = 0;
    var skipped = 0;
    // WHY: _newMainKeys は new-main 表由来の正規化キー集合。ノーツ表側の全角記号
    // 表記差（ビビッド ☆＋＊。対 ビビッド ☆+*。）を吸収するため、両側を折りたたんで
    // 比較する。
    final foldedNewMainKeys = _newMainKeys.map(foldFullWidthAscii).toSet();
    for (var i = 0; i < table.rawRows.length; i++) {
      final raw = table.rawRows[i];
      final grid = table.grid[i];
      if (_isHeaderRow(grid) ||
          _isCategoryRow(raw, 8) ||
          _isExcludedRow(raw) ||
          grid.length < 7) {
        continue;
      }
      final joinKey = foldFullWidthAscii(
        normalizeSongTitle(grid[1].isEmpty ? grid[0] : grid[1]),
      );
      // WHY: noteBase は int? を返すため、null の譜面キーを疎マップから除外して構築する
      // （SongEntry 契約: null 値禁止。「'KEY': ?値」は null をエントリごと落とす
      // Dart の null-aware element）。
      final light = noteBase(grid[3]);
      final normal = noteBase(grid[4]);
      final hyper = noteBase(grid[5]);
      final ex = noteBase(grid[6]);
      final counts = <String, int>{
        'LIGHT': ?light,
        'NORMAL': ?normal,
        'HYPER': ?hyper,
        'EX': ?ex,
      };
      final entry = _entries.where((e) {
        final ek = e['normalizedKey']! as String;
        final folded = foldFullWidthAscii(ek);
        return folded == joinKey && foldedNewMainKeys.contains(folded);
      }).toList();
      if (counts.isEmpty || entry.isEmpty) {
        skipped++;
        continue;
      }
      // WHY: 同名異曲があれば全 variant に同じノーツ数を適用する（同一曲の別譜面行
      // のためノーツ数は共通とみなせる）。
      for (final e in entry) {
        e['noteCounts'] = counts;
        e['totalNotes'] = counts.values.reduce((a, b) => a > b ? a : b);
      }
      applied += entry.length;
    }
    log.add('[STAT] noteCounts applied=$applied skipped=$skipped');
  }

  /// 結果全体の整合検証。id 重複はハードゲート、同名異曲は統計、その他は警告。
  void _validateResult(List<Map<String, Object?>> songs) {
    final keys = <String>{};
    final ids = <String>{};
    var variants = 0;
    for (final song in songs) {
      final key = song['normalizedKey']! as String;
      if (!keys.add(key)) {
        variants++;
      }
      // WHY: id はユーザーデータの紐付け鍵なので重複は異常（同名異曲は派生種変更で
      // 一意化済み）。id 重複はパーサ異常の可能性が高いのでハードゲートのまま残す。
      final id = song['id']! as String;
      if (!ids.add(id)) {
        throw SongDbBuildException('id 重複（ハードゲート）: $id');
      }
      final levels = song['levels']! as Map<String, int>;
      for (final v in levels.values) {
        if (v < 1 || v > 50) {
          log.add('[WARN] levels 範囲外 1-50: ${song['title']} ($v)');
        }
      }
      final total = song['totalNotes'] as int?;
      if (total != null && total <= 0) {
        log.add('[WARN] totalNotes<=0: ${song['title']} ($total)');
      }
    }
    log.add(
      '[STAT] normalizedKey unique=${keys.length}/${songs.length} variants=$variants',
    );
  }
}
