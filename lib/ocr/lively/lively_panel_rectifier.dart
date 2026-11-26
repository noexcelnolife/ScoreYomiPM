import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// Lively のパネル切り出し + 傾き補正。
///
/// WHY: PC 画面の写真は ±5 度ほど傾いて撮られる。P 単位の行バンドは横一直線を
/// 前提にしているため、補正しないと右端で 1 行分ずれる（実測: 12P 幅で
/// 5 度 = 約 0.9P）。手順は `tool/lively_crop_rectify.dart` で計測に使った
/// ものと同じで、枠 + ロール + 等倍率のワープ（台形補正は既定 0）。
class LivelyPanelRectifier {
  const LivelyPanelRectifier({
    this.scale = 2.0,
    this.maxOutputSide = 3200,
    this.rollSearchDeg = 5.0,
    this.rollStepDeg = 0.25,
    this.rollSampleStep = 2,
  });

  /// パネルの拡大率。実測で 2 倍が最も当たった（3 倍は頭打ち）。
  final double scale;

  /// 出力の長辺上限。これ以上拡大しても当たらない（実測）。
  final int maxOutputSide;

  final double rollSearchDeg;
  final double rollStepDeg;
  final int rollSampleStep;

  /// [box] を切り出して傾きを直した画像を返す。作れなければ null。
  img.Image? rectify(img.Image photo, Rect box) {
    final clamped = _clampToImage(box, photo.width, photo.height);
    if (clamped == null) return null;
    final roll = estimateRoll(photo, clamped);
    final size = _outputSize(clamped);
    return _warp(photo, clamped, roll, size.width, size.height);
  }

