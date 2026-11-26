// タスク 01a20305: seed_v2.json データ検証テスト（TDD red-first）
//
// WHY: seed_v2.json は docs/notes_count_collection_2026-11-22.md（commit 7bbb1f8）
// を唯一のソース・オブ・トゥルースとして tool/generate_seed_v2.dart が生成する。
// 本テストは収集ドキュメントの値を独立に転記した期待表と生成物を突合する
// （ジェネレータ側の転記と二重化し、転記ミスを不一致として検知する）。
//
// 検証項目:
//   1. envelope 契約（schemaVersion/sourceType/songCount/songs・updatedAt 更新済み）
//   2. totalNotes キー不在（リード最終裁定 01a2030b）: JSON には書かず
//      SongEntry の computed getter が max(notesCounts.values) を合成
//   3. notesCounts 34 エントリ（EX 22 + NORMAL/LIGHT 12）が期待値と完全一致
//      ・notesCounts 未収集キーは null 埋めせず省略されている
//   4. レベル修正 5 件（docs「レベル差分」章どおり・修正後の値を固定）
//   5. id 集合と levels は seed_v1 と同一（5 件の修正を除く・入れ替えなし）
//   6. normalizedKey == normalizeSongTitle(title) 不変則（全曲）
//
// rootBundle で seed_v2 を読めること自体が pubspec asset 登録の検証を兼ねる。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

