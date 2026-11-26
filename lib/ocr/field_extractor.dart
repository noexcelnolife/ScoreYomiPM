/// ST-4 フィールド別OCR の抽出コア（spec.md §5.2）。
///
/// [OcrPageResult]（画像全体 OCR の生結果）から、プレーシェア結果画面の
/// 数値フィールド（スコア・COOL/GREAT/GOOD/BAD 判定数・MAX COMBO）を
/// 抽出する純 Dart 実装。依存は ocr_models（[OcrElement] /
/// [OcrPageResult]）と immutable 注釈のための foundation のみで、
/// OCR エンジンやプラグインに非依存（spec.md §7.3 の系統非依存・DIP）。
///
/// ## 方式（実データ統計に基づく・docs/field_layout_stats_2026-11-22.md §7）
///
/// 1. ラベルアンカーはテキスト完全一致（大文字小文字を正規化）で検出する。
///    WHY: 実データ 30 枚のラベル表記は大文字小文字の揺れ（`cOOL` 1 例）
///    以外に変異がなく、あいまい照合（レーベンシュタイン距離等）は
///    偽アンカーを生むリスクしかない（KISS・stats §3「30/30 変異なし」）。
/// 2. アンカー → 値要素の対応付けは「先に列（dx 符号・範囲）を確定させて
///    から同一直行（|dy| 窓）で値を取る」（stats §7⑤）。
///    WHY: 単純な近接最小距離マッチは偽ペアを生む。実際、統計書 §4.2 の
///    「GREAT dy −0.046 / GOOD dy −0.045 / BAD dx −0.11」は、値が未検出の
///    行で隣行の値を拾った偽ペアであることを Ground Truth（9 サンプル）
///    照合で確認した。真の幾何は「値はラベルと同一行の右側」：
///    COOL/GREAT/GOOD 値 dx≈+0.12〜+0.14、BAD 値 dx≈+0.19（右側！）、
///    COMBO 値 dx≈+0.14（右側！）、SCORE 値 dx≈+0.25。
/// 3. 座標はすべて正規化座標（要素中心 ÷ 画像幅・高さ）で扱う。
///    WHY: 実データは画像寸法が 19 パターンあり（stats §2）、絶対座標の
///    閾値は画像サイズで破綻するため（stats §7①）。
/// 4. 値テキストは全角数字の半角化 → 区切り除去 → 非数字 1 文字までを
///    許容して置換（O→0, l→1, その他は除去）して整数化する。
///    WHY: `9500O`（末尾 O は 0 の誤読）は置換で GT 値 95000 に復元できた
///    一方、除去すると 9500 という誤値になる（GT 照合で確認）。
///    非数字 2 文字以上（例: `BO`=30 の誤読）は偽値を避けるため拒否する。
/// 5. GREAT は `GREAT143` のように値がラベルに連結する形が 6/30 ある
///    （stats §7②）ため、連結形の接尾数字を直接値として採る。
/// 6. フィールド信頼度 = 根拠要素（ラベル + 値）の confidence 平均。
///    いずれかの根拠要素が [OcrElement.confidenceUnknown]（センチネル）の
///    場合は信頼度も不明としてセンチネルを伝播させる
///    （WHY: 平均は「不明」を「低い値」と偽装するため、不明は不明のまま
///    受け渡す。レイヤー判断は呼び出し側に委ねる）。
/// 7. スコアが 4 桁のときは信頼度を 0.5 倍に減衰する。
///    WHY: スコアは 5 桁が標準で、4 桁実測 2 例（96401→9640）はいずれも
///    末尾 1 桁の落字だった（GT クロスチェック）。桁落ち疑いを
///    信頼度の低さとして呼び出し側に伝える。
///
/// ## 「未抽出」と「抽出失敗」の区別
///
/// - 未抽出: 値要素が窓内に存在しない。→
///   [FieldExtractionResult.numericFields] にエントリ自体が存在しない
///   （[FieldExtractionResult.numeric] が null）。
///   実データでは BAD/GOOD の 1〜2 桁値が OCR 未検出になることが多く、
///   「未抽出」は失敗ではなく正常な状態である（stats §7⑥・⑧）。
/// - 抽出はしたが不審: 値は得られたが検証範囲外 →
///   [ExtractedNumericField.isValid] が false。または桁落ち疑い →
///   信頼度が減衰済み。
///
/// ## Wave 1 の抽出対象外（将来拡張）
///
/// - MISS 判定: PM（本作）には MISS 判定が存在しない（2026-11-21
///   ユーザー確認・BAD がミス相当）。判定欄は COOL/GREAT/GOOD/BAD の
///   4 行のみで MISS 行の要素は存在しないため、種別ごと削除した
///   （KISS/YAGNI・リーダー指示）。フルコンボ判定（spec VR-4）は
///   「BAD=0」で表現する。MISS の計算も不要と確定（2026-11-21 ユーザー
///   確認）: spec VR-1 は「判定合計 = 総ノーツ数（収録曲 DB 照合）」であり
///   MISS は式に現れない。逆算実装は後続フェーズ。
/// - レベル: Wave 1 では抽出されない（ラベル レベル/Lv が実データ 30 枚で
///   1 枚も検出されない・stats §3）。種別自体も保持しない（常に未抽出に
///   なる種別は死にコードになるため・KISS）。FR-3 確認画面のレベル行は
///   手入力で代替し、リージョン再 OCR（Wave 2 / ST-5）で抽出可能に
///   なった時点で種別を追加する。
///   レベル値の仕様は **1〜50 の整数**（2026-11-21 ユーザー確認）。
///   Wave 2 実装時の検証範囲は 1..50。ドット混じり読みへの対応として
///   ドットを OCR ノイズとして除去する正規化を許容する（種別によらない
///   一般ルール。FieldExtractor._parseNumericValue で動作済み）。
///   【訂正・2026-11-22】当初この正規化の動機例として挙げていた「4.6/4.3」
///   という読みは、実データ内の設定ブロック（HI-SPEED 欄・l558-587）の値
///   でありレベルの読みではなかった（リーダー確認・fb599cb §4）。レベル
///   自体はグラフィック描画のため Wave 1 の全体 OCR では未検出（0/30）。
///   この訂正はレベル種別を復活させない判断に影響しない（Wave 2 で
///   クロップ OCR が実用化された時点で種別＋バリデーション 1..50 を
///   セットで追加する）。なお「4.」で切れる部分読み（4→誤値）は
///   Wave 2 の測定時に分類する。
/// - 曲名: Wave 1 では抽出しない。
///   WHY: fullText 冒頭は誤読が支配的でアンカーに使えず（stats §7⑧）、
///   ヒューリスティックな抽出は偽値を作る。FR-3 の手入力で代替し、
///   Wave 2（リージョン再 OCR）で取得方式を確定させた時点で
///   テキストフィールドの型を追加する。
/// - パイプラインへの組み込みは精度確認（本ファイルの実データテスト）の
///   後に行う（タスク指示より）。画像寸法は呼び出し側が渡す。
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show immutable;
import 'package:scoreyomipm/models/ocr_models.dart';

