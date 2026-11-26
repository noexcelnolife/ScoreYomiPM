/// クロップ再 OCR の領域算出（Wave 2・spec.md §5.2）。
///
/// 全体 OCR で未検出/落字だったフィールドを、ラベルアンカー位置を実測
/// ジオメトリで囲んだ小領域に絞って再認識する。領域の設計根拠は
/// docs/field_layout_stats_2026-11-22.md（リーダー訂正版・0d25daa）:
///
/// - 判定値はラベルと **同一行**（正規化 |dy| ≤ 0.012）でラベルの右側。
///   列窓（FieldExtractor.columnWindowOf）: COOL/GREAT/GOOD は
///   dx ∈ [0.05, 0.20]・BAD は [0.10, 0.25]・COMBO は [0.10, 0.25]・
///   SCORE は [0.20, 0.30]（GT 検証済み）。
/// - レベル値は難易度要素（EX/LIGHT）の右隣（観測 dx ≈ +0.34・同一直行）。
///   全体 OCR では "LW501"/"LUS0"（≈ Lv.50 の誤読）として 3/30 に現れる。
/// - 曲名帯は難易度行の直下（観測 cy ≈ 0.215・30 枚中 1 枚のみ検出）。
///
/// クロップを小さくすることの狙い: 全体 OCR では小さな白文字（判定数値）
/// が背景の模様・他行の文字に埋もれて検出から漏れる（GOOD 16/30・BAD
/// 17/30 未検出）。領域を絞ると文字の相対サイズが大きくなり検出率が上がる
/// というのが Wave 2 の仮説で、効果はエミュレータ上の 30 枚計測で検証する。
library;

import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

import '../models/ocr_models.dart';
import 'ac_row_estimator.dart';
import 'field_extractor.dart';
import 'ocr_engine.dart';
import 'ui_anchor.dart';

/// 1 つのクロップ再 OCR 領域。
///
/// [region] は正規化座標（0..1）。engine へは [toPixelRect] で絶対 px に
/// 変換して渡す（WHY: 正規化座標は 19 種類の画像サイズで共通の設計根拠を
/// 表現でき、engine 契約は実画像座標で統一する）。
@immutable
class RegionSpec {
  const RegionSpec({
    required this.target,
    required this.region,
    required this.script,
    required this.reason,
    this.pixelScale = 1.0,
    this.isFallback = false,
    this.contrastRetry = false,
  });

  final RegionTarget target;

  /// クロップ領域（正規化座標・画像境界外を含み得る）。
  final Rect region;

  /// 認識スクリプト（数値系は Latin・曲名帯は日本語。WHY は各算出処理）。
  final OcrScript script;

  /// クロップ描画の拡大率（1.0 で等倍）。
  ///
  /// WHY: 数値系は小さい白文字で ML Kit の検出下限を下回り、等倍では
  /// 検出漏れする（Wave 2 初回計測の知見）ため 3 倍に拡大する。
  /// 曲名帯の文字は十分大きいため等倍。
  final double pixelScale;

  /// プライマリ spec が 0 候補だった場合のみ実行するフォールバック spec 否。
  ///
  /// WHY: GOOD/BAD の bottom 拡張 spec（bottom=cy+0.06）は隣行（BAD 行の値帯
  /// cy+0.034〜0.058）を完全に含むため、element 数優先で採用すると既存の
  /// 20 枚まで隣行値が桁数優先で誤採用される。プライマリ spec で有効な
  /// 数値候補がゼロの時だけフォールバック spec を実行・採用する。
  final bool isFallback;

  /// 検出 0 要素時に、狭帯 crop へのコントラスト前処理（大津二値化）による
  /// 再試行を engine 側で行うか。
  ///
  /// WHY（docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22.md・
  /// docs コミット 18b2111・リード承認済み）: r6 で狭帯 scale 3.0 でも
  /// 5p1lg4/yb5h8w/enco0h/s9cv7b の 4 キーが 0 要素（グラデーション/縁取り
  /// 文字＝低コントラストが原因・r6 §4.5）。前処理は狭帯 crop に限定し、
  /// 0 要素時のみ再試行する（常時前置きは 23bjim/124356＝前処理なしで回復
  /// 済みキーの入力を変える退行リスクのため棄却）。primary/fallback1 には
  /// 設定しない（r6 検出済みキーの入力経路を 1 バイトも変更しない＝構造的
  /// 非回帰）。red 段階では全 spec が default false（狭帯への設定は実装
  /// コミットで行う）。
  final bool contrastRetry;

  /// 算出根拠の短い説明（計測レポートに含め、領域設計の判断を追跡可能に
  /// するためのメタデータ。認識結果には影響しない）。
  final String reason;

  /// 正規化領域を画像 px 座標へ変換する。
  Rect toPixelRect(int imageWidth, int imageHeight) => Rect.fromLTRB(
    (region.left * imageWidth).floorToDouble(),
    (region.top * imageHeight).floorToDouble(),
    (region.right * imageWidth).ceilToDouble(),
    (region.bottom * imageHeight).ceilToDouble(),
  );
}

