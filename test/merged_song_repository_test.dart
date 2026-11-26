// ST-6 マージリポジトリテスト（TDD）

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/merged_song_repository.dart';
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

      final merged = MergedSongRepository(<SongRepository>[
        additional, // 最高優先
        main,
        seed, // 最低優先
      ]);

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

      final merged = MergedSongRepository(<SongRepository>[
        additional,
        main,
        seed,
      ]);

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
      final merged = MergedSongRepository(<SongRepository>[seed]);

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
      final merged = MergedSongRepository(<SongRepository>[seed]);

      expect(merged.allSongs[0].normalizedKey, equals('asong'));
      expect(merged.allSongs[1].normalizedKey, equals('bsong'));
    });

    test('isAvailable は全ソースが unavailable なら false', () {
      final seed = TestSongRepository(
        name: 'seed',
        songs: <SongEntry>[],
        available: false,
      );
      final merged = MergedSongRepository(<SongRepository>[seed]);
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
      final merged = MergedSongRepository(<SongRepository>[seed, main]);
      expect(merged.isAvailable, isTrue);
    });

    test('空ソースリストでは length 0', () {
      final merged = MergedSongRepository(<SongRepository>[]);
      expect(merged.length, equals(0));
      expect(merged.allSongs, isEmpty);
    });
  });
}
