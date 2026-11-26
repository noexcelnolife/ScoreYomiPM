// ST-6 Bundled Seed リポジトリテスト（TDD）

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/bundled_seed_repository.dart';

void main() {
  // WHY: rootBundle は platform channel 経由で asset を読むため、
  // 素の test() では TestWidgetsFlutterBinding の初期化が必須。
  // 未初期化だと loadString が失敗し、outer catch で _loaded=false になる。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BundledSeedRepository', () {
    test('asset JSON から33曲を読込', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      expect(repo.isAvailable, isTrue);
      expect(repo.length, equals(33));
      expect(repo.sourceName, contains('bundledSeed'));
    });

    test('特定曲名で検索', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      final entry = repo.findByNormalizedKey('harmonia');
      expect(entry, isNotNull);
      expect(entry?.title, equals('Harmonia'));
      expect(entry?.genre, equals('NUPRELUDE'));
    });

    test('存在しないキーは null を返す', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      expect(repo.findByNormalizedKey('nonexistent'), isNull);
    });

    test('containsNormalizedKey で存在確認', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      expect(repo.containsNormalizedKey('harmonia'), isTrue);
      expect(repo.containsNormalizedKey('nonexistent'), isFalse);
    });

    test('scr 曲名も含まれる', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      expect(repo.containsNormalizedKey('黒髪乱れし修羅となりて'), isTrue);
      expect(repo.containsNormalizedKey('sorrows'), isTrue);
      expect(repo.containsNormalizedKey('majestaria'), isTrue);
    });

    test('load 後の allSongs はソート済み', () async {
      final repo = BundledSeedRepository();
      await repo.load();

      final keys = repo.allSongs.map((e) => e.normalizedKey).toList();
      final sortedKeys = List<String>.from(keys)..sort();
      expect(keys, equals(sortedKeys));
    });
  });
}