/// 全体 OCR 結果からクロップ再 OCR 領域を算出する。
///
/// 領域の基準座標系は正規化座標（WHY: 実画像は 19 種類のサイズが混在する
/// ため、アンカー中心からの相対位置で設計根拠を表現する）。
class RegionSpecBuilder {
  const RegionSpecBuilder();

  /// アンカーの列窓外側のマージン（正規化幅）。
  ///
  /// WHY: 列窓は値の中心を狙った範囲で、窓端の文字が切れると ML Kit が
  /// 誤認識する。窓より ±0.03（画像幅の 3%）広く取る。
  static const double _xMargin = 0.03;

  /// アンカー行の上下マージン（正規化高さ）。
  ///
  /// WHY: 判定値は同一行（|dy| ≤ 0.012）だが、要素 bbox 中心と実際の文字
  /// 高さにズレがあり得る。ラベル高さ（≈0.02〜0.03）を含めて ±0.03 で
  /// 行を完全に覆う。
  static const double _yMargin = 0.03;

  /// ac_v1 行推定 spec の上下マージン（正規化高さ）。
  ///
  /// WHY 0.022（実測・tool/ac_row_deltas_output.txt）: ラベル/値の内容半高は
  /// 正規化 ≈0.014 以下（ラベル高さ中央値 0.021-0.027）、行推定の誤差は
  /// 実測最大 ≈0.005（wide169 のチェーンウォーク）。隣行コンテンツは行間
  /// dCy ≈0.044（主群）/ ≈0.052（16:9）から内容半高を引いた ≈0.025-0.038
  /// 以遠に始まるため、0.022 は推定行を覆いつつ隣行を排除する中間値。
  /// portrait（行間 dCy ≈0.021）は余裕がないため推定対象外
  /// （ac_row_estimator.dart 参照）。
  static const double _acEstimatedYMargin = 0.022;

  /// 難易度要素の正規化中心 y の上限（設定欄の "EX" 等との誤一致防止）。
  ///
  /// WHY: 難易度要素は曲名帯の上（観測 cy 0.1344〜0.1521）にあり、
  /// 判定欄や設定欄（cy > 0.5）の "EX" 表記とは y 座標で明確に分離する。
  static const double _difficultyCyMax = 0.2;

  /// 難易度語彙（大文字正規化後の完全一致・ST-5 フェーズ2-B でフルセット化）。
  ///
  /// WHY 実測（39 枚インベントリ・
  /// docs/st5_b_difficulty_vocabulary_design_confirmation_2026-11-22.md §2）:
  /// EX 24/30（+誤読 ER/EK 2 件は語彙で救えず difficultyEx NCC anchor が
  /// 補完）、NORMAL 2/30（kt1odi/yb5h8w・追加まで median fallback 落ち）、
  /// LIGHT 1/30（5p1lg4・削除すると同画像の level が NCC/median に後退する
  /// ため維持）、HYPER/EASY は 39 枚に実例なしの仕様語（ユーザー指示
  /// 「difficulty要素にはHYPERもあるので忘れないでください」+ EASY/NORMAL/
  /// HYPER/EX フルセット化・合成テストで固定）。完全一致は現行契約維持
  /// （contains への変更は 'TEXT' 等への誤マッチ面を広げるため不採用）。
  static const List<String> _difficultyVocabulary = [
    'EX',
    'LIGHT',
    'HYPER',
    'NORMAL',
    'EASY',
  ];

  /// 難易度要素が全体 OCR で未検出のときの仮アンカー（正規化座標）。
  ///
  /// WHY: 実測中央値（stats §4.1 の EX ラベル位置 cx 0.4740 / cy 0.1521）。
  /// 難易度欄はスコア欄とは独立した固定レイアウトのため、要素が検出
  /// できない画像でもこの位置を仮アンカーにしてレベル領域を算出する。
  static const double _fallbackDifficultyCx = 0.4740;
  static const double _fallbackDifficultyCy = 0.1521;

  /// NCC アンカー採用の最低スコア（幾何層ゲート第 1 条件・受け入れ条件②）。
  ///
  /// WHY 0.55: 設計 §1.4 のプローブ実測（横テンプレを縦バンドクロップへ
  /// 適用する最悪条件で 18/18・avgNCC 0.78、下限 0.495=0.55×0.9 で全成功）。
  /// 正ヒットは ≈0.78、無地/誤構造物は ≈0 のため誤検出側に十分な余裕。
  /// ui_anchor.dart の探索閾値と同値だが、幾何判断が単独でも防御できるよう
  /// 二重化（パック側閾値の変更に左右されない契約として本定数で固定）。
  static const double _anchorGateMinScore = 0.55;

  /// frameRight 整合サニティの許容差（正規化 x・|検出 − canonical|）。
  ///
  /// WHY 0.05: 設計 §1.1 の per-image local-peak 整合誤差 ±12px ≈ ±0.01W
  /// の 5 倍余裕。これを超えるズレは同一画面内の別の構造物（誤エッジ）を
  /// 捕えている可能性が高く、アンカー系の補正全体を不信扱いにする。
  static const double _anchorSanityMaxNormXDelta = 0.05;