/// 抽出対象の数値フィールド種別。
///
/// WHY レベル種別の経緯: レベルは実データ 30 枚の全体 OCR でラベル検出
/// 0/30 のため Wave 1 では意図的に実装しなかった（stats §3）。Wave 2 の
/// クロップ再 OCR（2026-11-22 計測）で "Lv.50" 型の読み
/// （LU50. 等の誤読）が取れることを実測で確認したため、クロップ結果専用の
/// パース（_parseLevelValue）+ バリデーション（1..50）をセットで追加した。
/// 全体 OCR の抽出には出てこない（アンカーを持たない）。
enum NumericFieldKind {
  /// スコア（5 桁・0〜100000）。4 桁読みは落字として信頼度を半減。
  score,

  /// MAX COMBO（COMBO ラベル行の値）。
  maxCombo,

  /// COOL 判定数。
  cool,

  /// GREAT 判定数。
  great,

  /// GOOD 判定数。
  good,

  /// BAD 判定数。
  bad,

  /// レベル（1〜50 の整数・2026-11-21 ユーザー確認）。
  ///
  /// 全体 OCR からは未抽出（ラベルアンカーなし）。クロップ再 OCR の
  /// 結果のみ入る（extractWithRegions）。
  level,
}

/// 抽出された 1 数値フィールドの確定値。
@immutable
class ExtractedField {
  /// フィールド種別。
  final NumericFieldKind kind;

  /// 正規化済みの数値。
  final int value;

  /// 値要素の生テキスト（正規化前）。
  final String rawText;

  /// フィールド信頼度（根拠要素 confidence の平均）。
  ///
  /// 根拠要素のいずれかが信頼度不明
  /// ([OcrElement.confidenceUnknown]) の場合はセンチネル値そのまま
  /// （「不明」を低い値と偽装しないため）。
  final double confidence;

  /// 値要素のバウンディングボックス（元画像座標系）。
  final Rect boundingBox;

  /// 検証範囲（spec.md §4.1）に収まるか。
  final bool isValid;

  /// 検証に失敗した理由（[isValid] が true のときは null）。
  final String? validationMessage;

  /// 根拠要素（ラベルアンカー + 値要素。連結形 GREAT143 の場合は 1 要素）。
  ///
  /// 手動構築（テスト等）では省略可能。
  final List<OcrElement> evidence;

  const ExtractedField({
    required this.kind,
    required this.value,
    required this.rawText,
    required this.confidence,
    required this.boundingBox,
    required this.isValid,
    this.validationMessage,
    this.evidence = const [],
  });

  @override
  String toString() =>
      'ExtractedField(${kind.name}: $value, '
      'raw: $rawText, conf: $confidence, valid: $isValid)';
}

/// 1 画像分のフィールド抽出結果。
@immutable
class FieldExtractionResult {
  /// 抽出できた数値フィールド（未抽出の種別はキー自体が存在しない）。
  final Map<NumericFieldKind, ExtractedField> numericFields;

  /// 抽出元となった OCR 要素数（デバッグ・計測用）。
  final int sourceElementCount;

  /// [numericFields] は [Map.unmodifiable] で包まれる（結果オブジェクトの
  /// 改変を防ぐため・const コンストラクタにはしない）。
  FieldExtractionResult({
    required Map<NumericFieldKind, ExtractedField> numericFields,
    required this.sourceElementCount,
  }) : numericFields = Map.unmodifiable(numericFields);

  /// 指定種別の抽出結果。未抽出なら null（「未抽出」と「抽出失敗」の区別は
  /// [ExtractedField.isValid] と [ExtractedField.confidence] で行う）。
  ExtractedField? field(NumericFieldKind kind) => numericFields[kind];

  /// スコア。
  ExtractedField? get score => field(NumericFieldKind.score);

