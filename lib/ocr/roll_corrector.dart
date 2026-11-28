// ST-1.5 ロール回転補正器（幾何補正 Phase 1・01a207fc）。
//
// 設計: docs/geometric_rectification_design_2026-11-23.md §3。Phase 0 実測
// （integration_test/ocr_geometric_degradation_test.dart）によりスケール耐性は
// 十分で、ロール回転のみが抽出劣化の主因と判明したため本クラスは回転のみを
// 扱う。
//
// 角度推定方式: 勾配方位ヒストグラム（文書スキュー補正の標準手法・純 Dart・
// 0.5 秒級）。既存 NCC 機構（ui_anchor.dart）を使った角度探索は候補角度ごとに
// canonical 解像度での回転と画像の再デコードが必要で 30 秒級になるため不採用。
//
// WHY 前段ブラー必須（2026-11-23 実測）: シャープな 1px エッジ（合成 PNG や
// JPEG の鮮鋭な罫線）では中心差分の dx がほぼ 0 になり、勾配方向に傾き情報が
// 載らない（サブピクセル位相は勾配方向へ現れない。実測では ±6°/±15° 傾きで
// ピークが δ≈0 に留まる二峰性ヒストグラムになった）。σ≈1 の平滑でエッジを
// 2-3px のランプにすると dx ≈ −2tanθ·g′ が成立し、勾配方向が厳密に法線方向
// （δ=θ）を指す。古典的文書デスキューでも前段平滑は標準手順。
//
// 角度契約: estimate が返す角度は「img.copyRotate(angle:) にそのまま渡して
// 正立化できる角度」。package:image の copyRotate(+θ) は内容を時計回りに回す
// （y 下向き画面座標で逆変換 x2 = ca·x + sa·y より順変換が +x→+y 方向）ので、
// copyRotate(θ) 傾きの画像の勾配法線は φ=90°+θ となり、返す角度は −θ になる。
// 符号は test/roll_corrector_test.dart の丸め込み（round-trip）テストで固定。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 角度推定結果。
class RollEstimate {
  /// 正立化に必要な copyRotate 角度（度・copyRotate(θ) 傾きに対し −θ）。
  final double angleDeg;

  /// 信頼度（ピーク近傍 ±[RollCorrector._confidenceWindowDeg] の質量比）。
  final double confidence;

  const RollEstimate({required this.angleDeg, required this.confidence});
}

/// ロール回転補正器（ST-1.5）。
///
/// ac_v1 経路（実機写真）の僅かな回転ずれを検出して正立化する。推定不能・
/// 無傾き・失敗のいずれでも呼び出し元に何もしない（fail-safe・遮断しない）。
class RollCorrector {
  /// これ未満の推定角度は補正しない閾値（度）。
  static const double correctThresholdDeg = 1.5;

  /// 推定用に縮小する作業コピーの最大幅（速度確保・精度は十分）。
  static const int _estimateMaxWidth = 512;

  /// 勾配強度の下限（弱エッジ=ノイズ・JPEG 圧縮劣化を除外）。
  static const double _minGradientMag = 20;

  /// ヒストグラムの範囲（±30°）と分解能（0.25°/ビン・240 ビン）。
  static const double _histRangeDeg = 30;
  static const double _binWidthDeg = 0.25;

  /// ヒストグラムのビン数（±30° ÷ 0.25°）。
  static const int _binCount = 240;

  /// 平滑化の半径（ビン数・5 ビン窓 = ±0.5°）。
  static const int _smoothRadius = 2;

  /// 信頼度の計測窓（ピークから ±2°）。
  static const double _confidenceWindowDeg = 2;

  /// 推定成立に必要な最小信頼度（窓質量比）。
  ///
  /// WHY 0.12: 一様ノイズの理論値は窓 4°/60° ≈ 6.7%（揺らぎ ±1% 程度）で
  /// 大きく下回り、支配的方位がある画像はこれを大きく上回る分離点。
  static const double _minConfidence = 0.12;

  /// 推定成立に必要な最小エッジ画素数。
  static const int _minEdgePixels = 300;

