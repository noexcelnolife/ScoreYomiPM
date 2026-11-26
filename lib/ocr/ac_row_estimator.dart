/// ac_v1 行推定フォールバック（01a2065a Q3 裁定・リード実装 2026-11-23）。
///
/// アーケード実機写真でラベル要素が ML Kit に検出されない/誤読される場合
/// （実測: HWxJNv の COOL=`CODL` 誤読・COMBO=`COMBO0` 連結）、ラベル
/// アンカーなしではクロップ再 OCR の領域を算出できず値が回復しない
/// （region_spec.dart の従来契約「アンカー未検出 = spec なし」）。
/// 本クラスは検出済みの他ラベル位置から、実測の隣接行デルタで対象ラベルの
/// 位置を推定する（チェーンウォーク）。
///
/// 実測根拠（tool/ac_row_deltas_output.txt・30 枚実機計測フィクスチャ）:
/// - 縦チェーン SCORE→BEST→COOL→GREAT→GOOD→BAD→COMBO の隣接行デルタ
///   （dCy/dCx・正規化座標）はバケット（主群 4:3 横 / 16:9 横）で系統的に
///   異なる（dCy ≈0.044 / ≈0.052-0.089）。単一の定数では推定できないため
///   バケット別表を持つ。ユーザー裁定「16:9 横 5 枚・4:3 縦 2 枚が canonical
///   seed からずれる」の実体はこの行間隔の差である（絶対位置オフセットでは
///   ない。WHY: オフセット係数による補正案は実測に基づかないため不採用）。
/// - 推定精度の実証例: HWxJNv の cool（GREAT 基準・実位置誤差 cy 0.0022 /
///   cx 0.0019）と maxCombo（BAD 基準・誤差 cy 0.0006 / cx 0.0004）。
///   test/ac_row_estimation_test.dart で凍結する。
///
/// WHY NCC パックアンカーを使わない（Q3 裁定の主軸）: 単一スケール NCC は
/// モーダル解像度 2048x1536 近傍でしか当たらず（4K 群ほぼ 0 ヒット）、
/// score ヒットの誤差中央値 205px（BEST 行の別 SCORE への誤着を含む）で
/// 信頼できる基準にならない（docs/ocr_ac_field_remeasurement_design_
/// 2026-11-23.md §6）。本推定は ML Kit テキストアンカー主経路の補完であり
/// NCC に依存しない。
///
/// WHY portrait を推定対象外にする: 行間 dCy ≈0.021 が行内容半高（≈0.010）
/// と同程度のため、推定誤差が隣行混入（=誤値採用）に直結する。標本 n=2 で
/// 行間余裕の検証もできず実例での必要性も未確認のため、実測が揃うまで除外
/// する（YAGNI・安全側）。
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:scoreyomipm/models/ocr_models.dart';

import 'field_extractor.dart';

/// 推定対象のアスペクト バケット。
///
/// WHY 3 分類のみ: 30 枚の実機写真は全てこの 3 分類に属する
/// （tool/ac_row_deltas_output.txt §bucket sizes: main43 23 / wide169 5 /
/// portrait 2）。other 帯（アスペクト 1.45-1.7 の中間等）は実例がなく、
/// 現れた時点で計測して拡張する。
enum _AspectBucket { main43, wide169, portrait }

/// 縦チェーンの 1 节点（ラベル文字列と対応する抽出種別）。
///
/// WHY BEST を含める: BEST は抽出対象フィールドではない
/// （NumericFieldKind に存在しない）が、score 推定の経由节点
/// （SCORE と COOL の間の行）になるためチェーンに含める。
@immutable
class _ChainNode {
  final String label;

  final NumericFieldKind? kind;

  const _ChainNode(this.label, this.kind);
}

/// 隣接行デルタ（下方向の行への dCy・dCx・正規化座標）。
@immutable
class _RowDelta {
  final double dCy;

  final double dCx;

  const _RowDelta(this.dCy, this.dCx);
}

/// 検出済みラベルから対象ラベルの位置を推定する。
class AcRowEstimator {
  const AcRowEstimator();

  /// 縦チェーン（上→下・実測レイアウト順）。
  static const List<_ChainNode> _chain = [
    _ChainNode('SCORE', NumericFieldKind.score),
    _ChainNode('BEST', null),
    _ChainNode('COOL', NumericFieldKind.cool),
    _ChainNode('GREAT', NumericFieldKind.great),
    _ChainNode('GOOD', NumericFieldKind.good),
    _ChainNode('BAD', NumericFieldKind.bad),
    _ChainNode('COMBO', NumericFieldKind.maxCombo),
  ];

  /// 主群 4:3 横（アスペクト [1.25, 1.45]）の隣接行デルタ
  /// （実測中央値・n=23。tool/measure_ac_row_deltas.dart で再現可能）。
  static const List<_RowDelta> _main43Deltas = [
    _RowDelta(0.0748, -0.0129), // SCORE→BEST
    _RowDelta(0.0632, 0.0281), // BEST→COOL
    _RowDelta(0.0444, 0.0078), // COOL→GREAT
    _RowDelta(0.0436, -0.0068), // GREAT→GOOD
    _RowDelta(0.0449, -0.0084), // GOOD→BAD
    _RowDelta(0.0443, 0.0160), // BAD→COMBO
  ];

