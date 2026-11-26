// 配信 DB 第1版（db/popn_hc_main_v1.json）の整合性テスト（TDD）
//
// WHY: この DB は OCR 照合の前提になる生成物だが、BEMANIWiki の表を変換した
// 第三者コンテンツなのでリポジトリには含めない（.gitignore の /db/）。
// 手元に生成物がある場合のみ検証する。封筒の契約キー（リード設計レビュー決定 2026-11-22）、
// normalizedKey の規約（normalizeSongTitle 出力・手打ち禁止）、同名異曲を
// 含む id の一意性・書式、レベル値の範囲をここで固定する。
// 生成は tool/generate_songdb.dart が行い、壊したらこのテストが落ちる。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

void main() {
  // WHY: 配信 DB は repo ファイルを直接読む（rootBundle は flutter run 専用で
  // テストからは相対パスで開くほうが確実・CI でも同等）。
  final file = File('db/popn_hc_main_v1.json');
  final exists = file.existsSync();

  // WHY: 未生成は異常ではなく前提条件の不在。新規クローンでは必ず未生成になるため、
  // 失敗ではなく skip として扱う（取得元は tool/songdb_manifest.json に記録済み）。
  if (!exists) {
    test(
      'db/popn_hc_main_v1.json の整合性',
      () {},
      skip:
          'db/popn_hc_main_v1.json 未生成。'
          '`dart run tool/generate_songdb.dart` で生成すると検証される',
    );
    return;
  }

  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final songs = json['songs'] as List<dynamic>;

  test(
    '封筒は契約キーのみ（schemaVersion/dbVersion/updatedAt/sourceType/songCount/songs）',
    () {
      final keys = json.keys.toSet();
      expect(keys, <String>{
        'schemaVersion',
        'dbVersion',
        'updatedAt',
        'sourceType',
        'songCount',
        'songs',
      }, reason: 'リード設計レビュー決定: 余分なキーは追加しない');
    },
  );

  test('schemaVersion は 1、dbVersion は 1', () {
    expect(json['schemaVersion'], 1);
    expect(json['dbVersion'], 1);
  });

  test('sourceType は wikiHC', () {
    expect(json['sourceType'], 'wikiHC');
  });

  test('updatedAt は ISO8601 UTC', () {
    final parsed = DateTime.parse(json['updatedAt'] as String);
    expect(parsed.isUtc, isTrue, reason: '生成側は UTC で出す契約');
  });

  test('songCount は songs.length と一致し 2000 以上', () {
    expect(json['songCount'], songs.length);
    expect(
      songs.length,
      greaterThanOrEqualTo(2000),
      reason: '旧曲+新曲の実測 2100 曲規模。大幅に減っていたら収集漏れ',
    );
  });

  test('全エントリの normalizedKey は normalizeSongTitle(title) と一致する', () {
    final mismatches = <String>[];
    for (final songJson in songs) {
      final song = songJson as Map<String, dynamic>;
      final expected = normalizeSongTitle(song['title'] as String);
      if (song['normalizedKey'] != expected) {
        mismatches.add(
          '${song['id']}: key=${song['normalizedKey']} expected=$expected',
        );
      }
    }
    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });

  test('id は hc-<section>-<sha1 10桁> 形式で全件一意', () {
    final ids = <String>{};
    final duplicates = <String>[];
    final badFormat = <String>[];
    final idPattern = RegExp(r'^hc-(ac|cs|ee|new)-[0-9a-f]{10}$');
    for (final songJson in songs) {
      final id = (songJson as Map<String, dynamic>)['id'] as String;
      if (!idPattern.hasMatch(id)) {
        badFormat.add(id);
      }
      if (!ids.add(id)) {
        duplicates.add(id);
      }
    }
    expect(badFormat, isEmpty, reason: badFormat.join('\n'));
    expect(duplicates, isEmpty, reason: '同名異曲は id の派生種で区別する契約');
  });

  test('levels は sparse（null 値を含まず）で値は 1〜50', () {
    final problems = <String>[];
    for (final songJson in songs) {
      final song = songJson as Map<String, dynamic>;
      final levels = song['levels'] as Map<String, dynamic>?;
      if (levels == null) {
        problems.add('${song['id']}: levels なし');
        continue;
      }
      for (final e in levels.entries) {
        if (e.value is! int) {
          problems.add('${song['id']}: ${e.key}=${e.value} は int ではない');
        } else if ((e.value as int) < 1 || (e.value as int) > 50) {
          problems.add('${song['id']}: ${e.key}=${e.value} は範囲外');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('totalNotes は hc-new- の id にのみ設定される', () {
    final problems = <String>[];
    for (final songJson in songs) {
      final song = songJson as Map<String, dynamic>;
      final id = song['id'] as String;
      final totalNotes = song['totalNotes'];
      if (id.startsWith('hc-new-')) {
        if (totalNotes == null) {
          problems.add('$id: 新曲なのに totalNotes なし');
        }
      } else if (totalNotes != null) {
        problems.add('$id: 旧曲なのに totalNotes=$totalNotes が設定されている');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