  /// アンカー δ 補正の上限（正規化 y・受け入れ条件②の正準維持）。
  ///
  /// WHY 0.06: 探索窓 ±96px = ±0.08W に対し、実測で想定される正準位置ズレは
  /// ラベル cy sd 0.0039-0.0046（stats §3.1）とタスク A クロップエッジ誤差
  /// ±10px ≈ ±0.014 の合計 ≤ ~0.015。0.06 はその 4 倍の余裕で、これを超える
  /// δ はアンカー誤検出か系統的なレイアウト差であり、無補正（正準 spec）の
  /// 維持が安全。
  static const double _maxAnchorShiftNorm = 0.06;

  /// δ の供給源アンカー id（assets/anchors/hc_v1 のパック契約 id）。
  ///
  /// WHY gaugeHeader: 設計 §1.2 事後確認の実測で 29/30 検出・cy spread
  /// ±0.004 と最安定（settingsNormal 26/30・cy spread ±0.024、difficultyEx
  /// 24/30 は存在時のみ）。δ 供給は 1 ソースに限定して判断を単純化し、
  /// 他アンカーは AnchorRegistration に記録・観測のみ（KISS）。
  static const String _deltaSourceAnchorId = 'gaugeHeader';

  /// frameRight 整合サニティに使うアンカー id（パック契約 id）。
  static const String _frameRightAnchorId = 'frameRight';

  /// level 再計算に使う難易度 EX アンカー id（パック契約 id）。
  static const String _difficultyExAnchorId = 'difficultyEx';

  /// [pageResult] の要素からクロップ再 OCR 領域を算出する。
  ///
  /// 数値系（score〜maxCombo）はアンカー未検出の種別をスキップする
  /// （WHY: アンカーなしの固定位置クロップは誤領域のリスクが高く、
  /// ノイズを増やすだけ。アンカーが取れるものだけ確実に再 OCR する）。
  /// GOOD は 2 番目の spec（底辺拡張 + scale 2.0）を併せ持つ（WHY:
  /// 23bjim good=2 はクロップ底辺拡張 + scale 2.0 で検出成功。
  /// e6xlzd good=0 はプライマリ・フォールバック両方で未検出（既知限界）。
  /// [targets] を指定するとその対象だけを算出する。
  ///
  /// [anchors] は ST-3.5（共通 UI アンカー登録）の検出結果。純データのみを
  /// 受け取り、デコード/NCC 機構は ui_anchor.dart 側に封入する（リード
  /// 受け入れ条件①・DIP）。null・ゲート不成立・縦入力（h > w）のときは
  /// anchors を一切使わず現行動作 100% を維持する（正準 spec 維持・条件②）。
  List<RegionSpec> buildSpecs(
    OcrPageResult pageResult, {
    Set<RegionTarget>? targets,
    AnchorRegistration? anchors,
    LayoutKind layoutKind = LayoutKind.hcV1,
  }) {
    final extractor = FieldExtractor(layoutKind: layoutKind);
    // WHY 縦入力で anchors を無効化: アンカー canonical は横 1200x800 基準
    // の実測で、縦レガシー空間（1071x2316）への適用は未検証。タスク A の
    // 正規化後（1080x714・h < w）は横経路に入るため、この分岐は縦未対応
    // 環境の防御であり正準維持が安全側（integration red で再評価）。
    final normalizedAnchors =
        pageResult.imageWidth != null &&
            pageResult.imageHeight != null &&
            pageResult.imageHeight! > pageResult.imageWidth!
        ? null
        : anchors;
    final specs = <RegionSpec>[];
    for (final target in RegionTarget.values) {
      if (targets != null && !targets.contains(target)) {
        continue;
      }
      // WHY: switch 式の case は文を書けないため、_levelSpec の呼び出しは
      // switch の外で 1 回だけ行う（呼び出し重複の排除がこの修正の目的）。
      final levelSpec = target == RegionTarget.level
          ? _levelSpec(pageResult, normalizedAnchors)
          : null;
      final specList = switch (target) {
        RegionTarget.songTitle => _songTitleSpecs(pageResult),
        RegionTarget.level => levelSpec == null ? <RegionSpec>[] : [levelSpec],
        _ => _numericSpecs(extractor, pageResult, target),
      };
      specs.addAll(specList);
    }
    return specs;
  }

