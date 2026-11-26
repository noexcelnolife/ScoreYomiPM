// ST-5 曲名正規化テスト（TDD）
//
// spec.md §5.3 ST-5 に整合:
//   - 全角半角変換（ａ-ｚ→a-z, Ａ-Ｚ→A-Z, ０-９→0-9）
//   - 記号・空白除去（・, ♪, ♥, ★, ☆, スペース等）
//   - 大文字小文字畳み込み（toLowerCase）
//   - カタカナ/ひらがな/漢字は保持

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

void main() {
  group('normalizeSongTitle', () {
    test('空文字列は空文字列を返す', () {
      expect(normalizeSongTitle(''), equals(''));
    });

    test('全角英字 → 半角英字', () {
      expect(normalizeSongTitle('ＡＢＣａｂｃ'), equals('abcabc'));
    });

    test('全角数字 → 半角数字', () {
      expect(normalizeSongTitle('１２３'), equals('123'));
    });

    test('大文字小文字畳み込み', () {
      expect(normalizeSongTitle('Harmonia'), equals('harmonia'));
      expect(normalizeSongTitle('HARMONIA'), equals('harmonia'));
    });

    test('記号・空白を除去', () {
      expect(normalizeSongTitle('黒髪・乱れし・修羅'), equals('黒髪乱れし修羅'));
      expect(normalizeSongTitle('金縛り ♪ の ♥ 逢を'), equals('金縛りの逢を'));
      expect(normalizeSongTitle('  ★  SONG  ☆  '), equals('song'));
    });

    test('全角スペース・全角句読点を除去', () {
      expect(normalizeSongTitle('曲名。副題、'), equals('曲名副題'));
    });

    test('カタカナ/ひらがな/漢字は保持', () {
      expect(normalizeSongTitle('黒髪乱れし修羅となりて'), equals('黒髪乱れし修羅となりて'));
    });

    test('混合入力: 全角英数字+記号+カナ+漢字', () {
      expect(normalizeSongTitle('ＡＢＣ１２３・黒髪・乱れし！'), equals('abc123黒髪乱れし'));
    });

    test('制御文字は除去', () {
      expect(normalizeSongTitle('テスト\tテスト\nテスト'), equals('テストテストテスト'));
    });
  });
}
