import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/region_spec.dart';

/// 正規化中心座標 (cx, cy) を絶対 px bbox（1200x800 前提）へ変換する。
OcrElement el(
  String text,
  double cx,
  double cy, {
  double hNorm = 0.02,
  double confidence = 0.9,
}) => OcrElement(
  text: text,
  boundingBox: Rect.fromCenter(
    center: Offset(cx * 1200, cy * 800),
    width: 60,
    height: hNorm * 800,
  ),
  confidence: confidence,
);

OcrPageResult page(List<OcrElement> elements) => OcrPageResult(
  elements: elements,
  fullText: elements.map((e) => e.text).join(' '),
  imageWidth: 1200,
  imageHeight: 800,
);

/// 縦スクショ用ページ（実測寸法: scr001-009 前処理後 1071x2316）。
///
/// WHY 実測値: リード承認の前提確認 probe（2026-11-22・実行後削除）で
/// 9/9 が rect=(4,53,1075,2369) → crop 1071x2316・h > w を確認。
/// ST-1 期の「前処理 1080x720」記録は過去実装の値で現行と不一致。
OcrPageResult portraitPage(List<OcrElement> elements) => OcrPageResult(
  elements: elements,
  fullText: elements.map((e) => e.text).join(' '),
  imageWidth: 1071,
  imageHeight: 2316,
);