  /// 数値系（ラベルアンカー + 列窓）の領域を算出する。
  ///
  /// アンカー検出済み: 現行経路（GOOD だけ 2 つめの spec（底辺拡張 +
  /// scale 2.0）を追加・[_specsFromAnchor] 参照）。アンカー未検出: ac_v1 に
  /// 限り行推定フォールバック（AcRowEstimator・01a2065a Q3 裁定）で spec を
  /// 立てる。hc_v1 は現行どおりアンカー不在 = spec なし（構造的非回帰）。
  List<RegionSpec> _numericSpecs(
    FieldExtractor extractor,
    OcrPageResult pageResult,
    RegionTarget target,
  ) {
    final kind = _numericKindOf(target);
    final anchor = extractor.anchorPositionOf(pageResult, kind);
    if (anchor != null) {
      return _specsFromAnchor(extractor, target, kind, anchor);
    }
    if (extractor.layoutKind != LayoutKind.acV1) {
      return const []; // アンカー未検出（hc_v1 は現行どおり spec なし）。
    }
    final estimate = const AcRowEstimator().estimate(
      pageResult,
      kind,
      extractor,
    );
    if (estimate == null) {
      return const []; // 推定不能（全ラベル不在・portrait 等）。
    }
    final window = extractor.columnWindowOf(kind);
    return [
      RegionSpec(
        target: target,
        region: Rect.fromLTRB(
          _clamp01(estimate.cx + window.min - _xMargin),
          _clamp01(estimate.cy - _acEstimatedYMargin),
          _clamp01(estimate.cx + window.max + _xMargin),
          _clamp01(estimate.cy + _acEstimatedYMargin),
        ),
        script: OcrScript.latin,
        pixelScale: 3.0,
        // WHY contrastRetry は新経路のみ: 推定 spec は既存の入力経路を持た
        // ないため、0 要素時の二値化再試行を有効にしても検出済みキーの入力
        // を変えない（r6 契約「primary/fallback1 には設定しない」の精神を
        // 維持）。主経路 spec は設定しない。
        contrastRetry: true,
        reason:
            'ac row-estimated (${estimate.reason}) + column window '
            '[${window.min}, ${window.max}] ± margins',
      ),
    ];
  }

  /// アンカー検出済みの数値 spec（現行経路・GOOD/BAD 底辺拡張を含む）。
  List<RegionSpec> _specsFromAnchor(
    FieldExtractor extractor,
    RegionTarget target,
    NumericFieldKind kind,
    ({double cx, double cy}) anchor,
  ) {
    final window = extractor.columnWindowOf(kind);
    final left = _clamp01(anchor.cx + window.min - _xMargin);
    final right = _clamp01(anchor.cx + window.max + _xMargin);
    final top = _clamp01(anchor.cy - _yMargin);
    final bottom = _clamp01(anchor.cy + _yMargin);

    final specs = <RegionSpec>[
      RegionSpec(
        target: target,
        region: Rect.fromLTRB(left, top, right, bottom),
        script: OcrScript.latin,
        pixelScale: 3.0,
        reason:
            'label anchor (${anchor.cx.toStringAsFixed(4)}, '
            '${anchor.cy.toStringAsFixed(4)}) + column window '
            '[${window.min}, ${window.max}] ± margin (stats §7)',
      ),
    ];

    // WHY: GOOD は動的カウンター（モーションブラー/ゴースト付き）で、
    // 値グリフがクロップ底辺で切れやすい。プライマリ spec（bottom=cy+0.03）
    // で 0 候補の場合のみ、bottom=cy+0.06 のフォールバック spec を実行する
    //（WHY: 拡張 spec は隣行（BAD 行の値帯 cy+0.034〜0.058）を完全に含む
    // ため、常時実行すると隣行値を桁数優先で誤採用する）。
    // probe 結果：23bjim good=2 はプライマリ spec で未検出、フォールバック
    // spec で "2" を検出。e6xlzd good=0 はプライマリ・フォールバック両方で
    // 未検出（既知限界）。
    //
    // WHY ac_v1 では拡張 spec を生成しない: ac の判定行間 dCy≈0.044（主群）
    // に対し拡張幅 +0.06 が隣行（GOOD の下は BAD 行・BAD の下は COMBO 行）
    // に届き、対象行グリフ未検出時に隣行値を誤採用する（実測: 30 枚フル
    // パイプラインで bad 7 件・good 1 件の誤値。いずれも隣行の同値要素と
    // 行一致した。tool/ac_wave2_verification_output.txt）。hc_v1 は BAD が
    // 判定行の最下段で下に判定行が存在しないため現行維持（r6 実績）。
    final canExpand = extractor.layoutKind != LayoutKind.acV1;
    if (canExpand && target == RegionTarget.good) {
      final expandedBottom = _clamp01(anchor.cy + 2 * _yMargin);
      specs.add(
        RegionSpec(
          target: target,
          region: Rect.fromLTRB(left, top, right, expandedBottom),
          script: OcrScript.latin,
          pixelScale: 2.0,
          isFallback: true,
          reason:
              'GOOD fallback (bottom=cy+2×_yMargin = '
              '${expandedBottom.toStringAsFixed(4)}) + scale 2.0 '
              '(プライマリ 0 候補時のみ実行・23bjim "2" 検証済み)',
        ),
      );
    }

    // WHY: BAD も一部画像で値グリフが底辺 +0.03 で切れる。プライマリ spec
    // で 0 候補の場合のみフォールバック spec を実行する（5p1lg4 bad=0 は
    // y 0.70 以降にあり、moderate 拡張では届かず既知限界）。
    // ac_v1 は上記のとおり隣行（COMBO）誤採用のため拡張しない。
    if (canExpand && target == RegionTarget.bad) {
      final expandedBottom = _clamp01(anchor.cy + 2 * _yMargin);
      specs.add(
        RegionSpec(
          target: target,
          region: Rect.fromLTRB(left, top, right, expandedBottom),
          script: OcrScript.latin,
          pixelScale: 2.0,
          isFallback: true,
          reason:
              'BAD fallback (bottom=cy+2×_yMargin = '
              '${expandedBottom.toStringAsFixed(4)}) + scale 2.0 '
              '(プライマリ 0 候補時のみ実行・5p1lg4 は既知限界)',
        ),
      );
    }
    return specs;
  }

