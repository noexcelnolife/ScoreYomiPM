// ST-3.5: buildSpecs へのアンカー統合（オプション引数）の unit テスト
// （TDD red 先行）。
//
// リード受け入れ条件の固定点:
// ① buildSpecs に渡す anchors は純データ（AnchorRegistration）のみで、
//    本テストファイルは画像を一切デコードしない（DIP・幾何層への機構漏出防止）。
// ② 再センタリング/再計算は named 定数ゲート（NCC スコア閾値・frameRight
//    整合サニティ・補正量上限）を満たすときのみ行い、不成立時は正準 spec
//    を維持する（= anchors 無指定の出力と一致）。
//
// 設計: docs/st3_5_ui_anchor_design_confirmation_2026-11-22.md §2.4
// （docs 単独コミット c8c9e00）。実装前のため現状は RED（anchors 引数が
// 存在しない = コンパイルエラー）。

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/region_spec.dart';
import 'package:scoreyomipm/ocr/ui_anchor.dart';

/// パック契約（assets/anchors/hc_v1・設計 §1.2 事後確認の実測中央値）の
/// canonical 位置。テストはこの値を AnchorHit.canonicalPosition として
/// 流し込む（幾何層は hit 自身が持つ canonical と検出位置の差で判定する）。
const Offset _gaugeHeaderCanonical = Offset(0.579, 0.352);
const Offset _frameRightCanonical = Offset(0.4467, 0.5);
const Offset _difficultyExCanonical = Offset(0.474, 0.153);

/// 横画像（1200x800）の pageResult。
OcrPageResult _page({
  List<OcrElement> elements = const [],
  int? width = 1200,
  int? height = 800,
}) {
  return OcrPageResult(
    elements: elements,
    fullText: '',
    imageWidth: width,
    imageHeight: height,
  );
}

/// ゲート検証用の合成 AnchorRegistration（画像デコード不要・条件①）。
AnchorRegistration _registration({
  bool includeGauge = true,
  double gaugeDeltaY = 0.0,
  double gaugeScore = 0.9,
  bool includeFrameRight = true,
  double frameRightX = 0.4467,
  bool includeEx = false,
  Offset exPosition = _difficultyExCanonical,
  double exScore = 0.9,
}) {
  final hits = <String, AnchorHit>{};
  if (includeGauge) {
    hits['gaugeHeader'] = AnchorHit(
      id: 'gaugeHeader',
      position: Offset(
        _gaugeHeaderCanonical.dx,
        _gaugeHeaderCanonical.dy + gaugeDeltaY,
      ),
      score: gaugeScore,
      canonicalPosition: _gaugeHeaderCanonical,
    );
  }
  if (includeFrameRight) {
    hits['frameRight'] = AnchorHit(
      id: 'frameRight',
      position: Offset(frameRightX, _frameRightCanonical.dy),
      score: 0.6,
      canonicalPosition: _frameRightCanonical,
    );
  }
  if (includeEx) {
    hits['difficultyEx'] = AnchorHit(
      id: 'difficultyEx',
      position: exPosition,
      score: exScore,
      canonicalPosition: _difficultyExCanonical,
    );
  }
  return AnchorRegistration(hits: hits);
}

/// spec の同一性を文字列化して比較する（RegionSpec は == を持たない）。
List<String> _serialize(List<RegionSpec> specs) => specs
    .map(
      (s) =>
          '${s.target}|${s.region}|${s.script}|'
          '${s.pixelScale}|${s.isFallback}|${s.reason}',
    )
    .toList();

