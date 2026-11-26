// ST-5 曲名辞書照合テスト（TDD）

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

/// テスト用 SongRepository スタブ。
class TestSongRepository implements SongRepository {
  final Map<String, SongEntry> _entries = {};

  TestSongRepository(List<String> titles) {
    for (final title in titles) {
      // WHY: 本番では辞書側キーも normalizeSongTitle で正規化されるため、
      // スタブも同一の正規化を適用して照合パスを実機と揃える。
      final normalized = normalizeSongTitle(title);
      _entries[normalized] = SongEntry(
        id: normalized,
        title: title,
        normalizedKey: normalized,
      );
    }
  }

  @override
  String get sourceName => 'test';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => _entries.values.toList();

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) =>
      _entries[normalizedKey];

  @override
  int get length => _entries.length;

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      _entries.containsKey(normalizedKey);
}

void main() {
  group('SongTitleMatcher.match', () {
    test('完全一致 → autoDecided=true、distance=0', () {
      final dict = TestSongRepository(<String>['黒髪乱れし修羅となりて']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('黒髪乱れし修羅となりて');

      expect(result.hasMatch, isTrue);
      expect(result.autoDecided, isTrue);
      expect(result.bestDistance, equals(0));
      expect(result.bestMatchOriginal, equals('黒髪乱れし修羅となりて'));
      expect(result.topCandidates, hasLength(1));
    });

    test('正規化後の完全一致 → autoDecided=true', () {
      final dict = TestSongRepository(<String>['Harmonia']);
      final matcher = SongTitleMatcher(dict);
      // 入力は大文字（正規化後に一致）
      final result = matcher.match('HARMONIA');

      expect(result.hasMatch, isTrue);
      expect(result.autoDecided, isTrue);
      expect(result.bestDistance, equals(0));
    });

    test('レーベンシュタイン距離 1 → autoDecided=true（候補1件）', () {
      final dict = TestSongRepository(<String>['黒髪乱れし修羅となりて']);
      final matcher = SongTitleMatcher(dict);
      // 1 文字の誤検出（末尾 'て' 欠落）
      final result = matcher.match('黒髪乱れし修羅となり');

      expect(result.hasMatch, isTrue);
      expect(result.autoDecided, isTrue);
      expect(result.bestDistance, equals(1));
    });

    test('距離 2-3 → autoDecided=false、TopK 候補あり', () {
      final dict = TestSongRepository(<String>['ABCDE', 'ABCDF', 'ABCDG']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('ABCDZ'); // 距離 1 で3件すべて候補

      expect(result.hasMatch, isTrue);
      expect(result.autoDecided, isFalse);
      expect(result.topCandidates, hasLength(3));
      expect(result.topCandidates.first.distance, equals(1));
    });

    test('距離 > 3 → hasMatch=false、candidates 空', () {
      final dict = TestSongRepository(<String>['ABCDE']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('XYZAB'); // 距離 5

      expect(result.hasMatch, isFalse);
      expect(result.autoDecided, isFalse);
      expect(result.topCandidates, isEmpty);
      expect(result.bestDistance, isNull);
    });

    test('空文字列 → hasMatch=false、autoDecided=false', () {
      final dict = TestSongRepository(<String>['ABC']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('');

      expect(result.hasMatch, isFalse);
      expect(result.autoDecided, isFalse);
      expect(result.topCandidates, isEmpty);
    });

    test('大文字小文字差は無視（正規化済み）', () {
      final dict = TestSongRepository(<String>['Hello World']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('hello world');

      expect(result.hasMatch, isTrue);
      expect(result.autoDecided, isTrue);
      expect(result.bestDistance, equals(0));
    });

    test('複数辞書エントリから最も近いを選択', () {
      final dict = TestSongRepository(<String>['ABC', 'XYZ']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('ABD'); // ABC と距離 1、XYZ と距離 3

      expect(result.bestMatchNormalized, equals('abc'));
      expect(result.bestDistance, equals(1));
      // 候補が2件あるため autoDecided は false（FR-3 で確認が必要）
      expect(result.autoDecided, isFalse);
      expect(result.topCandidates, hasLength(2));
    });

    test('rawOcrText と normalizedOcrText は保持', () {
      final dict = TestSongRepository(<String>['Test']);
      final matcher = SongTitleMatcher(dict);
      final result = matcher.match('Test!');

      expect(result.rawOcrText, equals('Test!'));
      expect(result.normalizedOcrText, equals('test'));
      expect(result.bestMatchOriginal, equals('Test'));
    });
  });
}
