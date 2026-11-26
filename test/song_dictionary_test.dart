// ST-5 曲名辞書テスト（TDD）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_dictionary.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

void main() {
  group('StaticSongDictionary', () {
    test('空リストでは length 0、contains は false', () {
      final dict = StaticSongDictionary(<String>[]);
      expect(dict.length, equals(0));
      expect(dict.contains('anything'), isFalse);
    });

    test('登録されたタイトルの正規化済み形式で contains は true', () {
      final dict = StaticSongDictionary(<String>['黒髪乱れし修羅となりて']);
      expect(dict.contains('黒髪乱れし修羅となりて'), isTrue);
      expect(dict.originalTitle('黒髪乱れし修羅となりて'), equals('黒髪乱れし修羅となりて'));
    });

    test('未登録タイトルでは contains は false', () {
      final dict = StaticSongDictionary(<String>['ABC']);
      expect(dict.contains('XYZ'), isFalse);
    });

    test('全角英数字を含むタイトルは正規化されて照合', () {
      final dict = StaticSongDictionary(<String>['ＡＢＣ１２３']);
      expect(dict.contains('abc123'), isTrue);
    });

    test('titles は正規化済みリストを返す', () {
      final dict = StaticSongDictionary(<String>['ＡＢＣ', 'def']);
      expect(dict.titles, contains('abc'));
      expect(dict.titles, contains('def'));
    });
  });

  group('GtCsvSongDictionary', () {
    test('docs/ground_truth_template.csv から曲名を読込', () {
      final csvPath = 'docs/ground_truth_template.csv';
      expect(File(csvPath).existsSync(), isTrue, reason: 'GT CSV が存在すること');

      final dict = GtCsvSongDictionary(csvPath);
      expect(dict.length, greaterThan(0));

      // scr001-009 の曲名が含まれていることを確認
      expect(dict.contains('黒髪乱れし修羅となりて'), isTrue);
      expect(dict.contains('金縛りの逢を'), isTrue);
    });

    test('曲名が空欄の行はスキップされる', () {
      final dict = GtCsvSongDictionary('docs/ground_truth_template.csv');
      // 既存30枚の空曲名行（al9lbl, 5p1lg4, kt1odi, yb5h8w, bet7t4, enco0h, s4i71t, z29mk5）はスキップ
      // scr001-009 はすべて曲名ありなので length >= 9
      expect(dict.length, greaterThanOrEqualTo(9));
    });

    test('originalTitle で元表記を取得', () {
      final dict = GtCsvSongDictionary('docs/ground_truth_template.csv');
      final normalized = normalizeSongTitle('黒髪乱れし修羅となりて');
      expect(dict.originalTitle(normalized), isNotNull);
    });
  });
}