  /// MAX COMBO。
  ExtractedField? get maxCombo => field(NumericFieldKind.maxCombo);

  /// COOL 判定数。
  ExtractedField? get cool => field(NumericFieldKind.cool);

  /// GREAT 判定数。
  ExtractedField? get great => field(NumericFieldKind.great);

  /// GOOD 判定数。
  ExtractedField? get good => field(NumericFieldKind.good);

  /// BAD 判定数。
  ExtractedField? get bad => field(NumericFieldKind.bad);

  /// レベル（クロップ再 OCR 専用・全体 OCR では常に null）。
  ExtractedField? get level => field(NumericFieldKind.level);

  @override
  String toString() => 'FieldExtractionResult(numeric: $numericFields)';
}

/// ラベルアンカー（内部表現）。
class _Anchor {
  final NumericFieldKind kind;
  final OcrElement element;
  final double cx;
  final double cy;

  /// `GREAT143` のようにラベルに値が連結している場合の値（なければ null）。
  final int? embeddedValue;

  const _Anchor({
    required this.kind,
    required this.element,
    required this.cx,
    required this.cy,
    this.embeddedValue,
  });
}

/// 値要素の列窓（dx 範囲と観測中心）。
///
/// dx = 値要素中心 x − ラベル中心 x（正規化座標）。範囲は実データ GT 照合の
/// 観測値（docs/field_layout_stats_2026-11-22.md §4.2 の偽ペアを除いた値）に
/// 余裕を持たせたもので、観測中心 [center] は複数候補時の決定的選択に使う。
class _ColumnWindow {
  final double min;
  final double max;
  final double center;

  const _ColumnWindow(this.min, this.max, this.center);
}

/// 同一直行判定の dy 許容幅（正規化座標）。
///
/// WHY: 実データの真のペアは dy ≦ 0.004 に収まる一方、隣接行（BAD 行と
/// GREAT 行）のラベル中心差は ≈0.014 しかない。0.012 は真ペアを全て受け、
/// 隣行値を dy だけで排除しきれないケースは列窓（dx）で排除する方針
/// （stats §7⑤「先に列を確定させてから値を取る」）。
const double _sameRowTolerance = 0.012;

/// ラベル別の列窓（hc_v1 / プレーシェア共有画像 基準）。
const Map<NumericFieldKind, _ColumnWindow> _hcV1Windows = {
  // 観測 dx: 0.2529〜0.2538（GT 8/9 例）。
  NumericFieldKind.score: _ColumnWindow(0.20, 0.30, 0.2533),
  // 観測 dx: 0.1229〜0.1436（COOL/GREAT/GOOD 共通列・GT 18 例）。
  NumericFieldKind.cool: _ColumnWindow(0.05, 0.20, 0.1333),
  NumericFieldKind.great: _ColumnWindow(0.05, 0.20, 0.1333),
  NumericFieldKind.good: _ColumnWindow(0.05, 0.20, 0.1333),
  // 観測 dx: 0.1883〜0.1904（BAD 値はラベルの右側・GT 3 例）。
  // WHY 右側: stats §4.2 の「BAD dx −0.11」は左隣（GREAT 値）を誤対応した
  // 偽ペアであり、GT 照合で BAD 値は右側 +0.19 と確認済み。
  NumericFieldKind.bad: _ColumnWindow(0.10, 0.25, 0.19),
  // 観測 dx: 0.1333〜0.1446（GT 9/9 例・COMBO 値はラベルの右側）。
  NumericFieldKind.maxCombo: _ColumnWindow(0.10, 0.25, 0.14),
};

/// ac_v1（アーケード実機結果画面）専用の列窓。
///
/// WHY: アーケード実機の結果画面はプレーシェア共有画像と列幾何が異なるため、
/// hc_v1 の _windows を流用せず ac_v1 専用の窓を持つ。以下の値は主群
/// 2048x1536 を基準とした見積もり値であり、Phase 7 の 30 枚一括実測で
/// 校正する（docs/arcade_photo_geometry_analysis_2026-11-23.md §4）。
///
/// FIXME(01a2060d Phase 7) 解消済み: 実測（ML Kit ラベル＋値位置）に基づき
/// min/max/center を再算出して反映済み（2026-11-23・30 枚実機計測）。
/// ac_v1 の列窓（ラベル基準の相対 dx 範囲）。
///
/// WHY 実測値と厳密幅: 30 枚実機計測の真同一行ペア（|dy|<=0.012）の dx 実測
/// min/max に将来写真分の余裕 ±0.01 を足した値。ランタイムの窓判定は
/// マージンを足さない厳密判定（window.min <= dx <= window.max）なので、
/// 実測全ペアを窓が直接カバーする必要がある。dx は写真フレーミング
/// （画面が写り込む割合）に不変なため、cy が写真間で大きくふれても成り立つ。
/// 計測ツール: tool/measure_ac_windows.dart（再校正は同ツールで再現可能）。
const Map<NumericFieldKind, _ColumnWindow> _acV1Windows = {
  // 実測 dx 範囲: score [0.1348,0.2056] cool [0.1252,0.1882]
  // great [0.1199,0.1770] good [0.1331,0.1926] bad [0.1389,0.2014]
  // maxCombo [0.1219,0.1736]。
  NumericFieldKind.score: _ColumnWindow(0.12, 0.22, 0.17),
  NumericFieldKind.cool: _ColumnWindow(0.11, 0.20, 0.155),
  NumericFieldKind.great: _ColumnWindow(0.11, 0.19, 0.15),
  NumericFieldKind.good: _ColumnWindow(0.12, 0.21, 0.165),
  NumericFieldKind.bad: _ColumnWindow(0.12, 0.22, 0.17),
  NumericFieldKind.maxCombo: _ColumnWindow(0.11, 0.19, 0.15),
};

