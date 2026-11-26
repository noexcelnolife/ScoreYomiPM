// ST-4 フィールド抽出コアのユニットテスト（合成フィクスチャ）。
//
// 幾何パラメータ（列窓・同一直行幅）は実データ統計
// （docs/field_layout_stats_2026-11-22.md §4.2 / §7 と Ground Truth 9 サンプル
// 照合で確認した真の幾何）に基づく。実データでの抽出率・GT 一致率は
// test/field_extractor_real_data_test.dart の担当。
//
// 合成レイアウトは正規化座標で記述する（実データは画像寸法が 19 パターン
// あるため絶対座標は禁止・stats §7①）。

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

/// 合成画像の寸法（任意。正規化座標なので値に依存しないことを検証する
/// ため、テストごとに異なる寸法を使う場合もある）。
const int _w = 1200;
const int _h = 800;

/// 正規化座標（中心 cx・cy）と要素高さ hNorm から [OcrElement] を組む。
OcrElement el(
  String text,
  double cx,
  double cy, {
  double hNorm = 0.02,
  double confidence = 0.9,
}) {
  final wNorm = text.length * 0.01;
  final left = (cx - wNorm / 2) * _w;
  final top = (cy - hNorm / 2) * _h;
  return OcrElement(
    text: text,
    boundingBox: Rect.fromLTWH(left, top, wNorm * _w, hNorm * _h),
    confidence: confidence,
  );
}

OcrPageResult page(List<OcrElement> elements, {int? width, int? height}) =>
    OcrPageResult(
      elements: elements,
      fullText: elements.map((e) => e.text).join(' '),
      // WHY: 正規化座標のテストだが抽出器は絶対 bbox を正規化へ変換するの
      // で寸法が必須（engine 相当の役割をテストヘルパーが果たす）。
      // 未指定時は _w/_h（1200x800）を既定とする。寸法欠落のケースは
      // page() を経由せず OcrPageResult を直接構築して検証する。
      imageWidth: width ?? _w,
      imageHeight: height ?? _h,
    );

FieldExtractionResult extract(List<OcrElement> elements) =>
    const FieldExtractor().extract(page(elements));