  /// 16:9 横（アスペクト ≥ 1.7）の隣接行デルタ（実測中央値・n=5）。
  static const List<_RowDelta> _wide169Deltas = [
    _RowDelta(0.0893, -0.0112), // SCORE→BEST
    _RowDelta(0.0728, 0.0251), // BEST→COOL
    _RowDelta(0.0518, 0.0071), // COOL→GREAT
    _RowDelta(0.0514, -0.0054), // GREAT→GOOD
    _RowDelta(0.0541, -0.0079), // GOOD→BAD
    _RowDelta(0.0519, 0.0139), // BAD→COMBO
  ];

  /// [kind] のラベル位置を推定する（推定不能なら null）。
  ///
  /// 対象種別自身のアンカーが検出済みの場合は null（推定はアンカー不在時
  /// のみ意味を持つ・呼び出し側契約の防御）。参照アンカーが 1 つもない
  /// 場合も null（推定根拠がなく偽位置を出さない）。
  ({double cx, double cy, String reason})? estimate(
    OcrPageResult pageResult,
    NumericFieldKind kind,
    FieldExtractor extractor,
  ) {
    final width = pageResult.imageWidth;
    final height = pageResult.imageHeight;
    if (width == null || height == null) {
      return null; // 正規化座標の前提が崩れるため推定しない。
    }
    final bucket = _bucketOf(width, height);
    if (bucket == _AspectBucket.portrait) {
      return null;
    }
    final targetIndex = _chainIndex(kind);
    if (targetIndex == null) {
      return null; // level 等・チェーン外の種別。
    }
    if (extractor.anchorPositionOf(pageResult, kind) != null) {
      return null; // アンカー検出済み → 推定の必要がない。
    }
    final detected = _detectChainPositions(pageResult, extractor);
    if (detected.isEmpty) {
      return null;
    }
    final refIndex = _nearestDetectedIndex(detected, targetIndex);
    final (dCy, dCx) = _walkDelta(bucket, refIndex, targetIndex);
    final ref = detected[refIndex]!;
    final cx = ref.cx + dCx;
    final cy = ref.cy + dCy;
    // 判定欄は画面下部に存在する（実測の最上段 SCORE ラベルは cy 0.371 以上）。
    // これを外れる推定は参照誤りの疑いが強いため棄却する。
    if (cx < 0 || cx > 1 || cy < 0.3 || cy > 0.99) {
      return null;
    }
    return (
      cx: cx,
      cy: cy,
      reason:
          'chain walk from ${_chain[refIndex].label} '
          '(${bucket.name} bucket, dCy ${dCy.toStringAsFixed(4)}, '
          'dCx ${dCx.toStringAsFixed(4)})',
    );
  }

  /// 画像寸法からバケットを分類する。
  ///
  /// WHY 1.7 境界: 16:9 = 1.778 と主群上限 1.45 の間に実例のない隙間がある。
  /// 隙間（1.45-1.7）は主群側に倒す（推定デルタの誤差方向として安全側とは
  /// 断定できないが、実例が出るまでの暫定分類）。
  _AspectBucket _bucketOf(int width, int height) {
    if (height > width) {
      return _AspectBucket.portrait;
    }
    if (width / height >= 1.7) {
      return _AspectBucket.wide169;
    }
    return _AspectBucket.main43;
  }

  /// 種別のチェーン添字（チェーン外なら null）。
  int? _chainIndex(NumericFieldKind kind) {
    for (var i = 0; i < _chain.length; i++) {
      if (_chain[i].kind == kind) {
        return i;
      }
    }
    return null;
  }

  /// 検出済みアンカーのチェーン添字 → 正規化中心座標マップ。
  Map<int, ({double cx, double cy})> _detectChainPositions(
    OcrPageResult pageResult,
    FieldExtractor extractor,
  ) {
    final detected = <int, ({double cx, double cy})>{};
    for (var i = 0; i < _chain.length; i++) {
      final kind = _chain[i].kind;
      if (kind == null) {
        continue; // BEST は抽出種別を持たない（推定の参照にはならない）。
      }
      final position = extractor.anchorPositionOf(pageResult, kind);
      if (position != null) {
        detected[i] = position;
      }
    }
    return detected;
  }

  /// 検出済み添字のうち [targetIndex] に最も近いもの（同距離は添字の小さい
  /// 方を優先・決定的）。
  int _nearestDetectedIndex(
    Map<int, ({double cx, double cy})> detected,
    int targetIndex,
  ) {
    var bestIndex = -1;
    var bestDistance = -1;
    for (final index in detected.keys.toList()..sort()) {
      final distance = (index - targetIndex).abs();
      if (bestIndex == -1 || distance < bestDistance) {
        bestIndex = index;
        bestDistance = distance;
      }
    }
    return bestIndex;
  }

  /// チェーンを [from] から [to] まで歩いた累積デルタ（dCy・dCx）。
  ///
  /// WHY 隣接辺の積算のみ: 非隣接ペア（例: SCORE→COOL 直行）のデルタも
  /// 実測できるが、辺ごとのバケット差が積算で正しく伝わる隣接積算を採用
  /// （ 直行表は節点数の組合せで表が膨らむため KISS も兼ねる）。
  (double, double) _walkDelta(_AspectBucket bucket, int from, int to) {
    final deltas = bucket == _AspectBucket.wide169
        ? _wide169Deltas
        : _main43Deltas;
    var dCy = 0.0;
    var dCx = 0.0;
    final step = from < to ? 1 : -1;
    var index = from;
    while (index != to) {
      final edge = step == 1 ? deltas[index] : deltas[index - 1];
      dCy += step * edge.dCy;
      dCx += step * edge.dCx;
      index += step;
    }
    return (dCy, dCx);
  }
}