  /// レベル領域（難易度要素の右隣。未検出時は EX アンカー → 実測中央値）。
  ///
  /// ST-3.5 の統合点（設計 §2.4・受け入れ条件②）:
  /// - difficulty 要素が取れた場合: element 相対（現行どおり。全域シフトに
  ///   自己整合するため δ 補正は行わない）。
  /// - difficulty 要素が取れず difficultyEx NCC アンカーがゲート成立:
  ///   EX 検出位置を難易度ラベル位置として使う（median fallback の置換）。
  /// - いずれも不成立: median fallback + gaugeHeader δ（正準固定窓への
  ///   補正。ゲート不成立なら無補正 = 現行値そのまま）。
  RegionSpec? _levelSpec(
    OcrPageResult pageResult,
    AnchorRegistration? anchors,
  ) {
    final difficulty = _findDifficulty(pageResult);
    if (difficulty != null) {
      final (cx, cy, label) = difficulty;
      return _levelSpecAt(
        cx,
        cy,
        'difficulty element "$label" at '
        '(${cx.toStringAsFixed(4)}, ${cy.toStringAsFixed(4)})',
      );
    }
    final anchored = _anchorLevelSpec(anchors);
    if (anchored != null) {
      return anchored;
    }
    final delta = _anchorDeltaY(anchors);
    final cy = _fallbackDifficultyCy + (delta?.$1 ?? 0.0);
    return _levelSpecAt(
      _fallbackDifficultyCx,
      cy,
      delta == null
          ? 'difficulty element not detected; fallback to measured median '
                'position ($_fallbackDifficultyCx, $_fallbackDifficultyCy)'
          : 'difficulty element not detected; median fallback re-centered '
                'by ${delta.$2}',
    );
  }

  /// 難易度ラベル位置 (cx, cy) を level バンド幾何へ写像する（共通部）。
  ///
  /// WHY dx [0.20, 0.45]: レベル文字列（"Lv.50" 等）の観測は難易度中心から
  /// dx ≈ +0.34（"LW501"/"LUS0" 3 例）。数字列の並びに幅があるため広めの
  /// 窓 + マージンで囲む。WHY Latin: レベルは数字のみで構成され、Latin
  /// モデルの方が桁・記号の分解能が高い。
  RegionSpec _levelSpecAt(double cx, double cy, String anchorDescription) {
    final left = _clamp01(cx + 0.20 - _xMargin);
    final right = _clamp01(cx + 0.45 + _xMargin);
    final top = _clamp01(cy - _yMargin);
    final bottom = _clamp01(cy + _yMargin);
    return RegionSpec(
      target: RegionTarget.level,
      region: Rect.fromLTRB(left, top, right, bottom),
      script: OcrScript.latin,
      pixelScale: 3.0,
      reason:
          '$anchorDescription + level offset [0.20, 0.45] (observed '
          'reads LW501/LUS0 ≈ Lv.50)',
    );
  }

  /// difficultyEx NCC アンカーがゲート成立したときの level spec（他は null）。
  ///
  /// WHY 検出位置を直接使う: EX アンカーは探索窓（±96px）で canonical 近傍
  /// に制限されており、NCC ≥ [_anchorGateMinScore] を満たすヒットは実ラベル
  /// 位置の信頼できる測定値。frameRight 整合サニティは共通ゲートで担保する
  /// （受け入れ条件②・KISS として δ 上限の追加判定はしない）。
  RegionSpec? _anchorLevelSpec(AnchorRegistration? anchors) {
    if (anchors == null) {
      return null;
    }
    final ex = anchors.hitOf(_difficultyExAnchorId);
    if (ex == null || ex.score < _anchorGateMinScore) {
      return null;
    }
    if (!_frameRightSane(anchors)) {
      return null;
    }
    return _levelSpecAt(
      ex.position.dx,
      ex.position.dy,
      'difficultyEx anchor (ncc=${ex.score.toStringAsFixed(2)}) at '
      '(${ex.position.dx.toStringAsFixed(4)}, '
      '${ex.position.dy.toStringAsFixed(4)})',
    );
  }

  /// frameRight 整合サニティ（アンカー再センタリング/再計算の共通条件・
  /// 受け入れ条件②）。
  ///
  /// WHY: frameRight が canonical から大きく外れて検出された場合は同一画面
  /// 内の別構造物を捕えた誤検出の可能性が高く、アンカー系の補正全体を
  /// 不信扱いにして正準 spec を維持する。
  bool _frameRightSane(AnchorRegistration? anchors) {
    if (anchors == null) {
      return false;
    }
    final frameRight = anchors.hitOf(_frameRightAnchorId);
    if (frameRight == null) {
      return false;
    }
    return (frameRight.position.dx - frameRight.canonicalPosition.dx).abs() <=
        _anchorSanityMaxNormXDelta;
  }