void main() {
  group('スコア', () {
    test('SCORE ラベルと同一行・右側列の 5 桁値を抽出する', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('98108', 0.8316, 0.4763),
      ]);

      final score = result.score!;
      expect(score.kind, NumericFieldKind.score);
      expect(score.value, 98108);
      expect(score.rawText, '98108');
      expect(score.isValid, isTrue);
      expect(score.evidence, hasLength(2));
    });

    test('全角数字と区切り文字を正規化する', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('９８，１０８', 0.8316, 0.4763),
      ]);

      expect(result.score!.value, 98108);
      expect(result.score!.rawText, '９８，１０８');
    });

    test('非数字 1 文字（O）は 0 に置換する（g7p9b2 の 9500O → 95000）', () {
      // WHY: 末尾の O は 0 の誤読。除去すると 9500（GT 95000 と不一致）に
      // なるため、置換で復元するのが正しい（GT 照合で確認）。
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('9500O', 0.8316, 0.4763),
      ]);

      expect(result.score!.value, 95000);
    });

    test('非数字が 2 文字以上ある値（BO 等）は偽値防止のため拒否する', () {
      // WHY: bet7t4 で BAD 値 30 が「BO」と誤読された実例。2 文字以上の
      // 混入は単一文字置換で復元できる水準を超えるため未抽出にする。
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('BO', 0.8316, 0.4763),
      ]);

      expect(result.score, isNull);
    });

    test('4 桁スコアは落字疑いとして信頼度を半減させる', () {
      // WHY: GT クロスチェックで 4 桁スコア（96401→9640）は末尾落字だった。
      final normal = extract([
        el('SCORE', 0.5783, 0.4763),
        el('98108', 0.8316, 0.4763, confidence: 0.9),
      ]);
      final suspected = extract([
        el('SCORE', 0.5783, 0.4763),
        el('9640', 0.8316, 0.4763, confidence: 0.9),
      ]);

      expect(normal.score!.confidence, closeTo(0.9, 0.0001));
      expect(suspected.score!.confidence, closeTo(0.45, 0.0001));
      // 値そのものは範囲内なので isValid は true（消費側が信頼度で判断）。
      expect(suspected.score!.isValid, isTrue);
      expect(suspected.score!.value, 9640);
    });

    test('検証範囲外のスコアは isValid=false（抽出失敗として区別）', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('999999', 0.8316, 0.4763),
      ]);

      final score = result.score!;
      expect(score.value, 999999);
      expect(score.isValid, isFalse);
      expect(score.validationMessage, isNotNull);
    });
  });

  group('判定数', () {
    test('COOL/GREAT/GOOD は同一行・右側列（dx +0.05〜+0.20）から取る', () {
      final result = extract([
        el('COOL', 0.5175, 0.5975),
        el('975', 0.6504, 0.5975),
        el('GREAT', 0.5275, 0.6456),
        el('58', 0.6613, 0.6459),
        el('GOOD', 0.5188, 0.6922),
        el('109', 0.6518, 0.6934),
      ]);

      expect(result.cool!.value, 975);
      expect(result.great!.value, 58);
      expect(result.good!.value, 109);
    });

    test('BAD は同一行・右側列（dx +0.10〜+0.25）から取る', () {
      // WHY: 統計書 §4.2 の「BAD dx −0.11（左隣）」は隣行（GREAT）の値を
      // 誤対応した偽ペアで、GT 照合では BAD 値はラベル右側 dx≈+0.19。
      final result = extract([
        el('BAD', 0.7612, 0.6295),
        el('7', 0.9516, 0.6326),
        // BAD の左隣にある GREAT 行の値（偽ペアを生ませないことの確認）。
        el('GREAT', 0.5275, 0.6456),
        el('164', 0.6517, 0.6475),
      ]);

      expect(result.bad!.value, 7);
      expect(result.great!.value, 164);
    });

    test('COMBO は同一行・右側列（dx +0.10〜+0.25）から取る', () {
      final result = extract([
        el('COMBO', 0.7833, 0.6833),
        el('0733', 0.9266, 0.6821),
      ]);

      expect(result.maxCombo!.value, 733); // ゼロ埋め 4 桁も正規化して一致。
    });

    test('同一直行から外れた値（dy 超過）は対応付けない（偽ペア防止）', () {
      // WHY: 近接最小距離だけの対応付けは、値が未検出の行で隣行の値を
      // 拾って偽ペアを作る（統計書 §4.2 の污染の実例）。
      final result = extract([
        el('GOOD', 0.5188, 0.6922),
        el('999', 0.6518, 0.6459), // 直上（GREAT 行相当）の値。
      ]);

      expect(result.good, isNull);
    });

    test('列窓から外れた値（左隣・遠方）は対応付けない', () {
      final result = extract([
        el('COOL', 0.5175, 0.5975),
        el('975', 0.4000, 0.5975), // 左側。
        el('9999', 0.9500, 0.5975), // 右すぎ。
      ]);

      expect(result.cool, isNull);
    });

    test('検証範囲外の判定数は isValid=false', () {
      final result = extract([
        el('COOL', 0.5175, 0.5975),
        el('12345', 0.6504, 0.5975),
      ]);

      final cool = result.cool!;
      expect(cool.value, 12345);
      expect(cool.isValid, isFalse);
    });

    test('ドット混じりの値はドットを除去して整数化する（4.6→46）', () {
      // WHY: ドットは OCR ノイズとして除去する正規化を種別によらず一律で
      // 許容する（ユーザー見解）。レベル種別は Wave 2 追加のため、ここでは
      // 種別によらず同一の正規化ルールであることを COOL で検証する。
      // 【訂正・2026-11-22】当初この正規化の動機例として挙げていた「4.6」
      // という読みは設定ブロック（HI-SPEED 欄）の値でレベルの読みでは
      // なかった（リーダー確認・fb599cb §4）。一般ノイズ除去ルールとして
      // の性質は変わらないため本テスト（挙動固定）は維持する。
      // 「4.」で切れる部分読み（4→誤値）は Wave 2 の測定時に分類する。
      final result = extract([
        el('COOL', 0.5175, 0.5975),
        el('4.6', 0.6504, 0.5975),
      ]);

      expect(result.cool!.value, 46);
      expect(result.cool!.rawText, '4.6');
    });
  });

  group('GREAT 連結形', () {
    test('GREAT143 のように値が連結したアンカーから値を直接採る', () {
      // WHY: 実データ 6/30 で GREAT と値が 1 要素に連結する（stats §7②）。
      final result = extract([el('GREAT143', 0.5275, 0.6456)]);

      final great = result.great!;
      expect(great.value, 143);
      expect(great.rawText, 'GREAT143');
      expect(great.evidence, hasLength(1));
    });

    test('連結形アンカーが他ラベルの値として再利用されない', () {
      final result = extract([
        el('GREAT143', 0.5275, 0.6456),
        el('COOL', 0.5175, 0.5975),
      ]);

      expect(result.great!.value, 143);
      expect(result.cool, isNull);
    });
  });

  group('ラベル検出', () {
    test('大文字小文字の揺れ（cOOL）を正規化して検出する', () {
      // WHY: 実データ 12h1bb で COOL が「cOOL」と読まれた実例。完全一致
      // （大文字小文字正規化）で十分であり、あいまい照合は使わない。
      final result = extract([
        el('cOOL', 0.5175, 0.5975),
        el('1199', 0.6400, 0.5987),
      ]);

      expect(result.cool!.value, 1199);
    });

    test('ラベル以外の文字列（NORMAL 等）はアンカーにならない', () {
      final result = extract([
        el('NORMAL', 0.4, 0.3),
        el('SCORE', 0.5783, 0.4763),
        el('98108', 0.8316, 0.4763),
      ]);

      expect(result.score!.value, 98108);
      expect(result.numericFields, hasLength(1));
    });

    test('同一種別のラベルが重複する場合は先勝ちで決定的にする', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('SCORE', 0.6, 0.9), // 後続の重複アンカー。
        el('98108', 0.8316, 0.4763),
      ]);

      expect(result.score!.value, 98108);
    });
  });

  group('信頼度', () {
    test('フィールド信頼度は根拠要素 confidence の平均', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763, confidence: 0.8),
        el('98108', 0.8316, 0.4763, confidence: 1.0),
      ]);

      expect(result.score!.confidence, closeTo(0.9, 0.0001));
    });

    test('根拠要素にセンチネル（信頼度不明）があれば不明を伝播する', () {
      // WHY: 平均は「不明」を「低い値」と偽装する。不明は不明のまま
      // 受け渡し、判断は呼び出し側に委ねる（センチネル設計）。
      final result = extract([
        el('SCORE', 0.5783, 0.4763, confidence: OcrElement.confidenceUnknown),
        el('98108', 0.8316, 0.4763, confidence: 1.0),
      ]);

      expect(result.score!.confidence, OcrElement.confidenceUnknown);
    });
  });

  group('未抽出と要素の再利用', () {
    test('アンカーがない種別は未抽出（エントリ自体が存在しない）', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('98108', 0.8316, 0.4763),
      ]);

      expect(result.field(NumericFieldKind.great), isNull);
      expect(result.numericFields.containsKey(NumericFieldKind.bad), isFalse);
    });

    test('値要素が窓内にない種別は未抽出（偽値を作らない）', () {
      final result = extract([
        el('COMBO', 0.7833, 0.6833),
        // COMBO の窓外（左側）にある数値。
        el('7', 0.7000, 0.6833),
      ]);

      expect(result.maxCombo, isNull);
    });

    test('1 つの値要素が 2 つのフィールドで重複使用されない', () {
      final result = extract([
        el('COOL', 0.5175, 0.5975),
        el('GREAT', 0.5275, 0.6456),
        el('1200', 0.6517, 0.5975), // COOL 行の値。
        el('1210', 0.6517, 0.6456), // GREAT 行の値。
      ]);

      expect(result.cool!.value, 1200);
      expect(result.great!.value, 1210);
    });

    test('空の OCR 結果は空の抽出結果になる', () {
      final result = extract([]);

      expect(result.numericFields, isEmpty);
      expect(result.sourceElementCount, 0);
    });

    test('sourceElementCount に元の要素数が入る', () {
      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('98108', 0.8316, 0.4763),
        el('オルビス', 0.2, 0.1),
      ]);

      expect(result.sourceElementCount, 3);
    });

    test('画像寸法が未設定の OcrPageResult は ArgumentError（沈黙した誤動作防止）', () {
      // WHY: engine の寸法設定漏れは「全フィールド未抽出」として隠蔽される
      // のではなく、明示的な失敗として早く発見できるべき（extract の doc 参照）。
      const pageWithoutDims = OcrPageResult(elements: [], fullText: '');

      expect(
        () => const FieldExtractor().extract(pageWithoutDims),
        throwsArgumentError,
      );
    });
  });

  group('extractWithRegions（クロップ再 OCR のマージ・Wave 2）', () {
    // GOOD 値が全体 OCR で未検出（白文字 16/30 未検出の再現）で、
    // クロップ再 OCR では取れたシナリオ。
    test('全体で未検出の GOOD をクロップ値で補完する', () {
      final fullPage = page([el('GOOD', 0.5188, 0.6922)]);
      final goodCrop = OcrPageResult(
        elements: [el('7', 0.65, 0.6922)],
        fullText: '7',
        imageWidth: 636,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.good: goodCrop,
      });

      expect(merged.good!.value, 7);
      expect(merged.good!.rawText, '7');
      // WHY: クロップ由来の bbox はクロップ座標系のまま（doc 参照）。
      expect(merged.good!.boundingBox, goodCrop.elements.single.boundingBox);
      expect(merged.sourceElementCount, 1);
    });

    test('全体で有効な値はクロップ値で上書きしない（文脈つきを優先）', () {
      final fullPage = page([
        el('GOOD', 0.5188, 0.6922),
        el('123', 0.65, 0.6922),
      ]);
      final goodCrop = OcrPageResult(
        elements: [el('99', 0.65, 0.6922)],
        fullText: '99',
        imageWidth: 636,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.good: goodCrop,
      });

      expect(merged.good!.value, 123);
    });

    test('スコアの落字（4 桁）をクロップの 5 桁読みで復帰する', () {
      // 3490q2 の 9640（実 GT 98108・confidence 半減）の再現。
      final fullPage = page([
        el('SCORE', 0.5783, 0.4763),
        el('9640', 0.8316, 0.4763),
      ]);
      final scoreCrop = OcrPageResult(
        elements: [el('98108', 0.55, 0.5)],
        fullText: '98108',
        imageWidth: 276,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.score: scoreCrop,
      });

      expect(merged.score!.value, 98108);
      expect(merged.score!.rawText, '98108');
    });

    test('クロップ側がノイズのみのときは全体結果を維持する', () {
      final fullPage = page([el('GOOD', 0.5188, 0.6922)]);
      final noisyCrop = OcrPageResult(
        elements: [el('BO', 0.5, 0.5), el('abc', 0.6, 0.5)],
        fullText: 'BO abc',
        imageWidth: 636,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.good: noisyCrop,
      });

      expect(merged.good, isNull);
    });

    test('クロップ値が検証範囲外なら採用しない', () {
      final fullPage = page([el('GOOD', 0.5188, 0.6922)]);
      final invalidCrop = OcrPageResult(
        elements: [el('99999', 0.5, 0.5)],
        fullText: '99999',
        imageWidth: 636,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.good: invalidCrop,
      });

      expect(merged.good, isNull);
    });

    test('レベルクロップ読み LW501 は範囲外（1..50）で不採用', () {
      // WHY: レベル種別は byName でマージされる。LW501 → 501 は 1..50 外なので
      // 検証が拒否され、クロップ結果は不採用。曲名は ST-5 照合フェーズ。
      final fullPage = page([el('EX', 0.4740, 0.1500)]);
      final levelCrop = OcrPageResult(
        elements: [el('LW501', 0.5, 0.5)],
        fullText: 'LW501',
        imageWidth: 372,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.level: levelCrop,
        RegionTarget.songTitle: levelCrop,
      });

      // 数値フィールドへは何も反映されない（EX はアンカーにも値にもならない）。
      expect(merged.numericFields, isEmpty);
    });

    test('クロップ候補は桁数が多いものを優先する（決定的）', () {
      final fullPage = page([el('GOOD', 0.5188, 0.6922)]);
      final crop = OcrPageResult(
        elements: [el('9', 0.7, 0.5), el('123', 0.6, 0.5), el('45', 0.65, 0.5)],
        fullText: '9 123 45',
        imageWidth: 636,
        imageHeight: 48,
      );

      final merged = const FieldExtractor().extractWithRegions(fullPage, {
        RegionTarget.good: crop,
      });

      expect(merged.good!.value, 123);
    });

    group('レベル（Wave 2 クロップ専用・1..50）', () {
      // 実測でクロップから返る "Lv.50" 系の読み（30 枚計測・2026-11-22）。
      test('LU39A 型の読みを 39 と解釈する（e6xlzd 実測・GT 39 一致）', () {
        final fullPage = page([el('EX', 0.4740, 0.1500)]);
        final levelCrop = OcrPageResult(
          elements: [el('LU39A', 0.8, 0.5)],
          fullText: 'LU39A',
          imageWidth: 372,
          imageHeight: 48,
        );

        final merged = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: levelCrop,
        });

        expect(merged.level!.value, 39);
        expect(merged.level!.rawText, 'LU39A');
      });

      test('LU50. / LUS0 型の読みを 50 と解釈する（bet7t4 実測・GT 50 一致）', () {
        final fullPage = page([el('EX', 0.4740, 0.1500)]);
        final merged = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: OcrPageResult(
            elements: [el('LU50.', 0.8, 0.5)],
            fullText: 'LU50.',
            imageWidth: 372,
            imageHeight: 48,
          ),
        });
        expect(merged.level!.value, 50);

        final merged2 = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: OcrPageResult(
            elements: [el('LUS0', 0.8, 0.5)],
            fullText: 'LUS0',
            imageWidth: 372,
            imageHeight: 48,
          ),
        });
        expect(merged2.level!.value, 50);
      });

      test('LW501（501 > 50）は検証範囲外で拒否する', () {
        // WHY: 全体 OCR のノイズ読み "LW501" は 501 となり 1..50 外。
        final fullPage = page([el('EX', 0.4740, 0.1500)]);
        final merged = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: OcrPageResult(
            elements: [el('LW501', 0.8, 0.5)],
            fullText: 'LW501',
            imageWidth: 372,
            imageHeight: 48,
          ),
        });

        expect(merged.level, isNull);
      });

      test('数字を含まない読み（LUJB→J0）は拒否する', () {
        final fullPage = page([el('EX', 0.4740, 0.1500)]);
        final merged = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: OcrPageResult(
            elements: [el('LUJB', 0.8, 0.5)],
            fullText: 'LUJB',
            imageWidth: 372,
            imageHeight: 48,
          ),
        });

        expect(merged.level, isNull);
      });

      test('クリーンな読み（44）はそのまま採用する', () {
        final fullPage = page([el('EX', 0.4740, 0.1500)]);
        final merged = const FieldExtractor().extractWithRegions(fullPage, {
          RegionTarget.level: OcrPageResult(
            elements: [el('44', 0.8, 0.5)],
            fullText: '44',
            imageWidth: 372,
            imageHeight: 48,
          ),
        });

        expect(merged.level!.value, 44);
      });
    });

    test('スコアの末尾 B は 5 桁目 0 の誤読として復元する（6926B→69260）', () {
      // Wave 2 の 30 枚計測で確認されたスコア読み（輪郭 0 → B 誤読）。
      final fullPage = page([
        el('SCORE', 0.5783, 0.4763),
        el('6926B', 0.8316, 0.4763),
      ]);

      final result = extract([
        el('SCORE', 0.5783, 0.4763),
        el('6926B', 0.8316, 0.4763),
      ]);

      expect(result.score!.value, 69260);
      expect(result.score!.rawText, '6926B');
      expect(fullPage, isNotNull); // page() ヘルパー利用の明示のため。
    });

    test('数字を含まない B 単独は値 0 にしない（B→0 置換の偽値防止）', () {
      // WHY: 判定ラベル末尾の "B" がクロップに混入しただけのケース。
      // B→0 置換があるため「元テキストに数字を含まない拒否」で守る。
      final result = extract([
        el('GOOD', 0.5188, 0.6922),
        el('B', 0.65, 0.6922),
      ]);

      expect(result.good, isNull);
    });
  });
}
