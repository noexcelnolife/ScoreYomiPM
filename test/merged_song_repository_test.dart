// ST-6 マージリポジトリテスト（TDD）

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';

/// テスト用スタブリポジトリ。
class TestSongRepository implements SongRepository {
  final String name;
  final List<SongEntry> songs;
  final bool available;

  TestSongRepository({
    required this.name,
    required this.songs,
    this.available = true,
  });

  @override
  String get sourceName => name;

  @override
  bool get isAvailable => available;

  @override
  List<SongEntry> get allSongs => List.unmodifiable(songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final entry in songs) {
      if (entry.normalizedKey == normalizedKey) {
        return entry;
      }
    }
    return null;
  }

  @override
  int get length => songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      songs.any((e) => e.normalizedKey == normalizedKey);
}

void main() {
  group('MergedSongRepository', () {
    test('3ソースをマージして重複なく統合', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 's1', title: 'Seed Song', normalizedKey: 'seedsong'),
          SongEntry(
            id: 's2',
            title: 'Common Song',
            normalizedKey: 'commonsong',
          ),
        ],
      );
      final main = TestSongRepository(
        name: 'main',
        songs: <SongEntry>[
          SongEntry(id: 'm1', title: 'Main Song', normalizedKey: 'mainsong'),
          SongEntry(
            id: 'm2',
            title: 'Common Song v2',
            normalizedKey: 'commonsong',
          ),
        ],
      );
      final additional = TestSongRepository(
        name: 'additional',
        songs: <SongEntry>[
          SongEntry(
            id: 'a1',
            title: 'Additional Song',
            normalizedKey: 'additionalsong',
          ),
          SongEntry(
            id: 'a2',
            title: 'Common Song v3',
            normalizedKey: 'commonsong',
          ),
        ],
      );

      final merged = MergedSongRepository(sources: <SongRepository>[
        additional, // 最高優先
        main,
        seed, // 最低優先
], loaders: const <BlobStoreSongRepositoryLoader>[]);

      expect(merged.length, equals(4));
      expect(merged.sourceName, contains('merged'));

      // 重複キー 'commonsong' は最高優先 (additional) の 'Common Song v3' が勝つ
      final common = merged.findByNormalizedKey('commonsong');
      expect(common?.title, equals('Common Song v3'));
      expect(common?.id, equals('a2'));

      // 非重複はすべて存在
      expect(
        merged.findByNormalizedKey('seedsong')?.title,
        equals('Seed Song'),
      );
      expect(
        merged.findByNormalizedKey('mainsong')?.title,
        equals('Main Song'),
      );
      expect(
        merged.findByNormalizedKey('additionalsong')?.title,
        equals('Additional Song'),
      );
    });

    test('優先順位: localAdditional > downloadedMain > bundledSeed', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 's1', title: 'Seed', normalizedKey: 'dupe'),
        ],
      );
      final main = TestSongRepository(
        name: 'main',
        songs: <SongEntry>[
          SongEntry(id: 'm1', title: 'Main', normalizedKey: 'dupe'),
        ],
      );
      final additional = TestSongRepository(
        name: 'additional',
        songs: <SongEntry>[
          SongEntry(id: 'a1', title: 'Additional', normalizedKey: 'dupe'),
        ],
      );

      final merged = MergedSongRepository(sources: <SongRepository>[
        additional,
        main,
        seed,
], loaders: const <BlobStoreSongRepositoryLoader>[]);

      final dupe = merged.findByNormalizedKey('dupe');
      expect(dupe?.title, equals('Additional'));
      expect(dupe?.id, equals('a1'));
    });

    test('containsNormalizedKey で存在確認', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 's1', title: 'Seed', normalizedKey: 'seedsong'),
        ],
      );
      final merged = MergedSongRepository(sources: <SongRepository>[seed], loaders: const <BlobStoreSongRepositoryLoader>[]);

      expect(merged.containsNormalizedKey('seedsong'), isTrue);
      expect(merged.containsNormalizedKey('nonexistent'), isFalse);
    });

    test('allSongs は正規化キー順でソート', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 's2', title: 'B Song', normalizedKey: 'bsong'),
          SongEntry(id: 's1', title: 'A Song', normalizedKey: 'asong'),
        ],
      );
      final merged = MergedSongRepository(sources: <SongRepository>[seed], loaders: const <BlobStoreSongRepositoryLoader>[]);

      expect(merged.allSongs[0].normalizedKey, equals('asong'));
      expect(merged.allSongs[1].normalizedKey, equals('bsong'));
    });

    test('isAvailable は全ソースが unavailable なら false', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[],
        available: false,
      );
      final merged = MergedSongRepository(sources: <SongRepository>[seed], loaders: const <BlobStoreSongRepositoryLoader>[]);
      expect(merged.isAvailable, isFalse);
    });

    test('isAvailable は1つでも available なら true', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[],
        available: false,
      );
      final main = TestSongRepository(
        name: 'main',
        songs: <SongEntry>[
          SongEntry(id: 'm1', title: 'Main', normalizedKey: 'mainsong'),
        ],
        available: true,
      );
      final merged = MergedSongRepository(sources: <SongRepository>[seed, main], loaders: const <BlobStoreSongRepositoryLoader>[]);
      expect(merged.isAvailable, isTrue);
    });

    test('空ソースリストでは length 0', () {
      final merged = MergedSongRepository(sources: <SongRepository>[], loaders: const <BlobStoreSongRepositoryLoader>[]);
      expect(merged.length, equals(0));
      expect(merged.allSongs, isEmpty);
    });
  });

  // 実データでは正規化キーが同じ別曲が 14 群ある（版違い・アレンジ違い）。
  // 旧実装はキー 1 本につき 1 行しか残さず、その 14 群で曲が消えていた。
  group('同名異曲（同一 normalizedKey が複数行ある場合）', () {
    test('ソース内の同一キー 2 行は両方残り、照合は id 最小を返す', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(
            id: 'k-b',
            title: 'Same Name (Long)',
            normalizedKey: 'samename',
          ),
          SongEntry(
            id: 'k-a',
            title: 'Same Name (Normal)',
            normalizedKey: 'samename',
          ),
        ],
      );
      final merged = MergedSongRepository(
        sources: <SongRepository>[seed],
        loaders: const <BlobStoreSongRepositoryLoader>[],
      );

      // 同名でも別曲なので、2 行とも allSongs に残る。
      expect(merged.length, equals(2));
      expect(
        merged.allSongs.map((e) => e.id).toList(),
        equals(<String>['k-a', 'k-b']),
      );

      // 照合結果は id 最小の 1 行に固定される。
      expect(merged.findByNormalizedKey('samename')?.id, equals('k-a'));
    });

    test('2 ソースが同一キーを持つ場合、上位ソースの行だけが残る', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 'low-1', title: 'Dupe (seed)', normalizedKey: 'dupe'),
          // 下位ソース固有のキーは消えてはいけない。
          SongEntry(
            id: 'low-9',
            title: 'Seed Only',
            normalizedKey: 'seedonly',
          ),
        ],
      );
      final main = TestSongRepository(
        name: 'main',
        songs: <SongEntry>[
          SongEntry(id: 'high-1', title: 'Dupe (main)', normalizedKey: 'dupe'),
        ],
      );
      final merged = MergedSongRepository(
        sources: <SongRepository>[main, seed],
        loaders: const <BlobStoreSongRepositoryLoader>[],
      );

      // 'dupe' は上位 1 行のみ。下位の 'low-1' は同一キーごと捨てる。
      expect(merged.findByNormalizedKey('dupe')?.id, equals('high-1'));
      expect(
        merged.allSongs.where((e) => e.normalizedKey == 'dupe').length,
        equals(1),
      );
      // 下位ソース固有のキーは残る（ソース丸ごと破棄ではない）。
      expect(merged.findByNormalizedKey('seedonly')?.id, equals('low-9'));
      expect(merged.length, equals(2));
    });

    test('上位 1 行・下位 2 行（同名異曲）なら上位 1 行だけが残る', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 'low-1', title: 'Dupe (Long)', normalizedKey: 'dupe'),
          SongEntry(
            id: 'low-2',
            title: 'Dupe (Normal)',
            normalizedKey: 'dupe',
          ),
        ],
      );
      final main = TestSongRepository(
        name: 'main',
        songs: <SongEntry>[
          SongEntry(id: 'high-1', title: 'Dupe (main)', normalizedKey: 'dupe'),
        ],
      );
      final merged = MergedSongRepository(
        sources: <SongRepository>[main, seed],
        loaders: const <BlobStoreSongRepositoryLoader>[],
      );

      // 下位ソース内の同名異曲 2 行は、上位がキーを持つ以上どちらも残さない。
      expect(merged.length, equals(1));
      expect(merged.allSongs.single.id, equals('high-1'));
      expect(merged.findByNormalizedKey('dupe')?.id, equals('high-1'));
    });

    test('allSongs は (normalizedKey, id) 昇順で並ぶ', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[
          SongEntry(id: 'z-9', title: 'Beta 9', normalizedKey: 'beta'),
          SongEntry(id: 'a-1', title: 'Alpha 1', normalizedKey: 'alpha'),
          SongEntry(id: 'z-2', title: 'Beta 2', normalizedKey: 'beta'),
          SongEntry(id: 'a-7', title: 'Alpha 7', normalizedKey: 'alpha'),
        ],
      );
      final merged = MergedSongRepository(
        sources: <SongRepository>[seed],
        loaders: const <BlobStoreSongRepositoryLoader>[],
      );

      // キーだけで並べると同キー内の順序が未定義になり、実行ごとに揺れる。
      expect(
        merged.allSongs.map((e) => e.id).toList(),
        equals(<String>['a-1', 'a-7', 'z-2', 'z-9']),
      );
    });
  });
}