/// アンカーのテキスト（大文字正規化済み）→ 種別。
///
/// WHY `MAX COMBO` も許容: 実データの行ラベルは「COMBO」だが（GT 設計事実）、
/// 将来の表記揺れに備え両方を受けると安全（リーダー指示。実データ 30 枚で
/// MAX COMBO 表記は 0 例のため、現状は COMBO のみが実効アンカー）。
const Map<String, NumericFieldKind> _anchorKinds = {
  'SCORE': NumericFieldKind.score,
  'COOL': NumericFieldKind.cool,
  'GREAT': NumericFieldKind.great,
  'GOOD': NumericFieldKind.good,
  'BAD': NumericFieldKind.bad,
  'COMBO': NumericFieldKind.maxCombo,
  'MAX COMBO': NumericFieldKind.maxCombo,
};

/// `GREAT143` のような「ラベル + 値」連結形のパターン。
final RegExp _greatMergedPattern = RegExp(
  r'^GREAT(\d+)$',
  caseSensitive: false,
);

/// OCR 対象のレイアウト種別。
///
/// hcV1: プレーシェア共有画像（hc_v1 アンカーパック・現行 _windows 基準）。
/// acV1: アーケード実機結果画面（ac_v1 アンカーパック・ac_v1 固有の列窓基準）。
/// livelyV1: PC 版 Lively のスコア画面写真（P 単位の行ブロック・統合 3 パス）。
///   この種別は [FieldExtractor] の窓を使わず `LivelyOcrRoute` が読む。
enum LayoutKind { hcV1, acV1, livelyV1 }

/// [OcrPageResult] から数値フィールドを抽出する。
class FieldExtractor {
  final LayoutKind layoutKind;

  const FieldExtractor({this.layoutKind = LayoutKind.hcV1});

  /// 寸法が未設定なら [ArgumentError]（extract と anchorPositionOf の共通契約）。
  ///
  /// WHY: 寸法なしでは正規化座標変換が不能で、沈黙して空の結果を返すと
  /// 呼び出し側のバグ（engine の寸法設定漏れ）が「全フィールド未抽出」と
  /// して隠蔽されてしまう。明示的な失敗の方が発見が早い。
  void _requireDims(OcrPageResult pageResult) {
    if (pageResult.imageWidth == null || pageResult.imageHeight == null) {
      throw ArgumentError(
        'OcrPageResult.imageWidth/imageHeight must be set by the engine '
        '(normalization requires image dimensions).',
      );
    }
  }

  /// [kind] のラベルアンカーの正規化中心座標を返す（未検出なら null）。
  ///
  /// WHY: Wave 2 のクロップ再 OCR（region_spec.dart）が全体 OCR のラベル
  /// 位置を領域算出の起点にする。アンカー判定規則（GREAT 連結形・
  /// 'MAX COMBO' 変種等）を抽出コアと 1 箇所に保つため private ロジックを
  /// 公開アクセサ経由で再利用する。アンカー重複時の選択も extract と同一
  /// （先勝ち・決定的）なので、クロップ領域と抽出結果の対応が崩れない。
  ({double cx, double cy})? anchorPositionOf(
    OcrPageResult pageResult,
    NumericFieldKind kind,
  ) {
    _requireDims(pageResult);
    final anchors = _collectAnchors(
      pageResult.elements,
      pageResult.imageWidth!.toDouble(),
      pageResult.imageHeight!.toDouble(),
    );
    final anchor = anchors[kind];
    if (anchor == null) {
      return null;
    }
    return (cx: anchor.cx, cy: anchor.cy);
  }

  /// [kind] の列窓（ラベル中心からの正規化 dx 範囲と中心）。
  ///
  /// WHY: クロップ再 OCR（region_spec.dart）は列窓よりやや広い x 範囲を
  /// クロップする。窓定数を 2 箇所で複製するとドリフトするため公開する。
  ({double min, double max, double center}) columnWindowOf(
    NumericFieldKind kind,
  ) {
    final windows = layoutKind == LayoutKind.acV1 ? _acV1Windows : _hcV1Windows;
    final window = windows[kind];
    if (window == null) {
      // WHY: レベルはラベルアンカーを持たない（"Lv.50" 系のプレフィックス
      // 付き読みのため列窓の概念がない）。クロップ領域は region_spec の
      // レベル専用算出（難易度アンカー基準）を使う。
      throw ArgumentError('No column window for $kind');
    }
    return (min: window.min, max: window.max, center: window.center);
  }