void main() {
  const builder = RegionSpecBuilder();

  // 実測ジオメトリ（docs/field_layout_stats_2026-11-22.md §4.1 の中央値）。
  const goodCx = 0.5188;
  const goodCy = 0.6922;
  const badCx = 0.7612;

  group('RegionSpecBuilder 数値系（ラベルアンカー + 列窓）', () {
    test('GOOD アンカーから列窓 ± マージンの領域を算出する（Latin）', () {
      final specs = builder.buildSpecs(
        page([
          el('GOOD', goodCx, goodCy),
          el('COOL', 0.5175, 0.5975),
          el('GREAT', 0.5275, 0.6456),
          el('BAD', badCx, 0.6295),
          el('COMBO', 0.7833, 0.6833),
          el('SCORE', 0.5783, 0.4763),
        ]),
        targets: {RegionTarget.good},
      );

      // 2 番目の spec（底辺拡張 + scale 2.0）が追加される（WHY: 23bjim の "2" や
      // e6xlzd good=0 はプライマリ・フォールバック両方で未検出（既知限界）。23bjim good=2 のみ検証済み、probe 結果）。
      expect(specs, hasLength(2));

      // 1 番目: 現行の列窓 spec（scale 3.0）。
      final primary = specs.firstWhere((s) => s.pixelScale == 3.0);
      expect(primary.region.left, closeTo(0.5388, 1e-9));
      expect(primary.region.right, closeTo(0.7488, 1e-9));
      expect(primary.region.top, closeTo(goodCy - 0.03, 1e-9));
      expect(primary.region.bottom, closeTo(goodCy + 0.03, 1e-9));
      expect(primary.script, OcrScript.latin);
      expect(primary.reason, contains('column window'));

      // 2 番目: 底辺拡張（bottom = cy + 0.06）+ scale 2.0。
      final secondary = specs.firstWhere((s) => s.pixelScale == 2.0);
      expect(secondary.region.left, closeTo(0.5388, 1e-9));
      expect(secondary.region.right, closeTo(0.7488, 1e-9));
      expect(secondary.region.top, closeTo(goodCy - 0.03, 1e-9));
      expect(secondary.region.bottom, closeTo(goodCy + 0.06, 1e-9));
      expect(secondary.script, OcrScript.latin);
      expect(secondary.reason, contains('fallback'));
      expect(secondary.isFallback, isTrue);
    });

    test('BAD の列窓右端 + マージンは 1.0 に clamp される', () {
      final specs = builder.buildSpecs(
        page([el('BAD', badCx, 0.6295)]),
        targets: {RegionTarget.bad},
      );

      // BAD は通常 spec（scale 3.0）＋ 底辺拡張 spec（scale 2.0）の 2 つ。
      expect(specs, hasLength(2));
      // 両方の spec で右端は 1.0 に clamp される。
      for (final s in specs) {
        expect(s.region.right, 1.0);
      }
      // フォールバック spec は isFallback=true。
      expect(specs.any((s) => s.isFallback), isTrue);
    });

    test('アンカー未検出の種別はスキップし、他の種別は算出される', () {
      // WHY: アンカーなしの固定位置クロップは誤領域のリスクが高いため
      // （buildSpecs の doc 参照）、欠けている種別だけ省かれる。
      final specs = builder.buildSpecs(page([el('GOOD', goodCx, goodCy)]));

      final targets = specs.map((s) => s.target).toSet();
      expect(targets, isNot(contains(RegionTarget.bad)));
      expect(targets, contains(RegionTarget.good));
    });

    test('targets 指定で算出対象を絞れる', () {
      final specs = builder.buildSpecs(
        page([el('SCORE', 0.5783, 0.4763), el('GOOD', goodCx, goodCy)]),
        targets: {RegionTarget.score},
      );

      expect(specs, hasLength(1));
      expect(specs.single.target, RegionTarget.score);
    });
  });

  group('RegionSpecBuilder レベル（難易度要素の右隣）', () {
    test('難易度要素 (EX) をアンカーにレベル領域を算出する（Latin）', () {
      final specs = builder.buildSpecs(
        page([el('EX', 0.4740, 0.1500)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      // 左端 = cx + 0.20 − 0.03 = 0.644 / 右端 = cx + 0.45 + 0.03 = 0.954
      expect(spec.region.left, closeTo(0.644, 1e-9));
      expect(spec.region.right, closeTo(0.954, 1e-9));
      expect(spec.region.top, closeTo(0.12, 1e-9));
      expect(spec.region.bottom, closeTo(0.18, 1e-9));
      expect(spec.script, OcrScript.latin);
      expect(spec.reason, contains('"EX"'));
    });

    test('曲名帯より下（判定欄側）の EX 表記はアンカーに使わない', () {
      // WHY: 設定欄や判定欄にも "EX" 起票の表記があり得るため、
      // 難易度要素は曲名帯の上（cy ≤ 0.2）に限定する。
      final specs = builder.buildSpecs(
        page([el('EX', 0.4740, 0.6000)]),
        targets: {RegionTarget.level},
      );

      expect(specs.single.reason, contains('fallback'));
    });

    test('難易度要素が未検出のときは実測中央値の仮アンカーで補う', () {
      final specs = builder.buildSpecs(
        page([el('SCORE', 0.5783, 0.4763)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      // 仮アンカー (0.4740, 0.1521) + 同一オフセット。
      expect(spec.region.left, closeTo(0.644, 1e-9));
      expect(spec.region.right, closeTo(0.954, 1e-9));
      expect(spec.region.top, closeTo(0.1221, 1e-9));
      expect(spec.region.bottom, closeTo(0.1821, 1e-9));
      expect(spec.reason, contains('fallback'));
    });
  });

  group('RegionSpecBuilder レベル（難易度語彙フルセット・ST-5 フェーズ2-B）', () {
    test('難易度要素 (NORMAL) をアンカーにレベル領域を算出する（kt1odi 実測位置）', () {
      // WHY 実測: NORMAL は横 2/30（kt1odi cx 0.502 cy 0.138 / yb5h8w cx
      // 0.507 cy 0.146）に存在し、語彙不在のため median fallback 落ちして
      // いた（設計確認 §2.1）。B の主効果対象。
      final specs = builder.buildSpecs(
        page([el('NORMAL', 0.502, 0.138)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      // 左端 = cx + 0.20 − 0.03 = 0.672 / 右端 = cx + 0.45 + 0.03 = 0.982
      expect(spec.region.left, closeTo(0.672, 1e-9));
      expect(spec.region.right, closeTo(0.982, 1e-9));
      expect(spec.region.top, closeTo(0.108, 1e-9));
      expect(spec.region.bottom, closeTo(0.168, 1e-9));
      expect(spec.script, OcrScript.latin);
      expect(spec.reason, contains('"NORMAL"'));
    });

    test('難易度要素 (EASY) をアンカーにレベル領域を算出する（仕様語・39 枚実例なし）', () {
      // WHY: EASY は 39 枚実データに例がないが EASY/NORMAL/HYPER/EX
      // フルセット化の仕様語（設計確認 §3.1・合成テストで固定）。
      final specs = builder.buildSpecs(
        page([el('EASY', 0.50, 0.15)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      expect(spec.region.left, closeTo(0.67, 1e-9));
      expect(spec.region.right, closeTo(0.98, 1e-9));
      expect(spec.region.top, closeTo(0.12, 1e-9));
      expect(spec.region.bottom, closeTo(0.18, 1e-9));
      expect(spec.reason, contains('"EASY"'));
    });

    test('難易度要素 (HYPER) をアンカーにレベル領域を算出する（既存語彙の pin・ユーザー指示）', () {
      // WHY: ユーザー指示「difficulty要素にはHYPERもあるので忘れないで
      // ください」への明示確認を pin として固定（既存語彙・挙動不変）。
      final specs = builder.buildSpecs(
        page([el('HYPER', 0.50, 0.15)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      expect(spec.region.left, closeTo(0.67, 1e-9));
      expect(spec.region.right, closeTo(0.98, 1e-9));
      expect(spec.reason, contains('"HYPER"'));
    });

    test('難易度要素 (LIGHT) をアンカーにレベル領域を算出する（5p1lg4 実測位置・維持判断の pin）', () {
      // WHY: LIGHT は fixture 由来の語だが 5p1lg4（cx 0.497 cy 0.139）に
      // 実在するため維持（削除すると同画像の level が difficultyEx NCC /
      // median に後退する・設計確認 §0-2）。
      final specs = builder.buildSpecs(
        page([el('LIGHT', 0.497, 0.139)]),
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      expect(spec.region.left, closeTo(0.667, 1e-9));
      expect(spec.region.right, closeTo(0.977, 1e-9));
      expect(spec.region.top, closeTo(0.109, 1e-9));
      expect(spec.region.bottom, closeTo(0.169, 1e-9));
      expect(spec.reason, contains('"LIGHT"'));
    });

    test('設定列の NORMAL（cy 0.816）は難易度要素に使わない（cy cap ガードの pin）', () {
      // WHY: NORMAL を語彙に追加すると設定列 NORMAL（ST-3.5 settingsNormal
      // canonical cx 0.7088 cy 0.8163）が誤マッチ候補に浮上する。cy cap
      // 0.2 が排除する（設計確認 §3.2・cap の防御価値は現役）。
      final specs = builder.buildSpecs(
        page([el('NORMAL', 0.709, 0.816)]),
        targets: {RegionTarget.level},
      );

      expect(specs.single.reason, contains('fallback'));
    });

    test('縦正規化空間（1080x714）の NORMAL をアンカーに算出する（r3 実測 cy 0.158）', () {
      // WHY 実測: タスク A 正規化後の縦 difficulty 行は cy ≈ 0.158
      // （QA-Docs r3 データ 3 例一致・設計確認 §2.2）。cap 0.2 以内で
      // 余裕 ≈30px/714px → _difficultyCyMax の縦見直しは不要
      // （ST-3.5 受け入れ条件③クローズ）。
      final pageResult = OcrPageResult(
        elements: [
          OcrElement(
            text: 'NORMAL',
            boundingBox: Rect.fromCenter(
              center: const Offset(0.51 * 1080, 0.158 * 714),
              width: 60,
              height: 16,
            ),
            confidence: 0.9,
          ),
        ],
        fullText: 'NORMAL',
        imageWidth: 1080,
        imageHeight: 714,
      );
      final specs = builder.buildSpecs(
        pageResult,
        targets: {RegionTarget.level},
      );

      final spec = specs.single;
      expect(spec.region.left, closeTo(0.68, 1e-9));
      expect(spec.region.right, closeTo(0.99, 1e-9));
      expect(spec.region.top, closeTo(0.128, 1e-9));
      expect(spec.region.bottom, closeTo(0.188, 1e-9));
      expect(spec.reason, contains('"NORMAL"'));
    });
  });

  group('RegionSpecBuilder 曲名帯（固定バンド）', () {
    test('曲名帯は固定バンド・日本語スクリプト・プライマリ+フォールバックの 2 spec', () {
      final specs = builder.buildSpecs(
        page(const []),
        targets: {RegionTarget.songTitle},
      );

      // プライマリ: 現行の固定バンド（scale 1.0・等倍）。
      // WHY: 既存検出ケース（probe 実測 24/30）の回帰ガード。プライマリの
      // 定義は一切変えない（ST-5 補完・設計確認のスコープ制約）。
      final primary = specs.firstWhere((s) => !s.isFallback);
      expect(primary.region, const Rect.fromLTRB(0, 0.16, 1, 0.30));
      expect(primary.script, OcrScript.japanese);
      expect(primary.pixelScale, 1.0);

      // フォールバック: 縦拡張バンド + scale 2.0（ST-5 補完・probe 実測）。
      // WHY: プライマリ帯 [0.16, 0.30] は曲名行（cy ≈ 0.215 中心）を覆うが、
      // probe で g7p9b2（曲名 cy ≈ 0.302・プライマリ下端ちょうど）や
      // ay7zmq が帯外/検出漏れになり、縦拡張 + 拡大で復帰することを確認済み。
      // プライマリが空要素だった場合のみ実行する（runner 契約）。
      final fallback = specs.firstWhere((s) => s.isFallback);
      expect(fallback.region, const Rect.fromLTRB(0, 0.14, 1, 0.34));
      expect(fallback.script, OcrScript.japanese);
      expect(fallback.pixelScale, 2.0);
      expect(fallback.reason, contains('fallback'));
    });

    test('縦スクショ（h > w）では portrait 曲名バンド 1 本のみで横バンドは返さない', () {
      // WHY: 縦スクショ実測（scr001-009 前処理後 1071x2316・h > w 9/9）では
      // 横画像向け固定バンド [0.16, 0.30] に曲名要素が無い（QA-Docs 診断・
      // probe 実測 9/9 で帯内 0 要素）。曲名行は cy 0.441-0.442 に実測
      //（scr009 'Sorrows' conf 0.84・scr008 'AMatostauia,' conf 0.29）。
      // portrait バンド [0.40, 0.47] は曲名行を余裕で覆い、隣接行
      //（NORMAL cy 0.401-0.403 / ジャンル行 cy 0.418-0.424 / GAUGE 行
      // cy 0.464・probe 実測）の混入は SongTitleElementMatcher が吸収する
      // ため spec 側では除外ロジックを追加しない（KISS・リード承認）。
      // scale 1.0 のみ: 縦の曲名は stylized フォントで scale 3 再 OCR が
      // 不改善との QA-Docs 実測（レポート §3）により拡大再 OCR を採用しない。
      final specs = builder.buildSpecs(
        portraitPage(const []),
        targets: {RegionTarget.songTitle},
      );

      expect(specs, hasLength(1));
      final spec = specs.single;
      expect(spec.region, const Rect.fromLTRB(0, 0.40, 1, 0.47));
      expect(spec.script, OcrScript.japanese);
      expect(spec.pixelScale, 1.0);
      expect(spec.isFallback, isFalse);
    });

    test('寸法未設定時は横バンド経路を維持する（安全側デフォルト）', () {
      // WHY: pageResult の寸法が取得できない入力では縦横を判定できないため、
      // 既存の横バンド動作をそのまま維持する（後方互換・リード承認の
      // 安全側デフォルト）。実運用では pipeline が必ず寸法付き pageResult
      // を渡すため、この分岐は防御的経路。
      final specs = builder.buildSpecs(
        const OcrPageResult(elements: [], fullText: ''),
        targets: {RegionTarget.songTitle},
      );

      final primary = specs.firstWhere((s) => !s.isFallback);
      expect(primary.region, const Rect.fromLTRB(0, 0.16, 1, 0.30));
      final fallback = specs.firstWhere((s) => s.isFallback);
      expect(fallback.region, const Rect.fromLTRB(0, 0.14, 1, 0.34));
    });
  });

  group('狭帯 spec の contrastRetry フラグ（フェーズ2-G）', () {
    // WHY（docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22.md
    // ・docs コミット 18b2111・リード承認済み）: r6 で 5p1lg4/yb5h8w/enco0h/
    // s9cv7b が狭帯 A/B 発火でも 0 要素（グラデーション/縁取り文字＝低
    // コントラスト・r6 §4.5）。0 要素時の大津二値化再試行を狭帯のみに限定
    // するフラグを spec に持たせる。red 段階では全 spec が default false
    // （狭帯への設定は未実装）→ 狭帯 2 件が red になる。
    test('狭帯 A/B は contrastRetry=true・primary/fallback1 は false を固定', () {
      final specs = builder.buildSpecs(
        page([el('Harmonia', 0.5, 0.27)]),
        targets: {RegionTarget.songTitle},
      );

      expect(specs, hasLength(4));
      // primary（等倍広帯）: 前処理再試行の対象外（r6 検出済みキーの入力
      // 経路を 1 バイトも変更しないため・構造的非回帰）。
      expect(specs[0].isFallback, isFalse);
      expect(specs[0].contrastRetry, isFalse);
      // fallback1（広帯 2 倍）: 同上。
      expect(specs[1].isFallback, isTrue);
      expect(specs[1].contrastRetry, isFalse);
      // 狭帯 A [0.24, 0.29] s3.0: 0 要素時の前処理再試行対象（red）。
      expect(specs[2].contrastRetry, isTrue);
      // 狭帯 B [0.19, 0.29] s3.0: 同上（red）。
      expect(specs[3].contrastRetry, isTrue);
    });
  });

  group('RegionSpec.toPixelRect', () {
    test('正規化領域を画像 px 座標へ変換する（外側は floor/ceil で覆う）', () {
      final spec = builder
          .buildSpecs(
            page([el('EX', 0.4740, 0.1500)]),
            targets: {RegionTarget.level},
          )
          .single;

      final px = spec.toPixelRect(1200, 800);
      // left = 0.644 * 1200 = 772.8 → floor 772 / right = 1144.8 → ceil 1145
      expect(px.left, 772);
      expect(px.right, 1145);
      expect(px.top, 96);
      expect(px.bottom, 144);
    });
  });
}