RegionSpec _specOf(
  List<RegionSpec> specs,
  RegionTarget target, {
  bool fallback = false,
}) {
  // WHY singleWhere → where().first（docs/st5_f2_f_narrowband_scale3_design_
  // confirmation_2026-11-22.md・docs コミット a2037df・リード承認済み）:
  // フェーズ2-F で songTitle に狭帯 A/B（isFallback=true）2 本が追加され、
  // fallback 指定の singleWhere が 3 件ヒットして StateError になる。
  // 「最初の non-fallback = primary・最初の fallback = fallback1（広帯）」
  // という従来の意味論を維持するため first を取る（狭帯 A/B の幾何固定は
  // region_ocr_test.dart の fallback 3 本構成テストが担当する）。
  return specs
      .where((s) => s.target == target && s.isFallback == fallback)
      .first;
}

void main() {
  test('回帰ガード: anchors 未指定と anchors:null で出力が完全一致する', () {
    final page = _page();
    final base = const RegionSpecBuilder().buildSpecs(page);
    final withNull = const RegionSpecBuilder().buildSpecs(page, anchors: null);
    expect(_serialize(withNull), _serialize(base));
  });

  test('ゲート成立の gaugeHeader δ でも曲名帯は固定を維持する（δ 適用廃止・プラス側）', () {
    // WHY 意図的挙動変更（ST-5 横有効決定退行是正・docs/st5_delta_regression_
    // fix_design_confirmation_2026-11-22.md・docs コミット 0232da5・リード
    // 承認済み）: 旧 assert は「δ で曲名帯が再センタリングされる」を期待
    // していたが、r4 実測で gaugeHeader cy ふれ（0.3425-0.3564・canonical
    // 0.3525）は固定テンプレ UI の NCC 検出ノイズであり実シフトが存在しない
    // こと、δ を曲名帯へ伝搬するとクロップ内容シフト→ML Kit 読み取り同一性
    // 入れ替わりで横有効決定 14/30→10/30 に退行したこと（52c4xa と bt2qlc
    // は NCC/cy/δ 3 値完全同一で hit が真逆＝単調ゲートでは分離不能）から
    // 曲名帯への δ 適用を廃止。ゲート成立 δ がプラス側（+0.012・旧テスト値）
    // でも固定。マイナス側（−0.0050・52c4xa/bt2qlc 実測値）はファイル末尾の
    // 回帰ガードが担当する。
    final anchors = _registration(gaugeDeltaY: 0.012);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    final fallback = _specOf(specs, RegionTarget.songTitle, fallback: true);
    expect(primary.region.top, closeTo(0.16, 1e-6));
    expect(primary.region.bottom, closeTo(0.30, 1e-6));
    expect(fallback.region.top, closeTo(0.14, 1e-6));
    expect(fallback.region.bottom, closeTo(0.34, 1e-6));
    expect(primary.reason, isNot(contains('anchor')));
    expect(fallback.reason, isNot(contains('anchor')));
  });

  test('NCC スコアが閾値未満のときは正準 spec を維持する（検出層通過後の防御）', () {
    // 検出層の閾値で落ちるスコアだが、直接構築した registration を渡す
    // （幾何層ゲートは単独でも防御として機能する契約）。
    final anchors = _registration(gaugeDeltaY: 0.012, gaugeScore: 0.40);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    expect(primary.region.top, closeTo(0.16, 1e-9));
    expect(primary.region.bottom, closeTo(0.30, 1e-9));
  });

  test('frameRight が整合しない（|Δx| > サニティ上限）ときは正準 spec を維持する', () {
    final anchors = _registration(gaugeDeltaY: 0.012, frameRightX: 0.60);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    expect(primary.region.top, closeTo(0.16, 1e-9));
    expect(primary.region.bottom, closeTo(0.30, 1e-9));
  });

  test('frameRight アンカーが欠落するときは正準 spec を維持する', () {
    final anchors = _registration(gaugeDeltaY: 0.012, includeFrameRight: false);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    expect(primary.region.top, closeTo(0.16, 1e-9));
    expect(primary.region.bottom, closeTo(0.30, 1e-9));
  });

  test('δ が補正量上限を超えるときは正準 spec を維持する', () {
    final anchors = _registration(gaugeDeltaY: 0.10);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    expect(primary.region.top, closeTo(0.16, 1e-9));
    expect(primary.region.bottom, closeTo(0.30, 1e-9));
  });

  test('difficulty 要素なし + difficultyEx アンカー成立で level がアンカー基準になる', () {
    final anchors = _registration(includeEx: true);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final level = _specOf(specs, RegionTarget.level);
    expect(level.region.left, closeTo(0.474 + 0.20 - 0.03, 1e-6));
    expect(level.region.right, closeTo(0.474 + 0.45 + 0.03, 1e-6));
    expect(level.region.top, closeTo(0.153 - 0.03, 1e-6));
    expect(level.region.bottom, closeTo(0.153 + 0.03, 1e-6));
    expect(level.reason, contains('anchor'));
  });

  test('difficultyEx のスコア不足は median fallback + gaugeHeader δ に落ちる', () {
    final anchors = _registration(
      gaugeDeltaY: 0.012,
      includeEx: true,
      exScore: 0.40,
    );
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final level = _specOf(specs, RegionTarget.level);
    expect(level.region.left, closeTo(0.4740 + 0.20 - 0.03, 1e-6));
    expect(level.region.right, closeTo(0.4740 + 0.45 + 0.03, 1e-6));
    expect(level.region.top, closeTo(0.1521 + 0.012 - 0.03, 1e-6));
    expect(level.region.bottom, closeTo(0.1521 + 0.012 + 0.03, 1e-6));
  });

  test('level: difficulty 要素ありのときは anchors があっても element 相対のまま', () {
    // EX 要素中心 (0.47, 0.15)・bbox (552,112)-(576,128)。
    final exElement = OcrElement(
      text: 'EX',
      boundingBox: Rect.fromLTRB(552, 112, 576, 128),
      confidence: 1.0,
    );
    final page = _page(elements: [exElement]);

    final base = const RegionSpecBuilder().buildSpecs(page);
    final anchored = const RegionSpecBuilder().buildSpecs(
      page,
      anchors: _registration(gaugeDeltaY: 0.012, includeEx: true),
    );

    // element 相対 spec は全域シフトで自己整合するため δ 補正しない。
    expect(
      _specOf(anchored, RegionTarget.level).region,
      _specOf(base, RegionTarget.level).region,
    );
    // WHY 意図的挙動変更（曲名帯への δ 適用廃止・docs 0232da5 参照）:
    // 旧 assert「0.16 + 0.012」は δ 再センタリングを期待していたが廃止。
    // 正準固定窓（曲名帯）は δ の値に依らず固定を維持する（根拠の全文は
    // プラス側固定テストの WHY コメント参照）。
    final anchoredPrimary = _specOf(anchored, RegionTarget.songTitle);
    expect(anchoredPrimary.region.top, closeTo(0.16, 1e-6));
  });

  test(
    'level: NORMAL text anchor があるときは difficultyEx NCC ヒットがあっても text 側を採用する',
    () {
      // ST-5 B 条件②（リード指示）: 選択順の固定。縦 NORMAL 曲では difficultyEx
      // テンプレが擬ヒットする（自デバイス実行 3/9・スコア 0.557-0.566）ため、
      // text anchor 優先を位置と理由文字列で固定する（将来の選択順変更に対する
      // 回帰ガード・設計確認 §3.3）。
      // NORMAL 要素中心は kt1odi 実測 (0.502, 0.138)。
      final normal = OcrElement(
        text: 'NORMAL',
        boundingBox: Rect.fromCenter(
          center: const Offset(0.502 * 1200, 0.138 * 800),
          width: 60,
          height: 16,
        ),
        confidence: 0.9,
      );
      // difficultyEx 擬ヒット（実測位置帯 (0.51, 0.158)・スコア 0.566）を併存させる。
      final anchors = _registration(
        includeEx: true,
        exPosition: const Offset(0.51, 0.158),
        exScore: 0.566,
      );

      final level = _specOf(
        const RegionSpecBuilder().buildSpecs(
          _page(elements: [normal]),
          anchors: anchors,
        ),
        RegionTarget.level,
      );

      // text anchor（0.502, 0.138）基準の領域。NCC 擬ヒット側を採用すると
      // left が 0.68 になるため位置でも判別できる。
      expect(level.region.left, closeTo(0.502 + 0.17, 1e-6));
      expect(level.region.top, closeTo(0.108, 1e-6));
      expect(level.reason, contains('"NORMAL"'));
    },
  );

  test('level: どのアンカーも使えなければ現行の median fallback のまま', () {
    final base = const RegionSpecBuilder().buildSpecs(_page());
    final level = _specOf(base, RegionTarget.level);
    expect(level.region.top, closeTo(0.1521 - 0.03, 1e-9));
    expect(level.region.bottom, closeTo(0.1521 + 0.03, 1e-9));

    // gaugeHeader すら不成立の registration でも同じ（正準維持）。
    final anchored = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: _registration(includeGauge: false),
    );
    expect(_specOf(anchored, RegionTarget.level).region, level.region);
  });

  test('縦入力（h>w）では anchors があっても正準 portrait バンドを維持する', () {
    // WHY: アンカー canonical は横 1200x800 基準の実測で、縦（正規化前の
    // レガシー空間）への適用は未検証。v1 では適用しない（正準維持）。
    final anchors = _registration(gaugeDeltaY: 0.012, includeEx: true);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(width: 1080, height: 2000),
      anchors: anchors,
    );

    final title = _specOf(specs, RegionTarget.songTitle);
    expect(title.region, const Rect.fromLTRB(0, 0.40, 1, 0.47));

    final level = _specOf(specs, RegionTarget.level);
    expect(level.region.top, closeTo(0.1521 - 0.03, 1e-9));
    expect(level.region.bottom, closeTo(0.1521 + 0.03, 1e-9));
  });

  // WHY 曲名帯固定（docs/st5_delta_regression_fix_design_confirmation_2026-11-22.md・
  // docs コミット 0232da5・リード承認済み）: r4 実測で gaugeHeader cy ふれ
  // （0.3425-0.3564・canonical 0.3525）は固定テンプレ UI の NCC 検出ノイズであり、
  // δ を曲名帯へ伝搬するとクロップ内容シフト→ML Kit 読み取り同一性入れ替わりで
  // 横有効決定 14/30→10/30 に退行した（52c4xa と bt2qlc は NCC/cy/δ 3 値完全同一で
  // hit が真逆＝単調ゲートでは分離不能）。r3 (39d9fba) の固定帯が実測 14/30 のため
  // 曲名帯は anchors の有無・δ の値に依らず固定を維持する。gaugeDeltaY −0.0050 は
  // r4 の 52c4xa/bt2qlc 実測値（frameRight 整合・|δ| ≤ 0.06 でゲート成立を満たす）。
  test('回帰ガード: ゲート成立の anchors でも曲名帯は r3 (39d9fba) 固定帯を維持する', () {
    final anchors = _registration(gaugeDeltaY: -0.0050);
    final specs = const RegionSpecBuilder().buildSpecs(
      _page(),
      anchors: anchors,
    );

    final primary = _specOf(specs, RegionTarget.songTitle);
    final fallback = _specOf(specs, RegionTarget.songTitle, fallback: true);
    expect(primary.region.top, closeTo(0.16, 1e-6));
    expect(primary.region.bottom, closeTo(0.30, 1e-6));
    expect(fallback.region.top, closeTo(0.14, 1e-6));
    expect(fallback.region.bottom, closeTo(0.34, 1e-6));
    expect(primary.reason, isNot(contains('anchor')));
    expect(fallback.reason, isNot(contains('anchor')));
  });
}