  /// [pageResult] の要素からフィールドを抽出する。
  ///
  /// 要素 bbox を正規化座標へ変換するため、[OcrPageResult.imageWidth] /
  /// [OcrPageResult.imageHeight] が必須（engine が decode 時に設定する
  /// 単一情報源。WHY: 呼び出し側が別途画像を decode して寸法を渡す
  /// 二重管理を避ける）。
  ///
  /// 寸法が未設定の [OcrPageResult] を渡した場合は [ArgumentError] を
  /// 投げる。WHY: 寸法なしでは正規化座標変換が不能で、沈黙して空の結果を
  /// 返すと呼び出し側のバグ（engine の寸法設定漏れ）が「全フィールド未
  /// 抽出」として隠蔽されてしまう。明示的な失敗の方が発見が早い。
  FieldExtractionResult extract(OcrPageResult pageResult) {
    _requireDims(pageResult);
    final width = pageResult.imageWidth!.toDouble();
    final height = pageResult.imageHeight!.toDouble();
    final anchors = _collectAnchors(pageResult.elements, width, height);
    // 全アンカーを最初に確保済みにする（連結形 GREAT143 が他ラベルの
    // 値候補として再利用されないようにするため）。
    final claimed = anchors.values.map((a) => a.element).toSet();

    final fields = <NumericFieldKind, ExtractedField>{};
    for (final kind in NumericFieldKind.values) {
      final anchor = anchors[kind];
      if (anchor == null) {
        continue; // 未抽出: アンカーなし（レベル等は Wave 2 対象）。
      }
      final extracted = anchor.embeddedValue != null
          ? _fieldFromMergedAnchor(anchor)
          : _fieldFromWindow(
              kind,
              anchor,
              pageResult.elements,
              claimed,
              width,
              height,
            );
      if (extracted != null) {
        fields[kind] = extracted;
      }
    }
    return FieldExtractionResult(
      numericFields: fields,
      sourceElementCount: pageResult.elements.length,
    );
  }

  /// クロップ再 OCR（Wave 2）の結果で [extract] の結果を補強する。
  ///
  /// [regionResults] は [RegionOcrRunner] の結果のうち数値系のみを渡す。
  /// songTitle は数値種別ではないため無視される（WHY: 曲名の生値は ST-5 照合
  /// フェーズの対象）。レベルは byName でマージされ、クロップ OCR の
  /// 読み（LU50. 等）を _parseLevelValue + 1..50 バリデーションで採用する。
  ///
  /// マージ規則（WHY）: 全体 OCR はラベル文脈（同一行・列窓）つきで確実性
  /// が高い。クロップ側の役目は「全体で取れなかったものの補完」なので、
  /// 全体で有効な値は上書きしない。例外はスコアの落字（4 桁）で、クロップ
  /// 側が 5 桁の有効値ならクロップを採用する（落字復帰）。
  ///
  /// クロップ由来フィールドの boundingBox はクロップ座標系のまま
  /// （WHY: FR-3 は値・生値・信頼度のみを使用する。元画像座標への再投影は
  /// デバッグ表示が必要になった時点で行う）。
  FieldExtractionResult extractWithRegions(
    OcrPageResult pageResult,
    Map<RegionTarget, OcrPageResult> regionResults,
  ) {
    final merged = extract(pageResult);
    final fields = Map<NumericFieldKind, ExtractedField>.of(
      merged.numericFields,
    );
    for (final kind in NumericFieldKind.values) {
      // WHY byName: 数値 7 種は RegionTarget と名前が一致する（共有語彙）。
      final crop = regionResults[RegionTarget.values.byName(kind.name)];
      if (crop == null) {
        continue;
      }
      final full = fields[kind];
      final replacement = _fieldFromCrop(crop, kind);
      if (replacement == null || !_shouldReplace(kind, full, replacement)) {
        continue;
      }
      fields[kind] = replacement;
    }
    return FieldExtractionResult(
      numericFields: fields,
      sourceElementCount: merged.sourceElementCount,
    );
  }

  /// クロップ値で全体値を置き換えるかどうか（[extractWithRegions] の規則）。
  bool _shouldReplace(
    NumericFieldKind kind,
    ExtractedField? full,
    ExtractedField cropField,
  ) {
    if (full == null || !full.isValid) {
      return true; // 全体で未検出/無効 → 補完。
    }
    return kind == NumericFieldKind.score &&
        cropField.value >= 10000 &&
        full.value < 10000; // 落字（4 桁）→ 5 桁復帰。
  }

  /// クロップ結果から最良の数値候補を 1 つ選ぶ。
  ///
  /// WHY: クロップ内にはラベルがない（アンカー方式が使えない）ため、
  /// 正規化 + 検証を通った要素から決定的な優先順で 1 つ選ぶ:
  /// 桁数が多い（= 落字でない完全読み） > 信頼度が高い（不明は最後） > 左。
  ExtractedField? _fieldFromCrop(OcrPageResult crop, NumericFieldKind kind) {
    _requireDims(crop);
    final cropWidth = crop.imageWidth!.toDouble();
    ExtractedField? best;
    for (final element in crop.elements) {
      final value = kind == NumericFieldKind.level
          ? _parseLevelValue(element.text)
          : _parseCropNumericValue(element.text, kind);
      if (value == null) {
        continue;
      }
      final (isValid, _) = _validate(kind, value);
      if (!isValid) {
        continue;
      }
      final candidate = ExtractedField(
        kind: kind,
        value: value,
        rawText: element.text,
        confidence: element.hasUnknownConfidence
            ? OcrElement.confidenceUnknown
            : element.confidence,
        boundingBox: element.boundingBox,
        isValid: true,
      );
      if (best == null || _isBetterCropCandidate(candidate, best, cropWidth)) {
        best = candidate;
      }
    }
    return best;
  }

