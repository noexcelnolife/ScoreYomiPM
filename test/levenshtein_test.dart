// ST-5 レーベンシュタイン距離テスト（TDD）

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/levenshtein.dart';

void main() {
  group('levenshteinDistance', () {
    test('同一文字列は距離 0', () {
      expect(levenshteinDistance('', ''), equals(0));
      expect(levenshteinDistance('abc', 'abc'), equals(0));
      expect(levenshteinDistance('黒髪', '黒髪'), equals(0));
    });

    test('空文字列 vs 非空文字列は長さが距離', () {
      expect(levenshteinDistance('', 'abc'), equals(3));
      expect(levenshteinDistance('abc', ''), equals(3));
      expect(levenshteinDistance('', ''), equals(0));
    });

    test('1 文字の挿入', () {
      expect(levenshteinDistance('abc', 'abcd'), equals(1));
      expect(levenshteinDistance('abcd', 'abc'), equals(1));
    });

    test('1 文字の削除', () {
      expect(levenshteinDistance('abcd', 'abc'), equals(1));
    });

    test('1 文字の置換', () {
      expect(levenshteinDistance('abc', 'abd'), equals(1));
      expect(levenshteinDistance('kitten', 'sitting'), equals(3));
    });

    test('完全に異なる文字列', () {
      expect(levenshteinDistance('abc', 'xyz'), equals(3));
    });

    test('日本語文字列', () {
      expect(levenshteinDistance('黒髪', '黒髪乱れし'), equals(3));
      expect(levenshteinDistance('修羅となりて', '修羅となり'), equals(1));
    });

    test('距離 2 以上の例', () {
      expect(levenshteinDistance('hello', 'hallo'), equals(1));
      expect(levenshteinDistance('hello', 'helo'), equals(1));
      expect(levenshteinDistance('hello', 'helloo'), equals(1));
    });
  });
}
