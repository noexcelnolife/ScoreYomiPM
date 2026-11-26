// タスク 01a20305: seed_v2.json 生成ツール
//
// docs/notes_count_collection_2026-11-22.md（commit 7bbb1f8）を唯一の
// ソース・オブ・トゥルースとして assets/songs/seed_v1.json から
// assets/songs/seed_v2.json を生成する。
//
// 変換内容（リード最終裁定 01a2030b 反映）:
//   1. notesCounts マップを追加キーとして付与
//      （収集表 34 エントリ = EX 22 + NORMAL/LIGHT 12・未収集難易度キーは
//       null 埋めせず省略＝Harmonia の LIGHT+EX のような複数難易度を表現可能）。
//      totalNotes は **JSON に書かない**（検収合格の af194bd 状態を維持）。
//      WHY: VR-1 契約値は SongEntry の computed getter が
//      max(notesCounts.values) として合成し、legacy 曲（main_v1 の 135 曲）は
//      fromJson で totalNotes を読み戻して救済する（裁定 01a2030b）。
//   2. レベル修正 5 件（収集ドキュメント「レベル差分」章どおり）
//   3. updatedAt 更新（seed_v1 とは異なる時刻に更新）
//
// ハードゲート（違反時 exit 非ゼロ）:
//   - 入力 seed_v1: id 一意・normalizedKey 不変則・曲数 33
//   - レベル修正: 修正前の旧レベル値が seed_v1 と一致（ドキュメント/seed 漂移検知）
//   - 出力: id 集合一致・34 エントリ全件照合・修正後レベル 5 件・
//     notesCounts 値は正数 int・totalNotes キーは出力しない
//   - 書き出し後のバイトを再読込して全ゲートを再検証
//
// 使い方: dart run tool/generate_seed_v2.dart（リポジトリルートで実行）
// 文字化け対策: JSON は File.writeAsString(UTF-8) でのみ書く
// （シェル経由のファイル書き込みは禁止・タスク 01a20201 規約の継承）。

import 'dart:convert';
import 'dart:io';

import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

/// 収集表（docs/notes_count_collection_2026-11-22.md・commit 7bbb1f8 より転記）。
/// 要素: [楽曲id, 難易度キー, 総ノーツ数]。
/// テスト（test/seed_v2_data_test.dart）にも独立転記しており、
/// 両者の不一致はテストで RED になる（転記ミスの二重チェック）。
const List<List<Object>> _notesCountTable = [
  ['popn_hc_001', 'EX', 1036],
  ['popn_hc_002', 'EX', 1300],
  ['popn_hc_003', 'EX', 1418],
  ['popn_hc_004', 'EX', 1056],
  ['popn_hc_005', 'EX', 1052],
  ['popn_hc_006', 'EX', 1947],
  ['popn_hc_009', 'EX', 1682],
  ['popn_hc_010', 'EX', 1630],
  ['popn_hc_011', 'EX', 1560],
  ['popn_hc_012', 'EX', 1882],
  ['popn_hc_013', 'EX', 1215],
  ['popn_hc_014', 'EX', 1295],
  ['popn_hc_015', 'EX', 1461],
  ['popn_hc_016', 'EX', 1603],
  ['popn_hc_017', 'EX', 1358],
  ['popn_hc_018', 'EX', 1331],
  ['popn_hc_019', 'EX', 1471],
  ['popn_hc_020', 'EX', 1647],
  ['popn_hc_021', 'EX', 1318],
  ['popn_hc_022', 'EX', 1336],
  ['popn_hc_023', 'EX', 1355],
  ['popn_hc_024', 'EX', 1287],
  ['popn_hc_001', 'LIGHT', 135],
  ['popn_hc_007', 'NORMAL', 247],
  ['popn_hc_008', 'NORMAL', 353],
  ['scr_001', 'NORMAL', 484],
  ['scr_002', 'NORMAL', 540],
  ['scr_003', 'NORMAL', 421],
  ['scr_004', 'NORMAL', 566],
  ['scr_005', 'NORMAL', 463],
  ['scr_006', 'NORMAL', 503],
  ['scr_007', 'NORMAL', 497],
  ['scr_008', 'NORMAL', 501],
  ['scr_009', 'NORMAL', 475],
];

