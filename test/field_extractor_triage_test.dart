// トリアージ用合成ケース: HC 抽出値の正 GT 検証（回転表現は撤回済み）
//
// 前提の訂正（リード 2026-11-23・01a208f7 再スコープ）:
//   従来「cool 733 / great 33 / good 975 / bad 58 / combo 2」は誤 GT
//   （ground_truth.json のどの版にも存在しない値）。正 GT は
//   score 98108 / cool 975 / great 58 / good 2 / bad 1 / combo 733
//   （判定合計 1036 = コンボ 733 以下で整合の注記付き）。本テストは
//   正 GT に基づき再定義し、「回転」表現を撤回する。
//
// WHY（hcV1 共通窓の構造）: hcV1 では cool/great/good の 3 種が同一の
// 列窓 (0.05, 0.20) を共有する（field_extractor.dart）。行分離は
// _sameRowTolerance = 0.012 の dy 判定のみのため、値が欠落する行では
//  隣接行の値の dy が 0.012 内に入ると誤対応し得る。実機 23bjim の生要素
//  には good/bad の値（2/1）が無く、GOOD↔975 dy=0.0995・BAD↔58 dy=0.017
//  はいずれも dy ゲート（0.012）から外れるため、good/bad が null になる
// 正しい挙動が実証される。本テストはそのうち共有列窓で値の欠落を
// 「設計正対応（欠落種別は null）」として確認する。

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

void main() {
  group('triage: hcV1 correct GT(synthetic)', () {
    // WHY: 1200x800 (hc_v1 横 1.5 系) を画像寸法として固定する。
    const width = 1200.0;
    const height = 800.0;

    OcrElement at(String text, double cx, double cy) {
      const half = 10.0;
      final x = cx * width;
      final y = cy * height;
      return OcrElement(
        text: text,
        boundingBox: Rect.fromLTRB(x - half, y - half, x + half, y + half),
        confidence: 0.9,
      );
    }

    test('control: all labels present — each kind gets its own row value', () {
      // WHY: 基準。正 GT（cool 975 / great 58 / good 2 / bad 1 /
      // maxCombo 733）で全ラベル有りのとき各 kind が本来の行値を得る。
      const score = 98108;
      const cool = 975;
      const great = 58;
      const good = 2;
      const bad = 1;
      const combo = 733;

      // 行配置（正規化 cy）: score / cool / great / good / bad / combo
      // dx: 観測中心（score 0.2533 / cool-great-good 0.1333 / bad 0.19 /
      // combo 0.14）。
      final page = OcrPageResult(
        elements: <OcrElement>[
          at('SCORE', 0.30, 0.10),
          at('98108', 0.30 + 0.2533, 0.10),
          at('COOL', 0.30, 0.30),
          at('975', 0.30 + 0.1333, 0.30),
          at('GREAT', 0.30, 0.40),
          at('58', 0.30 + 0.1333, 0.40),
          at('GOOD', 0.30, 0.50),
          at('2', 0.30 + 0.1333, 0.50),
          at('BAD', 0.30, 0.60),
          at('1', 0.30 + 0.19, 0.60),
          at('COMBO', 0.30, 0.70),
          at('733', 0.30 + 0.14, 0.70),
        ],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );

      final result = const FieldExtractor().extract(page);

      expect(result.score?.value, score);
      expect(result.cool?.value, cool);
      expect(result.great?.value, great);
      expect(result.good?.value, good);
      expect(result.bad?.value, bad);
      expect(result.maxCombo?.value, combo);
      expect(result.level, isNull);
    });

    test('control: a missing label element does not shift a following kind '
        '(missing row -> null, other rows keep their values)', () {
      // WHY: GREAT ラベル要素を欠落させる（ML Kit 未検出を模す）。値 58
      // は COOL 行の dy 0.008（0.012 内）に置かれているが、cool は同列の
      // 975（dy=0）を取得するため 58 を誤採用せず、great はラベル行が無い
      // ため null になる。GOOD/BAD/maxCombo は本来の値が得られることを
      // 「設計正対応」として確認する（前回の「赤」表現は撤回）。
      const score = 98108;
      const cool = 975;
      const good = 2;
      const bad = 1;
      const combo = 733;

      final page = OcrPageResult(
        elements: <OcrElement>[
          at('SCORE', 0.30, 0.100),
          at('98108', 0.30 + 0.2533, 0.100),
          at('COOL', 0.30, 0.300),
          at('975', 0.30 + 0.1333, 0.300),
          // GREAT ラベル要素は欠落。
          at('58', 0.30 + 0.1333, 0.308),
          at('GOOD', 0.30, 0.400),
          at('2', 0.30 + 0.1333, 0.400),
          at('BAD', 0.30, 0.500),
          at('1', 0.30 + 0.19, 0.500),
          at('COMBO', 0.30, 0.600),
          at('733', 0.30 + 0.14, 0.600),
        ],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );

      final result = const FieldExtractor().extract(page);

      expect(result.score?.value, score);
      expect(result.cool?.value, cool);
      expect(result.great, isNull);
      expect(result.good?.value, good);
      expect(result.bad?.value, bad);
      expect(result.maxCombo?.value, combo);
    });
  });
}