  /// クロップ候補の優先比較（_fieldFromCrop の doc 参照）。
  bool _isBetterCropCandidate(
    ExtractedField candidate,
    ExtractedField best,
    double cropWidth,
  ) {
    final candidateDigits = candidate.value.toString().length;
    final bestDigits = best.value.toString().length;
    if (candidateDigits != bestDigits) {
      return candidateDigits > bestDigits;
    }
    if (candidate.confidence != best.confidence) {
      return candidate.confidence > best.confidence;
    }
    return _centerX(candidate.boundingBox, cropWidth) <
        _centerX(best.boundingBox, cropWidth);
  }

  /// ラベルアンカーを検出する（同一種別の重複は先勝ち・読み取り順の保証が
  /// ないため決定的にする）。
  Map<NumericFieldKind, _Anchor> _collectAnchors(
    List<OcrElement> elements,
    double width,
    double height,
  ) {
    final anchors = <NumericFieldKind, _Anchor>{};
    for (final element in elements) {
      final normalized = element.text.trim().toUpperCase();
      final kind = _anchorKinds[normalized];
      if (kind != null) {
        anchors.putIfAbsent(
          kind,
          () => _Anchor(
            kind: kind,
            element: element,
            cx: _centerX(element.boundingBox, width),
            cy: _centerY(element.boundingBox, height),
          ),
        );
        continue;
      }
      final merged = _greatMergedPattern.firstMatch(normalized);
      if (merged != null) {
        anchors.putIfAbsent(
          NumericFieldKind.great,
          () => _Anchor(
            kind: NumericFieldKind.great,
            element: element,
            cx: _centerX(element.boundingBox, width),
            cy: _centerY(element.boundingBox, height),
            embeddedValue: int.tryParse(merged.group(1)!),
          ),
        );
      }
    }
    return anchors;
  }

  /// 連結形アンカー（`GREAT143`）から直接フィールドを組み立てる。
  ExtractedField? _fieldFromMergedAnchor(_Anchor anchor) {
    final value = anchor.embeddedValue;
    if (value == null) {
      return null;
    }
    final (isValid, message) = _validate(anchor.kind, value);
    return ExtractedField(
      kind: anchor.kind,
      value: value,
      rawText: anchor.element.text,
      confidence: anchor.element.confidence,
      boundingBox: anchor.element.boundingBox,
      isValid: isValid,
      validationMessage: message,
      evidence: [anchor.element],
    );
  }

  /// 列窓 + 同一直行で値要素を対応付けてフィールドを組み立てる。
  ExtractedField? _fieldFromWindow(
    NumericFieldKind kind,
    _Anchor anchor,
    List<OcrElement> elements,
    Set<OcrElement> claimed,
    double width,
    double height,
  ) {
    final window = (layoutKind == LayoutKind.acV1
        ? _acV1Windows
        : _hcV1Windows)[kind]!;
    OcrElement? best;
    var bestKey = double.infinity;
    for (final candidate in elements) {
      if (claimed.contains(candidate)) {
        continue;
      }
      final value = _parseNumericValue(candidate.text);
      if (value == null) {
        continue;
      }
      final dx = _centerX(candidate.boundingBox, width) - anchor.cx;
      final dy = _centerY(candidate.boundingBox, height) - anchor.cy;
      if (dx < window.min || dx > window.max || dy.abs() > _sameRowTolerance) {
        continue;
      }
      // 複数候補時は同一直行性（|dy|）→ 列中心近さの順で決定的に選ぶ。
      final key = dy.abs() * 10 + (dx - window.center).abs();
      if (key < bestKey) {
        bestKey = key;
        best = candidate;
      }
    }
    if (best == null) {
      return null; // 未抽出: 窓内に値要素なし（偽値を作らない）。
    }
    claimed.add(best);
    return _buildField(kind, anchor, best);
  }

  /// 値要素が確定した後の正規化・検証・信頼度計算。
  ExtractedField _buildField(
    NumericFieldKind kind,
    _Anchor anchor,
    OcrElement valueElement,
  ) {
    final value = _parseNumericValue(valueElement.text)!;
    final (isValid, message) = _validate(kind, value);
    var confidence = _averageConfidence([anchor.element, valueElement]);
    // 4 桁スコアは末尾落字の疑い（GT クロスチェック 96401→9640）なので
    // 信頼度を減衰して呼び出し側に不審さを伝える。
    if (kind == NumericFieldKind.score && value < 10000) {
      confidence = confidence == OcrElement.confidenceUnknown
          ? confidence
          : confidence * 0.5;
    }
    return ExtractedField(
      kind: kind,
      value: value,
      rawText: valueElement.text,
      confidence: confidence,
      boundingBox: valueElement.boundingBox,
      isValid: isValid,
      validationMessage: message,
      evidence: [anchor.element, valueElement],
    );
  }