  /// 文字行の水平方向の分散が最大になる角度（度）を返す。
  ///
  /// WHY: 行ごとの射影に山が立つ角度 = 文字行が水平になる角度。ラベルの
  /// 座標から直接求めるより、パネル全体の文字を使って安定する。
  double estimateRoll(img.Image photo, Rect box) {
    final clamped = _clampToImage(box, photo.width, photo.height);
    if (clamped == null) return 0;
    final rgb = _rgbBytes(photo);
    final columns = clamped.width.floor() ~/ rollSampleStep;
    final rows = clamped.height.floor() ~/ rollSampleStep;
    if (columns < 8 || rows < 8) return 0;
    final luminance = Int32List(columns * rows);
    final left = clamped.left.floor();
    final top = clamped.top.floor();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final px = math.min(left + x * rollSampleStep, photo.width - 1);
        final py = math.min(top + y * rollSampleStep, photo.height - 1);
        final i = (py * photo.width + px) * 3;
        luminance[y * columns + x] =
            (rgb[i] * 299 + rgb[i + 1] * 587 + rgb[i + 2] * 114) ~/ 1000;
      }
    }
    return _bestRoll(luminance, columns, rows);
  }

  double _bestRoll(Int32List luminance, int width, int height) {
    final threshold = _otsuThreshold(luminance);
    final centerX = (width - 1) / 2;
    final centerY = (height - 1) / 2;
    final bins = Float64List(height * 2 + width);
    var bestScore = -1.0;
    var bestAngle = 0.0;
    final steps = (rollSearchDeg / rollStepDeg).round();
    for (var step = -steps; step <= steps; step++) {
      final degrees = step * rollStepDeg;
      final radians = degrees * math.pi / 180;
      final cosA = math.cos(radians);
      final sinA = math.sin(radians);
      bins.fillRange(0, bins.length, 0);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          // 大津の閾値は「暗い側 <= t < 明るい側」の分割。ここで <= を使うと
          // 背景までインクに数えて射影が平坦になり、角度が決まらなくなる。
          if (luminance[y * width + x] <= threshold) continue;
          final rotated = (-(x - centerX) * sinA + (y - centerY) * cosA)
              .round();
          final bin = rotated + height;
          if (bin >= 0 && bin < bins.length) bins[bin] += 1;
        }
      }
      var score = 0.0;
      for (final value in bins) {
        score += value * value;
      }
      if (score > bestScore) {
        bestScore = score;
        bestAngle = degrees;
      }
    }
    return bestAngle;
  }

  /// 大津の閾値（輝度の 2 クラス分離が最大になる値）。
  int _otsuThreshold(Int32List values) {
    final histogram = Int32List(256);
    for (final v in values) {
      histogram[v.clamp(0, 255)] += 1;
    }
    final total = values.length;
    var sum = 0.0;
    for (var i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    var sumB = 0.0;
    var weightB = 0;
    var best = 0.0;
    var threshold = 0;
    for (var i = 0; i < 256; i++) {
      weightB += histogram[i];
      if (weightB == 0) continue;
      final weightF = total - weightB;
      if (weightF == 0) break;
      sumB += i * histogram[i];
      final meanB = sumB / weightB;
      final meanF = (sum - sumB) / weightF;
      final between = weightB * weightF * (meanB - meanF) * (meanB - meanF);
      if (between > best) {
        best = between;
        threshold = i;
      }
    }
    return threshold;
  }

  ({int width, int height}) _outputSize(Rect box) {
    var effective = scale;
    final maxSide = math.max(box.width, box.height) * effective;
    if (maxSide > maxOutputSide) {
      effective = maxOutputSide / math.max(box.width, box.height);
    }
    return (
      width: math.max(1, (box.width * effective).round()),
      height: math.max(1, (box.height * effective).round()),
    );
  }

  /// 枠の中心を軸に [rollDeg] だけ回した切り出し（逆写像 + 双一次補間）。
  img.Image? _warp(
    img.Image photo,
    Rect box,
    double rollDeg,
    int outW,
    int outH,
  ) {
    final rgb = _rgbBytes(photo);
    final radians = rollDeg * math.pi / 180;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    final cx = box.center.dx;
    final cy = box.center.dy;
    final out = Uint8List(outW * outH * 3);
    final w = photo.width;
    final h = photo.height;
    for (var v = 0; v < outH; v++) {
      final dy = ((v + 0.5) / outH - 0.5) * box.height;
      final sinDy = sinA * dy;
      final cosDy = cosA * dy;
      for (var u = 0; u < outW; u++) {
        final dx = ((u + 0.5) / outW - 0.5) * box.width;
        final sx = cx + dx * cosA - sinDy;
        final sy = cy + dx * sinA + cosDy;
        _sampleBilinear(rgb, w, h, sx, sy, out, (v * outW + u) * 3);
      }
    }
    return img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: out.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
  }

  /// 画像外は黒（0）で埋める。パネル外周の余白なので読取に影響しない。
  void _sampleBilinear(
    Uint8List rgb,
    int width,
    int height,
    double x,
    double y,
    Uint8List out,
    int offset,
  ) {
    final x0 = x.floor();
    final y0 = y.floor();
    if (x0 < 0 || y0 < 0 || x0 >= width - 1 || y0 >= height - 1) {
      final xi = x0.clamp(0, width - 1);
      final yi = y0.clamp(0, height - 1);
      final i = (yi * width + xi) * 3;
      out[offset] = rgb[i];
      out[offset + 1] = rgb[i + 1];
      out[offset + 2] = rgb[i + 2];
      return;
    }
    final fx = x - x0;
    final fy = y - y0;
    final i00 = (y0 * width + x0) * 3;
    final i10 = i00 + 3;
    final i01 = i00 + width * 3;
    final i11 = i01 + 3;
    for (var c = 0; c < 3; c++) {
      final top = rgb[i00 + c] * (1 - fx) + rgb[i10 + c] * fx;
      final bottom = rgb[i01 + c] * (1 - fx) + rgb[i11 + c] * fx;
      out[offset + c] = (top * (1 - fy) + bottom * fy).round().clamp(0, 255);
    }
  }

  Uint8List _rgbBytes(img.Image photo) {
    final source = photo.numChannels == 3
        ? photo
        : photo.convert(numChannels: 3);
    return source.getBytes(order: img.ChannelOrder.rgb);
  }

  Rect? _clampToImage(Rect box, int width, int height) {
    final rect = Rect.fromLTRB(
      math.max(0, box.left),
      math.max(0, box.top),
      math.min(width.toDouble(), box.right),
      math.min(height.toDouble(), box.bottom),
    );
    if (rect.width < 8 || rect.height < 8) return null;
    return rect;
  }
}
