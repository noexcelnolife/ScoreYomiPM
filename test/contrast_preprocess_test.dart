import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/ocr/contrast_preprocess.dart';

Uint8List grayPx(List<int> lumas) =>
    Uint8List.fromList(lumas.expand((v) => <int>[v, v, v, 255]).toList());

void main() {
  group('ContrastPreprocess.binarize', () {
    test('3x1 2値画像: 少数派クラスタ（文字）を黒・多数派（背景）を白へ極性正規化', () {
      // WHY 前処理の本質契約（docs/st5_f2_g_contrast_preprocess_design_
      // confirmation_2026-11-22.md §1・docs コミット 18b2111・リード承認
      // 済み）: r6 で狭帯 scale 3.0 でもグラデーション/縁取り文字の 4 キーが
      // ML Kit 0 要素（r6 §4.5）。大津二値化で文字/背景の luma 差を 0/255 に
      // 引き上げる。文字=少数派クラスタ → 黒 0・背景=多数派 → 白 255（暗字
      // 明背景が ML Kit v2 の主学習分布という経験則に合わせる極性固定）。
      // 出力は RGBA 全チャンネル同値 (v, v, v, 255)。
      final rgba = grayPx(<int>[40, 40, 220]);

      final out = ContrastPreprocess.binarize(rgba, 3, 1);

      expect(out, isNotNull);
      expect(
        out,
        Uint8List.fromList(<int>[
          255, 255, 255, 255, // 背景 40 → 白 255（多数派）
          255, 255, 255, 255,
          0, 0, 0, 255, // 文字 220 → 黒 0（少数派）
        ]),
      );
    });

    test('2x1 2値画像: 暗い少数派文字も黒へ正規化する（極性は面積基準）', () {
      // WHY 極性が「明るさ」でなく「面積（少数派=文字）」基準であることを
      // 固定する。暗背景 220 の中の暗文字 40 でも、文字が少数派なら黒に
      // 正規化される（暗字明背景への一方向化）。
      final rgba = grayPx(<int>[220, 40]);

      final out = ContrastPreprocess.binarize(rgba, 2, 1);

      expect(out, isNotNull);
      expect(
        out,
        Uint8List.fromList(<int>[
          255, 255, 255, 255, // 背景 220 → 白
          0, 0, 0, 255, // 文字 40 → 黒（少数派）
        ]),
      );
    });

    test('単色画像は null（縮退・前処理スキップ）', () {
      // WHY 単色画像には文字構造の情報がなく、二値化しても無意味な再認識
      // コストだけが発生する。null を返して呼び出し側に「再試行しない」を
      // 伝える契約（設計書 §3 縮退ポリシー）。
      final rgba = grayPx(<int>[100, 100, 100, 100]);

      expect(ContrastPreprocess.binarize(rgba, 2, 2), isNull);
    });

    test('1x1 画像は null（極小・縮退）', () {
      // WHY 1 ピクセルではクラスタ分離の定義自体が成立しない（単色扱い）。
      final rgba = grayPx(<int>[120]);

      expect(ContrastPreprocess.binarize(rgba, 1, 1), isNull);
    });

    test('2x2 混合画像は非 null かつ極性ルールどおり', () {
      // WHY 最小の 2 次元ケース。3px 背景 10 + 1px 文字 240 → 文字（少数派）
      // 1 px だけ黒・残り白。幅優先（行優先）の並びを固定する。
      final rgba = grayPx(<int>[10, 10, 10, 240]);

      final out = ContrastPreprocess.binarize(rgba, 2, 2);

      expect(out, isNotNull);
      expect(
        out,
        Uint8List.fromList(<int>[
          255, 255, 255, 255, //
          255, 255, 255, 255, //
          255, 255, 255, 255, //
          0, 0, 0, 255, // 文字（少数派）
        ]),
      );
    });

    test('同一入力には同一出力（決定性）', () {
      // WHY OCR パイプラインの再現性要件（r6 計測の決定性 39/39 と同一
      // 方向）。前処理も決定的であることをユニットで固定する。
      final rgba = grayPx(<int>[40, 40, 220]);

      final a = ContrastPreprocess.binarize(rgba, 3, 1);
      final b = ContrastPreprocess.binarize(rgba, 3, 1);

      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a, b);
    });
  });
}