  /// 値テキストを整数へ正規化する。数値として解釈できないなら null。
  ///
  /// - 全角数字 → 半角
  /// - 区切り文字（`,` `，` 半角/全角空白）→ 除去
  /// - 非数字 1 文字まで許容: `O/o/B/b`→0, `l/I`→1, その他（ドット含む）は除去
  ///   （`9500O` → 95000、`4.6` → 46、`6926B` → 69260。2 文字以上は `BO` の
  ///   ような誤読偽値防止のため拒否）
  ///   WHY B→0 追加（2026-11-22）: Wave 2 の 30 枚計測でスコアの 5 桁目
  ///   （輪郭 0）が `B` に誤読されるケースを確認（`6926B`/`9915B`/
  ///   `8985B`/`9320B`）。O→0 と同種の字形誤読として置換する。
  ///   【訂正・2026-11-23】上記 4 例の生テキストは ac ハイスコア写真 30 枚
  ///   （ac_hc_batch_results.json）には存在せず、プレーシェア領域再 OCR
  ///   計測（playshare_region_ocr_results.json）の読み。末尾 B→0 は両画面
  ///   共通の実測。
  ///   WHY ac 限定の 1 文字復元（2026-11-23・ac GT 30 枚検証）: 実機写真では
  ///   判定数/MAX COMBO の桁が 1 文字だけ誤読される実測があり、ac GT 記入で
  ///   対応先を特定した（スコア式 score=(cool+0.7great+0.4good)×100000÷
  ///   譜面総ノーツ（切り捨て）の逆算分母が同一譜面の複数写真間で一致する
  ///   ことで値を検証済み）:
  ///   - 先頭 B→3: `B8`→38 / `B90`→390 / `B33`→333 / `B0`→30×2 の 5 例。
  ///   - S→5: `S5`→55。Y→4: `Y84`→484 / `Y6`→46。
  ///   プレーシェア画面では先頭 B はノイズ（領域再 OCR の `B7147` 等は値から
  ///   除去が実測・region_merge_fixture_test 凍結）で画面字形が違うため、
  ///   hcV1 の挙動は変えず layoutKind で分岐する。末尾・中間 B は両画面とも
  ///   0（上の表）。小文字 `s/y`・ひらがな（`り`→4 候補・`も`→6 候補）は
  ///   実測 1 例以下のため未導入（次ウェーブ候補として記録）。
  ///   WHY 元テキストに数字を 1 つも含まない読みの拒否: 判定ラベルの末尾
  ///   （"GOOD" の D 等）がクロップに混入しただけの `B` 単独が、B→0 置換
  ///   によって偽値 0 になるのを防ぐ（`0` 単独の真の読みは数字を含むので
  ///   影響しない）。
  ///   WHY ドット除去: ドットは OCR ノイズとして除去する正規化を種別に
  ///   よらず一律で許容する（KISS・ユーザー見解）。
  ///   【訂正・2026-11-22】当初この正規化の動機例として挙げていた「4.6」
  ///   という読みは設定ブロック（HI-SPEED 欄）の値でレベルの読みでは
  ///   なかった（リーダー確認・fb599cb §4 l558-587）。種別によらない
  ///   一般ノイズ除去ルールという位置づけは変わらないため本正規化は維持。
  ///   「4.」で切れる部分読み（4→誤値）は Wave 2 測定済み（クロップ空で
  ///   レベル帯と判定 — _parseLevelValue を参照）。
  int? _parseNumericValue(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      var ch = rune;
      if (ch >= 0xFF10 && ch <= 0xFF19) {
        ch -= 0xFEE0; // 全角数字 → 半角。
      }
      buffer.writeCharCode(ch);
    }
    var text = buffer
        .toString()
        .replaceAll(',', '')
        .replaceAll('，', '')
        .replaceAll(' ', '')
        .replaceAll('　', '');
    // WHY: 置換前の段階で数字を 1 つも含まないかを判定する
    // （置換で数字が生えても採用条件にはならない）。
    final hasOriginalDigit = RegExp(r'[0-9]').hasMatch(text);
    final nonDigits = text.replaceAll(RegExp(r'[0-9]'), '');
    if (nonDigits.length > 1) {
      return null;
    }
    if (nonDigits.length == 1) {
      const substitutions = {
        'O': '0',
        'o': '0',
        'B': '0',
        'b': '0',
        'l': '1',
        'I': '1',
      };
      // WHY ac 限定の 1 文字復元（2026-11-23・ac GT 30 枚検証）: 先頭 B→3 /
      // S→5 / Y→4 は ac ハイスコア画面での実測対応（doc コメント参照）。
      // プレーシェア画面の先頭 B はノイズのため hcV1 の挙動は変更しない。
      final isAc = layoutKind == LayoutKind.acV1;
      if (isAc && nonDigits == 'B' && text.startsWith('B')) {
        text = text.replaceFirst('B', '3');
      } else if (isAc && nonDigits == 'S') {
        text = text.replaceFirst('S', '5');
      } else if (isAc && nonDigits == 'Y') {
        text = text.replaceFirst('Y', '4');
      } else {
        final substitution = substitutions[nonDigits];
        text = substitution != null
            ? text.replaceFirst(nonDigits, substitution)
            : text.replaceAll(nonDigits, '');
      }
    }
    if (text.isEmpty || !hasOriginalDigit) {
      return null;
    }
    return int.tryParse(text);
  }

  /// クロップ文脈の値パース（[extractWithRegions] 専用）。
  ///
  /// 1 文字正規化（[_parseNumericValue]）を先に試し、不成立のとき ac_v1 に
  /// 限り 2 文字語彙復旧（[_parseNumericValueTwoCharI0]）を試す。
  ///
  /// WHY 主経路（extract）に 2 文字復旧を適用しない: 全体 OCR の要素海では
  /// ノイズ読みが日常的に現れ、あいまいな語彙復旧は偽値の入口になる（stats §3
  /// の「あいまい照合は偽アンカーを生む」方針の値パース版）。クロップは列窓
  /// で絞られた小領域の再認識結果であり誤値の混入面が狭いため、Wave-2 専用で
  /// 許す（ユーザー裁定「Q2: ポスト処理必要」の実装・タスク 01a2065a）。
  ///
  /// WHY score の 0 値をクロップで採用しない（2026-11-22・run-2 計測）:
  /// HV8q_4WaEAEbLHQ の score 表示の部分読み `000` が 1 文字正規化で値 0 に
  /// なり検証範囲（0..100000）を通過して偽値を採用した（真値 100000 は全体
  /// 要素 `IO0000` に存在）。実測コーパス 30 枚のスコア分布は 5〜6 桁
  /// （最小 99802）で 0 点は不在。score の 0 はクロップ経路では拒否し、
  /// 真の 0 点の抽出は全体 OCR 経路の責務に残す（誤値より null を優先する
  /// 方針の一貫・経路間の役割分離）。score 以外の判定数/コンボは 0 が通常
  /// 表示のため拒否しない。
  int? _parseCropNumericValue(String raw, NumericFieldKind kind) {
    final value =
        _parseNumericValue(raw) ??
        (layoutKind != LayoutKind.acV1
            ? null
            : _parseNumericValueTwoCharI0(raw));
    if (value == null) {
      return null;
    }
    if (kind == NumericFieldKind.score && value == 0) {
      return null;
    }
    return value;
  }

  /// ac_v1 クロップ文脈専用の 2 文字語彙復旧（I→1・O→0）。
  ///
  /// 実測インスタンス: HV8q_4WaEAEbLHQ の score 値 `IO0000`（GT 100000）。
  /// ML Kit は 1 の縦棒を I、0 の輪郭を O と同一視する字形誤読で、1 文字版
  /// （O→0/I→1）と同種の誤読が 2 文字同時に起きた場合である
  /// （docs/ocr_ac_field_remeasurement_design_2026-11-23.md §4-5）。
  ///
  /// ガード（WHY 保守的側に倒す）:
  /// - 文字種は半角数字と大文字 I/O のみ（他の非数字は語彙外で即拒否。
  ///   小文字の字形的根拠は未測定のため語彙に入れない）
  /// - 元テキストに数字 3 桁以上を含む（`IO` のような数字なし読みや `IO5`
  ///   のような 1 桁読みはラベル片/ノイズの可能性が高いため。このゲートで
  ///   実質 score 専用になる: 判定数/コンボは 4 桁上限のため 2 文字の非数字
  ///   と 3 桁以上の元数字は両立しない）
  /// - 最終的な採用判定は [_fieldFromCrop] の種別検証範囲が行う
  int? _parseNumericValueTwoCharI0(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    var hasDigit = false;
    var hasSubstitution = false;
    for (final rune in text.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        hasDigit = true;
        continue;
      }
      if (rune == 0x49 || rune == 0x4F) {
        // 大文字 I / O。
        hasSubstitution = true;
        continue;
      }
      return null;
    }
    if (!hasDigit || !hasSubstitution) {
      return null;
    }
    final digitCount = text.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitCount < 3) {
      return null;
    }
    final substituted = text.replaceAll('I', '1').replaceAll('O', '0');
    return int.tryParse(substituted);
  }

  /// レベル値（"Lv.50" の誤読系テキスト）を整数へ正規化する。
  ///
  /// Wave 2 実測（30 枚計測・2026-11-22）でレベル領域のクロップからは
  /// `LU50.` / `LU39A` / `LUS0` / `LW.22` のような読みが返る
  /// （"Lv.50" 系の字形誤読。L は常に先頭・v/U/W は字形揺れ・末尾の
  /// A/ドットは装飾）。
  ///
  /// - 既知の字形揺れを先に数字へ置換（`S`→5・`B`→0・`O`→0・`I`→1）
  /// - 最初の数字連続のみ採用（`LU39A` → 39。末尾 A は装飾で 0 と区別
  ///   できないため以降を切る。`LW501` → 501 は 1〜50 外で検証が拒否）
  int? _parseLevelValue(String raw) {
    var text = raw.trim().toUpperCase();
    const substitutions = {'S': '5', 'B': '0', 'O': '0', 'I': '1'};
    text = text.split('').map((ch) => substitutions[ch] ?? ch).join();
    final match = RegExp(r'\d+').firstMatch(text);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(0)!);
  }

  /// 種別ごとの検証範囲（spec.md §4.1）。
  ///
  /// WHY: スコアは PM のハッシュタグ表記上限 100000、判定数とコンボは
  /// 実データが最大 4 桁（ゼロ埋め 0030 等）であるため 0〜9999。
  /// レベルは 1〜50 の整数（2026-11-21 ユーザー確認・クロップ再 OCR 専用）。
  (bool, String?) _validate(NumericFieldKind kind, int value) {
    final (min, max) = switch (kind) {
      NumericFieldKind.score => (0, 100000),
      NumericFieldKind.level => (1, 50),
      _ => (0, 9999),
    };
    if (value < min || value > max) {
      return (false, '$value は許容範囲 [$min, $max] 外');
    }
    return (true, null);
  }

  /// 根拠要素の confidence 平均。不明（センチネル）が混ざれば不明を返す。
  double _averageConfidence(List<OcrElement> elements) {
    var total = 0.0;
    for (final element in elements) {
      if (element.hasUnknownConfidence) {
        return OcrElement.confidenceUnknown;
      }
      total += element.confidence;
    }
    return total / elements.length;
  }

  double _centerX(Rect rect, double width) =>
      (rect.left + rect.right) / 2 / width;

  double _centerY(Rect rect, double height) =>
      (rect.top + rect.bottom) / 2 / height;
}