  /// 正立化対象の最大幅（長辺縮限・後段 OCR との整合）。
  static const int _uprightMaxWidth = 2048;

  /// ルーマ平面を一括抽出する（getPixel 反復を 1 パスに抑える）。
  Float64List _lumaPlane(img.Image work) {
    final w = work.width;
    final h = work.height;
    final luma = Float64List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = work.getPixel(x, y);
        luma[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }
    return luma;
  }

  /// ルーマ平面に 2 回の 3 タップ二項ブラー（[1,2,1]/4 の水平・垂直）を適用
  /// する（実効 σ ≈ 1.0）。
  ///
  /// WHY ブラー必須: ファイル先頭コメント参照（シャープ 1px エッジは勾配
  /// 方向に傾きを載せられないため、ランプ化が前提）。
  void _blur(Float64List luma, int w, int h) {
    final tmp = Float64List(w * h);
    for (var pass = 0; pass < 2; pass++) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final c = luma[y * w + x];
          final l = luma[y * w + (x > 0 ? x - 1 : 0)];
          final r = luma[y * w + (x < w - 1 ? x + 1 : w - 1)];
          tmp[y * w + x] = (l + 2 * c + r) / 4;
        }
      }
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final c = tmp[y * w + x];
          final u = tmp[(y > 0 ? y - 1 : 0) * w + x];
          final d = tmp[(y < h - 1 ? y + 1 : h - 1) * w + x];
          luma[y * w + x] = (u + 2 * c + d) / 4;
        }
      }
    }
  }

  /// 勾配方位ヒストグラムへ質量（勾配強度）を蓄積する。
  ///
  /// 戻り値は採用エッジ画素数。採用条件は「法線が垂直から ±30° 以内」=
  /// 水平エッジ寄りのみ（縦エッジ・斜め 45° エッジは除外）。
  ///
  /// WHY δ 基準で直接判定: 法線角 φ は 180° 周期なので |φ|>60° の帯域
  /// フィルタだけでは φ∈(120°,180°]（縦エッジ）が混入する。δ=φ−90°（φ≥0）
  /// または φ+90°（φ<0）として |δ|≤30° を判定すれば、同一エッジを逆向きに
  /// 計測しても同一 δ となりヒストグラムの wrap が不要になる。
  int _accumulateHistogram(Float64List luma, int w, int h, Float64List hist) {
    var edgePixels = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        // 中央差分勾配。
        final dx = luma[y * w + x + 1] - luma[y * w + x - 1];
        final dy = luma[(y + 1) * w + x] - luma[(y - 1) * w + x];
        final mag = math.sqrt(dx * dx + dy * dy);
        if (mag < _minGradientMag) {
          continue;
        }
        final phiDeg = math.atan2(dy, dx) * 180 / math.pi;
        final delta = phiDeg >= 0 ? phiDeg - 90 : phiDeg + 90;
        if (delta.abs() > _histRangeDeg) {
          continue;
        }
        edgePixels++;
        final bin = ((delta + _histRangeDeg) / _binWidthDeg).floor();
        hist[bin >= _binCount ? _binCount - 1 : bin] += mag;
      }
    }
    return edgePixels;
  }

  /// ヒストグラムを 5 ビン移動平均で平滑化する（端はクランプ）。
  Float64List _smoothed(Float64List hist) {
    final out = Float64List(_binCount);
    for (var i = 0; i < _binCount; i++) {
      var sum = 0.0;
      for (var k = -_smoothRadius; k <= _smoothRadius; k++) {
        var j = i + k;
        j = j < 0 ? 0 : (j >= _binCount ? _binCount - 1 : j);
        sum += hist[j];
      }
      out[i] = sum;
    }
    return out;
  }

  /// 平滑化後ヒストグラムのピークビン番号。
  int _peakBin(Float64List smoothed) {
    var peak = 0;
    for (var i = 1; i < _binCount; i++) {
      if (smoothed[i] > smoothed[peak]) {
        peak = i;
      }
    }
    return peak;
  }

  /// ピーク ±[_confidenceWindowDeg] 窓の生ヒストグラム質量比を返す。
  ///
  /// WHY 生ヒストグラムを使用: 平滑化は質量の再分配であり、窓質量比は
  /// 平滑化の前後でほぼ不変。生値で評価する方が解釈が単純。
  double _windowMassRatio(Float64List hist, int peak) {
    var windowMass = 0.0;
    var totalMass = 0.0;
    for (var i = 0; i < _binCount; i++) {
      totalMass += hist[i];
    }
    final windowBins = (_confidenceWindowDeg / _binWidthDeg).round();
    for (var k = -windowBins; k <= windowBins; k++) {
      final j = peak + k;
      if (j >= 0 && j < _binCount) {
        windowMass += hist[j];
      }
    }
    if (totalMass <= 0) {
      return 0;
    }
    return windowMass / totalMass;
  }

  /// [image] の支配的な回転ずれ角を推定する（無傾き ≈ 0・copyRotate 用角度）。
  ///
  /// 支配的方位が無い場合（ノイズ・無地・エッジ不足）は null を返す。
  RollEstimate? estimate(img.Image image) {
    // 推定は低解像度コピーで行う（速度確保・方位統計は十分保持）。
    var work = image;
    if (image.width > _estimateMaxWidth) {
      work = img.copyResize(
        image,
        width: _estimateMaxWidth,
        interpolation: img.Interpolation.average,
      );
    }
    final luma = _lumaPlane(work);
    // WHY 勾配前の平滑: シャープ 1px エッジのままでは dx≈0 で傾き信号が消失
    // するため（ファイル先頭コメント参照）。σ≈1 のランプ化で dx ≈ −2tanθ·g′
    // が成立し、勾配方向が法線方向（δ=θ）を指す。
    _blur(luma, work.width, work.height);

    final hist = Float64List(_binCount);
    final edgePixels = _accumulateHistogram(
      luma,
      work.width,
      work.height,
      hist,
    );
    if (edgePixels < _minEdgePixels) {
      return null;
    }

    final peak = _peakBin(_smoothed(hist));
    final confidence = _windowMassRatio(hist, peak);
    if (confidence < _minConfidence) {
      return null;
    }

    // ピークビン中心の δ（垂直法線からのずれ）。正立化角度は符号反転
    // （copyRotate(θ) 傾き → −θ。ファイル先頭の角度契約を参照）。
    final deltaPeak = (peak + 0.5) * _binWidthDeg - _histRangeDeg;
    return RollEstimate(angleDeg: -deltaPeak, confidence: confidence);
  }

  /// [sourceBytes] が傾いていれば正立化した JPEG バイト列を返す。
  ///
  /// 無傾き（|[RollEstimate.angleDeg]| < [correctThresholdDeg]）・推定不能・
  /// 失敗のいずれでも null を返し、呼び出し元は元の画像で続行する。
  ///
  /// WHY ファイルではなくバイト列を返すか: Web には `dart:io` が無い。戻り値を
  /// バイト列にすれば、呼び出し元が「受け取ったら消す」義務を負わない
  /// （一時ファイルの破棄漏れという失敗モード自体が無くなる）。
  Uint8List? maybeUpright(Uint8List sourceBytes) {
    try {
      final image = img.decodeImage(sourceBytes);
      if (image == null) {
        return null;
      }
      final estimate = this.estimate(image);
      if (estimate == null || estimate.angleDeg.abs() < correctThresholdDeg) {
        return null;
      }
      // 正立化対象は元解像度のまま長辺縮限（後段 OCR と同じ扱い）。
      var upright = image;
      if (image.width > _uprightMaxWidth) {
        upright = img.copyResize(
          image,
          width: _uprightMaxWidth,
          interpolation: img.Interpolation.average,
        );
      }
      final rotated = img.copyRotate(
        upright,
        angle: estimate.angleDeg,
        interpolation: img.Interpolation.cubic,
      );
      return img.encodeJpg(rotated, quality: 92);
    } catch (_) {
      // WHY fail-safe: 補正経路のいかなる失敗も現行動作（無補正）へフォール
      // バックさせる（設計 §3・遮断しない）。
      return null;
    }
  }
}