  /// ゲート成立時の δ（正規化 y 補正量）とその説明。不成立時は null。
  ///
  /// ゲート（受け入れ条件②）: gaugeHeader NCC ≥ [_anchorGateMinScore] AND
  /// frameRight 整合サニティ成立 AND |δ| ≤ [_maxAnchorShiftNorm]。
  /// 不成立時は正準 spec を維持する（戻り値 null = 無補正）。
  (double, String)? _anchorDeltaY(AnchorRegistration? anchors) {
    if (anchors == null) {
      return null;
    }
    final gauge = anchors.hitOf(_deltaSourceAnchorId);
    if (gauge == null || gauge.score < _anchorGateMinScore) {
      return null;
    }
    if (!_frameRightSane(anchors)) {
      return null;
    }
    final dy = gauge.position.dy - gauge.canonicalPosition.dy;
    if (dy.abs() > _maxAnchorShiftNorm) {
      return null;
    }
    return (
      dy,
      'anchor δ=${dy.toStringAsFixed(4)} (gaugeHeader '
          'ncc=${gauge.score.toStringAsFixed(2)})',
    );
  }

  /// 曲名帯（固定バンド・日本語スクリプト）。
  ///
  /// WHY anchors（δ）を適用しない（ST-5 横有効決定退行是正・設計確認
  /// docs/st5_delta_regression_fix_design_confirmation_2026-11-22.md・
  /// docs コミット 0232da5・リード承認済み）: r4 実測で gaugeHeader cy の
  /// ふれ（0.3425-0.3564・canonical 0.3525）は固定テンプレ UI の NCC 検出
  /// ノイズであり、δ を曲名帯へ伝搬するとクロップ内容シフト→ML Kit の
  /// 読み取り同一性入れ替わりで横有効決定 14/30→10/30 に退行した
  /// （52c4xa と bt2qlc は NCC/cy/δ 3 値完全同一で hit が真逆＝単調
  /// ゲートでは原理的に分離不能）。r3 (39d9fba) の固定帯が実測 14/30 の
  /// ため常時固定を維持する。
  RegionSpec _songTitleSpec() {
    // WHY 固定バンド: タイトル行のラベルは存在せずアンカーにできない。
    // 実測では曲名要素が cy ≈ 0.215 に 1 例のみ検出（全 30 枚中）で、
    // 難易度行（cy 0.1344〜0.1521）の直下に曲名帯（白文字のジャンル/カテゴリ
    // 行 + ピンク文字の曲名行の 2 行構成・GT 設計事実）がある。難易度行の
    // 下端から判定欄（SCORE cy 0.476）までの間でバンド [0.16, 0.30] を取る。
    // WHY 日本語: 曲名・ジャンルは漢字仮名混じりを含むため。
    return RegionSpec(
      target: RegionTarget.songTitle,
      region: const Rect.fromLTRB(0, 0.16, 1, 0.30),
      script: OcrScript.japanese,
      reason:
          'fixed title band cy [0.16, 0.30] (title row observed at '
          'cy 0.215 below difficulty row; full width)',
    );
  }

  /// 曲名帯の spec 群（縦横で分岐）。
  ///
  /// WHY 分岐: 縦スクショ（前処理後 h > w・実測 scr001-009 は 1071x2316）
  /// では横画像向け固定バンド [0.16, 0.30] に曲名要素が無い（QA-Docs 診断
  /// 9/9 帯内 0 要素・probe 実測でも同様）。曲名行は cy 0.441-0.442 に実測
  /// されており、portrait バンド [0.40, 0.47] を 1 本だけ返す。横バンドを
  /// 縦で実行しないのは、実測 9/9 で帯内 0 要素の捨て打ちになるため。
  /// WHY 寸法未設定時は横バンド経路を維持: 縦横を判定できない入力では
  /// 既存動作（後方互換）が安全側デフォルト。実運用では pipeline が必ず
  /// 寸法付き pageResult を渡すため、この分岐は防御的経路。
  /// WHY 分岐コードを削除しない: 将来 A（埋め込み帯抽出→レイアウト正規化）
  /// が着地して前処理後が横長化しても、縦画像未対応環境の耐性として保持。
  List<RegionSpec> _songTitleSpecs(OcrPageResult pageResult) {
    final w = pageResult.imageWidth;
    final h = pageResult.imageHeight;
    if (w != null && h != null && h > w) {
      return [_songTitlePortraitSpec()];
    }
    // WHY 曲名帯は常時固定（δ 適用は廃止・docs 0232da5・リード承認済み）:
    // _songTitleSpec の doc コメント参照。_anchorDeltaY は level median
    // fallback（_levelSpec）でのみ継続使用する。
    // WHY 狭帯 A/B を末尾に追加（docs
    // st5_f2_f_narrowband_scale3_design_confirmation_2026-11-22.md・
    // commit a2037df・リード承認済み）: 曲名バナー付き新 UI のグラデーション
    // 装飾文字は低コントラストで ML Kit が検出段階で 0 要素になり、広帯 2 本
    // （scale 1.0/2.0）でも不検出だった（probe 実測・未検出 3 キー
    // 5p1lg4/23bjim/yb5h8w）。狭帯 + scale 3.0 拡大で検出可能性を上げる。
    // 発火は primary + fallback1 の両方が 0 候補のときのみ（runner 契約）。
    return [
      _songTitleSpec(),
      _songTitleFallbackSpec(),
      _songTitleNarrowASpec(),
      _songTitleNarrowBSpec(),
    ];
  }