/// 収集表の期待値（docs/notes_count_collection_2026-11-22.md より独立転記）。
/// 要素: [楽曲id, 難易度キー, 総ノーツ数]。EX 22 件 + NORMAL/LIGHT 12 件 = 34 件。
const List<List<Object>> _expectedNotesCounts = [
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

/// レベル修正 5 件（docs「レベル差分」章より独立転記）。
/// 要素: [楽曲id, 難易度キー, 修正後レベル]。
const List<List<Object>> _expectedLevelFixes = [
  ['popn_hc_011', 'EX', 49],
  ['popn_hc_013', 'EX', 46],
  ['popn_hc_016', 'EX', 48],
  ['popn_hc_018', 'EX', 48],
  ['scr_001', 'NORMAL', 25],
];

/// seed_v1.json（修正前・ジェネレータ入力）を disk から読む。
///
/// WHY: seed_v1 は pubspec asset から外れるため rootBundle では読めない。
/// dart:io File でホストから直接読む（flutter test はパッケージルートで実行）。
Map<String, dynamic> _loadSeedV1Raw() {
  final jsonString = File('assets/songs/seed_v1.json')
      .readAsStringSync(encoding: utf8);
  return jsonDecode(jsonString) as Map<String, dynamic>;
}

void main() {
  // WHY: rootBundle は platform channel 経由のため
  // TestWidgetsFlutterBinding の初期化が必須。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('seed_v2.json データ検証', () {
    late Map<String, dynamic> json;
    late List<Map<String, dynamic>> songs;

    setUpAll(() async {
      final jsonString = await rootBundle.loadString(
        'assets/songs/seed_v2.json',
      );
      json = jsonDecode(jsonString) as Map<String, dynamic>;
      songs = (json['songs'] as List<dynamic>).cast<Map<String, dynamic>>();
    });

    test('envelope 契約: 必須キーと値', () {
      expect(json['schemaVersion'], equals(1));
      expect(json['sourceType'], equals('bundledSeed'));
      expect(json['songCount'], equals(songs.length));
    });

    test('updatedAt は更新されている', () {
      // WHY: seed_v1 は 2026-11-22T00:00:00Z。v2 は同日でも別時刻で
      // 更新されたことを検証する（ジェネレータは固定値 2026-11-22T12:00:00Z）。
      final updatedAt = json['updatedAt'] as String;
      expect(DateTime.tryParse(updatedAt), isNotNull);
      expect(updatedAt, isNot(equals('2026-11-22T00:00:00Z')));
    });

    test('曲数は 33（seed_v1 と同数・入れ替えなし）', () {
      expect(songs.length, equals(33));
      expect(json['songCount'], equals(33));
    });

    test('totalNotes キーは JSON に存在しない（getter 合成に一本化）', () {
      // WHY 非出力（リード最終裁定 01a2030b）: totalNotes は seed_v2.json に
      // 書かず、SongEntry の computed getter が max(notesCounts.values) として
      // 合成する（legacy 曲は fromJson 読み戻し）。JSON 側に旧キーが復活すると
      // 検収合格の af194bd バイト状態から漂移するため、キー不在を固定する。
      // getter 側の合成検証は song_entry_test.dart の seed_v2 統合テストが担う。
      final problems = <String>[];
      for (final song in songs) {
        if (song.containsKey('totalNotes')) {
          problems.add('${song['id']}: totalNotes キーが残存');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('notesCounts 34 エントリが期待値と完全一致', () {
      final byId = {for (final s in songs) s['id'] as String: s};
      final problems = <String>[];
      for (final row in _expectedNotesCounts) {
        final id = row[0] as String;
        final difficulty = row[1] as String;
        final notes = row[2] as int;
        final song = byId[id];
        if (song == null) {
          problems.add('$id: 楽曲が存在しない');
          continue;
        }
        final map = song['notesCounts'];
        if (map is! Map<String, dynamic>) {
          problems.add('$id: notesCounts が存在しない');
          continue;
        }
        if (map[difficulty] != notes) {
          problems.add(
            '$id: notesCounts[$difficulty]=$map[$difficulty] '
            '（期待: $notes）',
          );
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
      // 34 行がすべて実在する id に紐づいたことの確認。
      expect(_expectedNotesCounts, hasLength(34));
    });

    test('notesCounts は期待キー集合と完全一致（過剰・欠落なし・null 埋めなし）', () {
      final expected = <String, Map<String, int>>{};
      for (final row in _expectedNotesCounts) {
        (expected[row[0] as String] ??= {})[row[1] as String] = row[2] as int;
      }
      final problems = <String>[];
      for (final song in songs) {
        final id = song['id'] as String;
        final expectedMap = expected[id] ?? const <String, int>{};
        final actualMap = song['notesCounts'];
        if (expectedMap.isEmpty) {
          if (actualMap != null) {
            problems.add('$id: 未収集曲なのに notesCounts=$actualMap');
          }
          continue;
        }
        if (actualMap is! Map<String, dynamic>) {
          problems.add('$id: 収集曲なのに notesCounts なし');
          continue;
        }
        // null 埋め禁止規約: 値は全て int で正数。
        for (final e in actualMap.entries) {
          if (e.value is! int || (e.value as int) <= 0) {
            problems.add('$id: notesCounts[${e.key}]=${e.value} は不正値');
          }
        }
        final asIntMap = actualMap.map((k, v) => MapEntry(k, v as int));
        if (asIntMap.length != expectedMap.length) {
          problems.add(
            '$id: キー数 ${asIntMap.length}（期待: '
            '${expectedMap.length}）',
          );
        }
        for (final e in expectedMap.entries) {
          if (asIntMap[e.key] != e.value) {
            problems.add(
              '$id: notesCounts[${e.key}]=${asIntMap[e.key]}'
              '（期待: ${e.value}）',
            );
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('レベル修正 5 件が反映されている', () {
      final byId = {for (final s in songs) s['id'] as String: s};
      final problems = <String>[];
      for (final row in _expectedLevelFixes) {
        final id = row[0] as String;
        final difficulty = row[1] as String;
        final level = row[2] as int;
        final levels = byId[id]?['levels'];
        if (levels is! Map<String, dynamic> || levels[difficulty] != level) {
          problems.add(
            '$id: levels[$difficulty] != $level '
            '（実: $levels?[$difficulty]）',
          );
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
      expect(_expectedLevelFixes, hasLength(5));
    });

    test('id 集合は seed_v1 と同一', () {
      final v1 = _loadSeedV1Raw();
      final v1Songs = (v1['songs'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final v1Ids = v1Songs.map((s) => s['id']).toList()..sort();
      final v2Ids = songs.map((s) => s['id']).toList()..sort();
      expect(v2Ids, equals(v1Ids));
    });

    test('levels は seed_v1 と同一（レベル修正 5 件のみ差分）', () {
      final v1 = _loadSeedV1Raw();
      final v1Songs = (v1['songs'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final v1ById = {for (final s in v1Songs) s['id'] as String: s};
      final fixedIds = _expectedLevelFixes.map((r) => r[0] as String).toSet();
      final problems = <String>[];
      for (final song in songs) {
        final id = song['id'] as String;
        final expected = Map<String, dynamic>.from(
          v1ById[id]?['levels'] as Map<String, dynamic>? ?? {},
        );
        if (fixedIds.contains(id)) {
          for (final row in _expectedLevelFixes) {
            if (row[0] == id) {
              expected[row[1] as String] = row[2] as int;
            }
          }
        }
        final actual = song['levels'];
        if (actual is! Map<String, dynamic> ||
            actual.length != expected.length ||
            expected.keys.any((k) => actual[k] != expected[k])) {
          problems.add('$id: levels 不一致（実: $actual・期待: $expected）');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('normalizedKey 不変則（全曲）', () {
      final problems = <String>[];
      for (final song in songs) {
        final title = song['title'] as String;
        final key = song['normalizedKey'] as String?;
        if (key == null || key != normalizeSongTitle(title)) {
          problems.add('${song['id']}: normalizedKey 不一致');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('title・version・genre・artist は seed_v1 と同一（内容保護）', () {
      final v1 = _loadSeedV1Raw();
      final v1Songs = (v1['songs'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final v1ById = {for (final s in v1Songs) s['id'] as String: s};
      final problems = <String>[];
      for (final song in songs) {
        final v1Song = v1ById[song['id']];
        for (final field in ['title', 'genre', 'artist', 'version']) {
          if (song[field] != v1Song?[field]) {
            problems.add(
              '${song['id']}: $field 変更'
              '（v1: ${v1Song?[field]}・v2: ${song[field]}）',
            );
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });
}
