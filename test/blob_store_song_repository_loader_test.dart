import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_browser.dart';

import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/in_memory_song_repository.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_json_parser.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/platform/idb_blob_store.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';

/// 最小限の songs JSON を生成する。
String _songsJson(List<Map<String, dynamic>> songs) =>
    jsonEncode(<String, dynamic>{'songs': songs});

/// テスト用の SongEntry リストを作成する。
List<Map<String, dynamic>> _songRows({
  required int count,
  String prefix = 'song',
}) {
  return List.generate(count, (i) {
    return <String, dynamic>{
      'id': '$prefix-$i',
      'title': '$prefix $i',
      'artist': 'artist $i',
      'bpm': 120,
      'difficulty': 5,
      'notes': <dynamic>[],
    };
  });
}

Future<InMemorySongRepository> _loadViaLoader(
  BlobStore blobStore,
  String key,
  List<SongEntry> Function(String json) parser,
) async {
  final loader = BlobStoreSongRepositoryLoader(
    blobStore: blobStore,
    key: key,
    parser: parser,
  );
  return loader.load();
}

void main() {
  group('BlobStoreSongRepositoryLoader (§5-1)', () {
    test(
      '(c) IoBlobStore で書き込み → ローダー経由で取得（往復）',
      () async {
        final blobStore = MemoryBlobStore();
        final key = SongDbPaths.additionalDbRelativePath;

        // 書き込み（取り込み後の状態をシミュレート）。
        final songs = _songRows(count: 3, prefix: 'added');
        await blobStore.write(key, utf8.encode(_songsJson(songs)));

        final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
        expect(repo.entries.length, 3);
        expect(repo.entries.map((e) => e.id).toList(),
            <String>['added-0', 'added-1', 'added-2']);
      },
    );

    test(
      '(c) IdbBlobStore(newIdbFactoryMemory()) で書き込み → ローダー経由で取得（Web 往復）',
      () async {
        final blobStore = IdbBlobStore(idbFactoryMemory);
        final key = SongDbPaths.additionalDbRelativePath;

        final songs = _songRows(count: 2, prefix: 'web');
        await blobStore.write(key, utf8.encode(_songsJson(songs)));

        final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
        expect(repo.entries.length, 2);
        expect(repo.entries.map((e) => e.id).toList(), <String>['web-0', 'web-1']);
      },
    );

    test('(d) 壊れた JSON でも例外を投げず空リポジトリを返す', () async {
      final blobStore = MemoryBlobStore();
      final key = SongDbPaths.additionalDbRelativePath;

      await blobStore.write(key, utf8.encode('{ this is not json'));

      final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
      expect(repo.entries, isEmpty);
    });

    test('(d) songs キー欠落でも例外を投げず空リポジトリを返す', () async {
      final blobStore = MemoryBlobStore();
      final key = SongDbPaths.additionalDbRelativePath;

      await blobStore.write(key, utf8.encode(jsonEncode(<String, dynamic>{})));

      final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
      expect(repo.entries, isEmpty);
    });

    test('(d) 行の型違いでも例外を投げず空リポジトリを返す', () async {
      final blobStore = MemoryBlobStore();
      final key = SongDbPaths.additionalDbRelativePath;

      await blobStore.write(
        key,
        utf8.encode(jsonEncode(<String, dynamic>{
          'songs': <dynamic>['not an object', 42, null],
        })),
      );

      final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
      expect(repo.entries, isEmpty);
    });

    test('(d) データなしのキーでも空リポジトリを返す', () async {
      final blobStore = MemoryBlobStore();
      final key = SongDbPaths.additionalDbRelativePath;

      final repo = await _loadViaLoader(blobStore, key, parseSongsJson);
      expect(repo.entries, isEmpty);
    });
  });

  group('MergedSongRepository.reload() (§2.4 回帰テスト)', () {
    test(
      '(a) 取り込み → reload() → findCandidates が新しい曲を返す',
      () async {
        final blobStore = MemoryBlobStore();
        final key = SongDbPaths.additionalDbRelativePath;

        // ローダーで MergedSongRepository を構築（初期は空）。
        final loader = BlobStoreSongRepositoryLoader(
          blobStore: blobStore,
          key: key,
          parser: parseSongsJson,
        );
        final repo = MergedSongRepository(
          sources: <SongRepository>[],
          loaders: <BlobStoreSongRepositoryLoader>[loader],
        );

        // reload() 前は空。
        expect(repo.findCandidates('new song'), isEmpty);

        // 取り込み：BlobStore に songs を書き込む。
        await blobStore.write(
          key,
          utf8.encode(
            _songsJson(_songRows(count: 2, prefix: 'imported')),
          ),
        );

        // reload() で読み直し。
        await repo.reload();

        // 新しい曲が検索に出る。
        final candidates = repo.findCandidates('imported');
        expect(candidates.length, 2);
        expect(candidates.map((SongEntry e) => e.title).toList(),
            <String>['imported 0', 'imported 1']);
      },
    );

    test(
      '(b) reload() 前は新しい曲を返さない（＝本当に読み直している）',
      () async {
        final blobStore = MemoryBlobStore();
        final key = SongDbPaths.additionalDbRelativePath;

        final loader = BlobStoreSongRepositoryLoader(
          blobStore: blobStore,
          key: key,
          parser: parseSongsJson,
        );
        final repo = MergedSongRepository(
          sources: <SongRepository>[],
          loaders: <BlobStoreSongRepositoryLoader>[loader],
        );

        // 取り込み：BlobStore に songs を書き込む（reload() はまだ呼ばない）。
        await blobStore.write(
          key,
          utf8.encode(
            _songsJson(_songRows(count: 1, prefix: 'late')),
          ),
        );

        // reload() 前は空。
        expect(repo.findCandidates('late'), isEmpty);

        // reload() 後は新しい曲が出る。
        await repo.reload();
        expect(repo.findCandidates('late').length, 1);
      },
    );

    test(
      '(c) IdbBlobStore(newIdbFactoryMemory()) でも reload() が動く',
      () async {
        final blobStore = IdbBlobStore(idbFactoryMemory);
        final key = SongDbPaths.mainDbRelativePath;

        final loader = BlobStoreSongRepositoryLoader(
          blobStore: blobStore,
          key: key,
          parser: parseSongsJson,
        );
        final repo = MergedSongRepository(
          sources: <SongRepository>[],
          loaders: <BlobStoreSongRepositoryLoader>[loader],
        );

        // 初期は空。
        expect(repo.findCandidates('web'), isEmpty);

        // 書き込み → reload()。
        await blobStore.write(
          key,
          utf8.encode(_songsJson(_songRows(count: 1, prefix: 'webmain'))),
        );
        await repo.reload();

        // 新しい曲が出る。
        expect(repo.findCandidates('webmain').length, 1);
      },
    );
  });
}