/// レベル修正 5 件（docs「レベル差分」章より転記）。
/// 要素: [楽曲id, 難易度キー, 修正前レベル, 修正後レベル]。
/// 修正前値は入力 seed_v1 との一致ゲートに使う（seed 側が既に修正済みなら
/// 本ツールは誤適用を避けるため fail する）。
const List<List<Object>> _levelFixes = [
  ['popn_hc_011', 'EX', 50, 49],
  ['popn_hc_013', 'EX', 48, 46],
  ['popn_hc_016', 'EX', 49, 48],
  ['popn_hc_018', 'EX', 49, 48],
  ['scr_001', 'NORMAL', 28, 25],
];

const String _inputPath = 'assets/songs/seed_v1.json';
const String _outputPath = 'assets/songs/seed_v2.json';

/// seed_v2 の updatedAt。
///
/// WHY 固定値: 再実行でバイト同一出力を保証する（生成物の diff 安定）。
/// seed_v1 の updatedAt（2026-11-22T00:00:00Z）とは異なるため、
/// テストは「updatedAt が更新されたこと」を検証できる。
const String _updatedAtV2 = '2026-11-22T12:00:00Z';

/// notesCounts マップのカノニカル出力順（譜面難易度の並び）。
const List<String> _canonicalOrder = ['LIGHT', 'NORMAL', 'HYPER', 'EX'];