  /// 縦スクショ用の曲名帯 spec（プレーシェア中央バンド・scale 1.0）。
  ///
  /// WHY [0.40, 0.47]: QA-Docs 診断の実効帯 [0.408, 0.452]（曲名行
  /// cy 0.43-0.45・probe 実測 cy 0.441-0.442）にレイアウト余裕分のマージン
  /// を加えた設計。隣接行（NORMAL cy 0.401-0.403 / ジャンル行 cy 0.418-0.424
  /// / GAUGE 行 cy 0.464・probe 実測）は混入するが、SongTitleElementMatcher
  /// の行クラスタリング + ジャンル行除外 + autoDecide 閾値 1 が吸収するため
  /// spec 側では除外ロジックを追加しない（KISS・scr009 の EMO 除外で実証）。
  /// WHY scale 1.0 のみ: 縦の曲名は stylized フォントで scale 3 japanese
  /// 再 OCR が不改善（QA-Docs レポート §3 実測・ジャンル行＝標準フォントは
  /// scale 3 で完読可）のため拡大再 OCR を採用しない（候補 D・不採用根拠）。
  RegionSpec _songTitlePortraitSpec() {
    return RegionSpec(
      target: RegionTarget.songTitle,
      region: const Rect.fromLTRB(0, 0.40, 1, 0.47),
      script: OcrScript.japanese,
      reason:
          'portrait title band cy [0.40, 0.47] (title row measured '
          'cy 0.441-0.442 in preprocessed 1071x2316 portrait shots; '
          'landscape bands hold 0 elements there - separate mechanism; '
          'scale 3 re-OCR rejected: no improvement on stylized fonts '
          '(QA-Docs ad23363 §3))',
    );
  }

  /// 曲名帯フォールバック（縦拡張バンド + scale 2.0・プライマリ 0 候補時のみ）。
  ///
  /// WHY 縦拡張 [0.14, 0.34]: プライマリ固定バンド [0.16, 0.30] は曲名行
  /// （cy ≈ 0.215 中心）を覆うが、レイアウト揺らぎで曲名行が帯下端付近に
  /// 来る画像がある（probe 実測: g7p9b2 曲名 cy ≈ 0.302・ay7zmq は帯外/
  /// 検出漏れ）。上端 0.14 は難易度行（cy 0.1344〜0.1521）の下部を含むが、
  /// SongTitleElementMatcher（ST-5 本実装）が要素単位照合 + 行クラスタリング
  /// で難易度/ジャンル行を除外するため誤照合しない。
  /// WHY scale 2.0: probe で 2 枚が復帰するほか、fj61sj の 'Eragarach' →
  /// 'Fragarach' のように拡大で読み品質が上がる観測があるため。
  /// WHY プライマリ有効時は実行しない（runner 契約）: 実測 24/30 が
  /// プライマリで検出済みで、追加 OCR の無駄打ちを避ける。
  RegionSpec _songTitleFallbackSpec() {
    return RegionSpec(
      target: RegionTarget.songTitle,
      region: const Rect.fromLTRB(0, 0.14, 1, 0.34),
      script: OcrScript.japanese,
      pixelScale: 2.0,
      isFallback: true,
      reason:
          'songTitle fallback: widened band cy [0.14, 0.34] + scale 2.0 '
          '(probe: g7p9b2 cy 0.302 / ay7zmq recover; primary-valid runs '
          'skip fallback per runner contract)',
    );
  }

  /// 曲名帯狭帯 A（2 行構成の下段曲名行・scale 3.0・全広帯 0 候補時のみ）。
  ///
  /// WHY [0.24, 0.29]: 曲名バナー付き新 UI で 2 行構成（上=ジャンル行白文字・
  /// 下=曲名行ピンク文字）の画像（23bjim・5p1lg4）の probe 輝度プロファイル
  /// 実測で、下段曲名行は p≥8 cy 0.2468-0.2861（23bjim）/ 0.2468-0.2804
  /// （5p1lg4）に存在。上端 0.24 は上段ジャンル行（0.1807-0.2271・peak
  /// p≈86-91）を確実に排除し、下端 0.29 は判定欄バー（0.3042+）を排除する。
  /// WHY scale 3.0: Harmonia の文字高 ≈19px は ML Kit の検出下限付近で
  /// scale 1.0/2.0 とも検出段階で 0 要素だった（根本原因・probe crop 視認
  /// 込み）。scale 3.0 で ≈57px に拡大して検出可能性を引き上げる。帯高
  /// 0.05×800=40px の縦 3 倍 = 120px、横長辺 1200×3=3600px は縦画像の
  /// scale 3 実験で実績のある寸法帯（QA-Docs ad23363・_crop に寸法制限なし）。
  /// WHY caveat: ad23363 §3 の通り scale 3 は stylized 読み品質を必ずしも
  /// 改善しない。r6 実画像検証の結果、23bjim/5p1lg4 は scale 3.0 でも
  /// 検出 0 要素のまま（根本原因は scale ではなく stylized 文字の低コントラ
  /// スト）。そこで 0 要素時のみ二値化前処理付き再 OCR を発火させる
  /// contrastRetry を有効化した（設計確認書 18b2111・フェーズ2-G）。
  RegionSpec _songTitleNarrowASpec() {
    return RegionSpec(
      target: RegionTarget.songTitle,
      region: const Rect.fromLTRB(0, 0.24, 1, 0.29),
      script: OcrScript.japanese,
      pixelScale: 3.0,
      isFallback: true,
      contrastRetry: true,
      reason:
          'songTitle narrow band A cy [0.24, 0.29] + scale 3.0 '
          '(probe: 2-line title lower row measured cy 0.2468-0.2861 in '
          '23bjim/5p1lg4; genre row 0.1807-0.2271 and judgment bar '
          '0.3042+ excluded; ML Kit missed 19px-tall gradient stylized '
          'text at scale 1.0-2.0 (detection stage, 0 elements); r6 '
          'confirmed scale 3.0 still yields 0 elements for stylized '
          'gradient text - contrastRetry binarize added (18b2111))',
    );
  }

