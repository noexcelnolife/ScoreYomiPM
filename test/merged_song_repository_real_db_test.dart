// 実データ（db/popn_hc_main_v1.json）を MergedSongRepository に通す結合テスト。
//
// WHY(単体テストと分けるか): merged_song_repository_test.dart は偽リポジトリで
// 仕様（ソース間の優先順位・ソース内の全行保持・並び順）を固定する。こちらは
// 「実データ 2,100 行がマージ層で消えない」という結果を確かめる。仕様が同じでも
// 実データの重複の形（14 群・各 2 行）が違えば落ちるので、両方要る。
//
// WHY(未生成なら skip か): 配信 DB は BEMANIWiki の表を変換した第三者コンテンツで
// リポジトリに含めない（.gitignore の /db/）。新規クローンでは必ず未生成になるため、
// 失敗ではなく skip として扱う（db_popn_hc_main_v1_consistency_test.dart と同じ扱い）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/in_memory_song_repository.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_json_parser.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';

void main() {
  final file = File('db/popn_hc_main_v1.json');

  if (!file.existsSync()) {
    test(
      '実データのマージ',
      () {},
      skip:
          'db/popn_hc_main_v1.json 未生成。'
          '`dart run tool/generate_songdb.dart` で生成すると検証される',
    );
    return;
  }

  // アプリと同じ経路（JSON → SongEntry）で読む。ここで行が減っていたら
  // マージ層以前の問題なので、件数を先に固定する。
  final entries = parseSongsJson(file.readAsStringSync());
  final merged = MergedSongRepository(
    sources: <SongRepository>[
      InMemorySongRepository(entries: entries, sourceName: 'downloadedMain'),
    ],
    loaders: const <BlobStoreSongRepositoryLoader>[],
  );

  test('実データの全行がマージ後も残る', () {
    expect(entries.length, equals(2100));
    expect(merged.length, equals(2100));
    expect(merged.allSongs.length, equals(entries.length));
  });

  test('同名異曲 14 群は全行残り、照合は id 最小の行を返す', () {
    final rowsByKey = <String, List<SongEntry>>{};
    for (final entry in entries) {
      (rowsByKey[entry.normalizedKey] ??= <SongEntry>[]).add(entry);
    }
    final duplicateKeys =
        rowsByKey.entries.where((e) => e.value.length > 1).toList();

    expect(duplicateKeys.length, equals(14), reason: '実データの同名異曲は 14 群');

    for (final group in duplicateKeys) {
      final sortedIds = group.value.map((e) => e.id).toList()..sort();
      final representative = merged.findByNormalizedKey(group.key);
      expect(
        representative?.id,
        equals(sortedIds.first),
        reason: '${group.key}: 照合は id 最小（${sortedIds.join(', ')}）',
      );
      final survived = merged.allSongs
          .where((e) => e.normalizedKey == group.key)
          .length;
      expect(
        survived,
        equals(group.value.length),
        reason: '${group.key}: 同性質の行は捨てない',
      );
    }
  });

  test('代表例: homesickpt.2&3 は 4 譜面の行が返る', () {
    // 旧実装は NORMAL 1 譜面の行を返していた（id の辞書順で負けた方）。
    final representative = merged.findByNormalizedKey('homesickpt.2&3');
    expect(representative?.id, equals('hc-ac-8aad763a4f'));
    expect(representative?.levels.length, equals(4));
  });

  test('allSongs は (normalizedKey, id) 昇順で並ぶ', () {
    final songs = merged.allSongs;
    for (int i = 1; i < songs.length; i++) {
      final previous = songs[i - 1];
      final current = songs[i];
      final byKey = previous.normalizedKey.compareTo(current.normalizedKey);
      final ordered = byKey < 0 || (byKey == 0 && previous.id.compareTo(current.id) <= 0);
      expect(
        ordered,
        isTrue,
        reason: '${previous.normalizedKey}/${previous.id} の次に '
            '${current.normalizedKey}/${current.id} が来ている',
      );
    }
  });
}