void main() {
  try {
    final input = jsonDecode(
      File(_inputPath).readAsStringSync(encoding: utf8),
    ) as Map<String, dynamic>;
    final inputSongs = (input['songs'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _validateInputSongs(inputSongs);
    _validateLevelFixPreconditions(inputSongs);

    final outputSongs = _buildOutputSongs(inputSongs);
    _validateOutputSongs(outputSongs, inputSongs);

    final text = _serialize(input, outputSongs);
    File(_outputPath).writeAsStringSync(text, encoding: utf8, flush: true);

    // WHY: 書き出したバイトを再読込して最終検証する
    // （シリアライズ結果が妥当な JSON として自己無矛盾であることの担保）。
    final roundTrip = jsonDecode(
      File(_outputPath).readAsStringSync(encoding: utf8),
    ) as Map<String, dynamic>;
    final rtSongs = (roundTrip['songs'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _validateEnvelope(roundTrip, rtSongs);
    _validateOutputSongs(rtSongs, inputSongs);

    _printSummary(rtSongs);
  } catch (e) {
    stderr.writeln('[ERROR] $e');
    exit(1);
  }
}

/// 入力 seed_v1 の基本ゲート（曲数・id 一意・normalizedKey 不変則）。
void _validateInputSongs(List<Map<String, dynamic>> songs) {
  final problems = <String>[];
  if (songs.length != 33) {
    problems.add('曲数が 33 でない: ${songs.length}');
  }
  final ids = <String>{};
  for (final s in songs) {
    final id = s['id'] as String?;
    if (id == null || !ids.add(id)) {
      problems.add('id 欠落/重複: $id');
      continue;
    }
    final title = s['title'] as String?;
    final key = s['normalizedKey'] as String?;
    if (title == null || key == null || key != normalizeSongTitle(title)) {
      problems.add('$id: normalizedKey 不変則違反');
    }
  }
  _failIfProblems('入力ゲート', problems);
}

/// レベル修正の事前条件: 修正前の旧レベル値が seed_v1 と一致すること。
///
/// WHY: 収集ドキュメントと seed の漂移を検知する。seed 側が既に修正済み
/// （旧値が存在しない）場合の誤適用を防ぐ。
void _validateLevelFixPreconditions(List<Map<String, dynamic>> songs) {
  final byId = {for (final s in songs) s['id'] as String: s};
  final problems = <String>[];
  for (final row in _levelFixes) {
    final id = row[0] as String;
    final difficulty = row[1] as String;
    final oldLevel = row[2] as int;
    final levels = byId[id]?['levels'] as Map<String, dynamic>?;
    if (levels == null || levels[difficulty] != oldLevel) {
      problems.add(
        '$id: levels[$difficulty] が修正前値 $oldLevel と不一致'
        '（実: ${levels?[difficulty]}）',
      );
    }
  }
  _failIfProblems('レベル修正事前条件', problems);
}

/// 変換本体: totalNotes は書かず notesCounts 付与・レベル修正。
List<Map<String, dynamic>> _buildOutputSongs(List<Map<String, dynamic>> songs) {
  final notesById = <String, Map<String, int>>{};
  for (final row in _notesCountTable) {
    (notesById[row[0] as String] ??= {})[row[1] as String] = row[2] as int;
  }
  final fixById = <String, List<Object>>{
    for (final row in _levelFixes) row[0] as String: row,
  };
  final result = <Map<String, dynamic>>[];
  for (final song in songs) {
    final id = song['id'] as String;
    final levels = Map<String, dynamic>.of(
      song['levels'] as Map<String, dynamic>? ?? {},
    );
    final fixRow = fixById[id];
    if (fixRow != null) {
      levels[fixRow[1] as String] = fixRow[3] as int;
    }
    final notes = notesById[id];
    result.add(<String, dynamic>{
      'id': song['id'],
      'title': song['title'],
      'normalizedKey': song['normalizedKey'],
      'genre': song['genre'],
      'artist': song['artist'],
      'levels': levels,
      if (notes != null) 'notesCounts': _orderedNotesCounts(notes),
      'version': song['version'],
    });
  }
  return result;
}

/// notesCounts をカノニカル順（LIGHT/NORMAL/HYPER/EX・未知キーは後段）で並べ直す。
Map<String, int> _orderedNotesCounts(Map<String, int> notes) {
  final ordered = <String, int>{};
  for (final key in _canonicalOrder) {
    if (notes.containsKey(key)) {
      ordered[key] = notes[key]!;
    }
  }
  final rest = notes.keys.where((k) => !_canonicalOrder.contains(k));
  for (final key in rest) {
    ordered[key] = notes[key]!;
  }
  return ordered;
}

/// 出力ゲート: id 集合一致・不変則・notesCounts/レベル修正の全件照合。
void _validateOutputSongs(
  List<Map<String, dynamic>> songs,
  List<Map<String, dynamic>> inputSongs,
) {
  final inputIds = inputSongs.map((s) => s['id'] as String).toList()..sort();
  final outputIds = songs.map((s) => s['id'] as String).toList()..sort();
  final problems = <String>[];
  if (outputIds.length != inputIds.length ||
      outputIds.any((id) => !inputIds.contains(id))) {
    problems.add('id 集合が入力と不一致');
  }
  final inputById = {for (final s in inputSongs) s['id'] as String: s};
  final fixById = {for (final row in _levelFixes) row[0] as String: row};
  final expectedNotes = _expectedNotesById();
  for (final s in songs) {
    _validateSingleSong(s, inputById, expectedNotes, fixById, problems);
  }
  _failIfProblems('出力ゲート', problems);
}

/// 収集表を id → {難易度: ノーツ数} のマップに展開する。
Map<String, Map<String, int>> _expectedNotesById() {
  final byId = <String, Map<String, int>>{};
  for (final row in _notesCountTable) {
    (byId[row[0] as String] ??= {})[row[1] as String] = row[2] as int;
  }
  return byId;
}

/// 1 曲分の出力検証（totalNotes 非出力・notesCounts・levels 差分）。
void _validateSingleSong(
  Map<String, dynamic> s,
  Map<String, Map<String, dynamic>> inputById,
  Map<String, Map<String, int>> expectedNotes,
  Map<String, List<Object>> fixById,
  List<String> problems,
) {
  final id = s['id'] as String;
  // WHY 非出力ゲート（リード裁定 01a2030b）: totalNotes は JSON に書かず
  // SongEntry の computed getter が合成する。誤って旧キーを出すと
  // 検収合格の af194bd 状態から漂移するため fail に倒す。
  if (s.containsKey('totalNotes')) {
    problems.add('$id: totalNotes キーは出力しない（getter 合成に一本化）');
  }
  final title = s['title'] as String;
  if (s['normalizedKey'] != normalizeSongTitle(title)) {
    problems.add('$id: normalizedKey 不変則違反');
  }
  _validateNotesCounts(id, s['notesCounts'], expectedNotes[id], problems);
  final expectedLevelMap = Map<String, dynamic>.of(
    inputById[id]?['levels'] as Map<String, dynamic>? ?? {},
  );
  final fixRow = fixById[id];
  if (fixRow != null) {
    expectedLevelMap[fixRow[1] as String] = fixRow[3] as int;
  }
  final actualLevels = s['levels'] as Map<String, dynamic>?;
  if (actualLevels == null ||
      actualLevels.length != expectedLevelMap.length ||
      expectedLevelMap.entries.any((e) => actualLevels[e.key] != e.value)) {
    problems.add('$id: levels 不一致（実: $actualLevels）');
  }
}

/// 1 曲分の notesCounts 検証（収集曲は完全一致・未収集曲はキーなし・値は正数）。
void _validateNotesCounts(
  String id,
  Object? actual,
  Map<String, int>? expected,
  List<String> problems,
) {
  if (expected == null) {
    if (actual != null) {
      problems.add('$id: 未収集曲に notesCounts');
    }
    return;
  }
  if (actual is! Map<String, dynamic>) {
    problems.add('$id: 収集曲に notesCounts なし');
    return;
  }
  if (actual.length != expected.length ||
      expected.entries.any((e) => actual[e.key] != e.value)) {
    problems.add('$id: notesCounts 不一致（実: $actual）');
  }
  for (final e in actual.entries) {
    if (e.value is! int || (e.value as int) <= 0) {
      problems.add('$id: notesCounts[${e.key}]=${e.value} は不正値');
    }
  }
}

/// envelope のゲート（契約キー・曲数一致・updatedAt 更新）。
void _validateEnvelope(
  Map<String, dynamic> json,
  List<Map<String, dynamic>> songs,
) {
  final problems = <String>[];
  if (json['schemaVersion'] != 1) {
    problems.add('schemaVersion が 1 でない: ${json['schemaVersion']}');
  }
  if (json['sourceType'] != 'bundledSeed') {
    problems.add('sourceType が bundledSeed でない: ${json['sourceType']}');
  }
  if (json['updatedAt'] != _updatedAtV2) {
    problems.add('updatedAt が想定値でない: ${json['updatedAt']}');
  }
  if (json['songCount'] != songs.length) {
    problems.add('songCount が songs 配列と不一致');
  }
  if (songs.length != 33) {
    problems.add('曲数が 33 でない: ${songs.length}');
  }
  _failIfProblems('envelope ゲート', problems);
}

/// seed_v1 と同じ体裁（2 スペース・levels/notesCounts はインライン）で直列化する。
String _serialize(
  Map<String, dynamic> input,
  List<Map<String, dynamic>> songs,
) {
  final b = StringBuffer();
  b.writeln('{');
  b.writeln('  "schemaVersion": ${input['schemaVersion']},');
  b.writeln('  "updatedAt": "$_updatedAtV2",');
  b.writeln('  "sourceType": "${input['sourceType']}",');
  b.writeln('  "songCount": ${songs.length},');
  b.writeln('  "songs": [');
  for (var i = 0; i < songs.length; i++) {
    _writeSong(b, songs[i], isLast: i == songs.length - 1);
  }
  b.writeln('  ]');
  b.write('}\n');
  return b.toString();
}

/// 1 曲分をフィールドごとの行で書く（null は明示出力・seed_v1 と同じ体裁）。
void _writeSong(
  StringBuffer b,
  Map<String, dynamic> s, {
  required bool isLast,
}) {
  final fields = <String>[
    '"id": ${jsonEncode(s['id'])}',
    '"title": ${jsonEncode(s['title'])}',
    '"normalizedKey": ${jsonEncode(s['normalizedKey'])}',
    '"genre": ${_jsonOrNull(s['genre'])}',
    '"artist": ${_jsonOrNull(s['artist'])}',
    '"levels": ${_inlineLevels(s['levels'] as Map<String, dynamic>)}',
    if (s.containsKey('notesCounts'))
      '"notesCounts": ${_inlineNotesCounts(s['notesCounts'] as Map<String, int>)}',
    '"version": ${_jsonOrNull(s['version'])}',
  ];
  b.writeln('    {');
  b.writeln('      ${fields.join(',\n      ')}');
  b.write('    }');
  b.writeln(isLast ? '' : ',');
}

/// null は "null"、それ以外は JSON 文字列リテラルとして出力。
String _jsonOrNull(Object? v) => v == null ? 'null' : jsonEncode(v);

/// levels をインライン（キー順は入力維持・値は int か null）。
String _inlineLevels(Map<String, dynamic> levels) {
  final entries = levels.entries
      .map((e) => '"${e.key}": ${e.value ?? 'null'}')
      .join(', ');
  return '{$entries}';
}

/// notesCounts をインライン（値は必ず int）。
String _inlineNotesCounts(Map<String, int> notes) {
  final entries = notes.entries.map((e) => '"${e.key}": ${e.value}').join(', ');
  return '{$entries}';
}

void _printSummary(List<Map<String, dynamic>> songs) {
  // WHY ASCII 中心: PS5.1 の stdout 表示崩れを避ける（検証はファイル経由）。
  stdout.writeln('seed_v2 generated: $_outputPath');
  stdout.writeln('songs=${songs.length}');
  stdout.writeln('notesCountsEntries=${_notesCountTable.length}');
  stdout.writeln('levelFixes=${_levelFixes.length}');
  stdout.writeln('updatedAt=$_updatedAtV2');
}

void _failIfProblems(String label, List<String> problems) {
  if (problems.isEmpty) {
    return;
  }
  for (final p in problems) {
    stderr.writeln('[$label] $p');
  }
  exit(1);
}