  /// 曲名帯狭帯 B（1 行構成の曲名行・scale 3.0・狭帯 A まで 0 候補時のみ）。
  ///
  /// WHY [0.19, 0.29]: 曲名バナー付き新 UI で 1 行構成の画像（yb5h8w・
  /// GT=アイスクリームマジック）の probe 実測で、曲名行は p≥28 cy
  /// 0.2193-0.2755 に存在。上端 0.19 は装飾バー 1 本目（0.1697-0.1828・
  /// peak p≈150-158）を排除し、下端 0.29 は装飾バー 2 本目（0.3042-0.3133）
  /// を排除する。A の下段行（0.2468-0.2861）も覆うが、発火順で A を先に
  /// 試すため A 想定画像が B で再 OCR されることはない（runner は候補が
  /// 得られた時点で打ち切り）。文字高 ≈43px でも scale 1.0 で 0 要素だった
  /// ため（検出段階失敗・グラデーション文字）scale 3.0 で検出可能性を
  /// 引き上げる。r6 実画像検証で yb5h8w は scale 3.0 でも検出 0 要素のまま
  /// だった（根本原因は stylized 文字の低コントラスト）ため、狭帯 A と同様に
  /// 0 要素時の contrastRetry（二値化前処理付き再 OCR）を有効化した
  /// （設計確認書 18b2111・フェーズ2-G）。
  RegionSpec _songTitleNarrowBSpec() {
    return RegionSpec(
      target: RegionTarget.songTitle,
      region: const Rect.fromLTRB(0, 0.19, 1, 0.29),
      script: OcrScript.japanese,
      pixelScale: 3.0,
      isFallback: true,
      contrastRetry: true,
      reason:
          'songTitle narrow band B cy [0.19, 0.29] + scale 3.0 '
          '(probe: single-row title measured cy 0.2193-0.2755 in yb5h8w; '
          'decoration bars 0.1697-0.1828 / 0.3042-0.3133 excluded; '
          'fired only when band A above also returns no candidates; '
          'r6 confirmed scale 3.0 still yields 0 elements for stylized '
          'gradient text - contrastRetry binarize added (18b2111))',
    );
  }

  /// 難易度要素（EASY/NORMAL/HYPER/EX・LIGHT は実測 1/30 で維持・曲名帯の上）
  /// を正規化中心座標で探す。語彙は [_difficultyVocabulary]（完全一致・
  /// 大文字正規化後）。
  ///
  /// 同種の要素が複数ある場合は読み取り順で先勝ち（決定的。
  /// FieldExtractor._collectAnchors と同一方針）。
  (double, double, String)? _findDifficulty(OcrPageResult pageResult) {
    _requireDims(pageResult);
    final width = pageResult.imageWidth!.toDouble();
    final height = pageResult.imageHeight!.toDouble();
    for (final element in pageResult.elements) {
      final normalized = element.text.trim().toUpperCase();
      if (!_difficultyVocabulary.contains(normalized)) {
        continue;
      }
      final cx =
          (element.boundingBox.left + element.boundingBox.right) / 2 / width;
      final cy =
          (element.boundingBox.top + element.boundingBox.bottom) / 2 / height;
      if (cy <= _difficultyCyMax) {
        return (cx, cy, element.text);
      }
    }
    return null;
  }

  NumericFieldKind _numericKindOf(RegionTarget target) => switch (target) {
    RegionTarget.score => NumericFieldKind.score,
    RegionTarget.cool => NumericFieldKind.cool,
    RegionTarget.great => NumericFieldKind.great,
    RegionTarget.good => NumericFieldKind.good,
    RegionTarget.bad => NumericFieldKind.bad,
    RegionTarget.maxCombo => NumericFieldKind.maxCombo,
    _ => throw StateError('$target is not a numeric target'),
  };

  double _clamp01(double value) => value.clamp(0.0, 1.0);

  void _requireDims(OcrPageResult pageResult) {
    if (pageResult.imageWidth == null || pageResult.imageHeight == null) {
      throw ArgumentError(
        'OcrPageResult.imageWidth/imageHeight must be set by the engine.',
      );
    }
  }
}
