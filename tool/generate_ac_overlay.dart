// ac_v1 canonical 座標のオーバーレイ画像生成（スポットチェック補助資料）。
//
// 目的: 実測校正値（tool/generate_ac_anchor_templates.dart・2026-11-23）を
// 実機写真の目視で確認できるようにする。
//
// 描画内容:
// - 緑枠  : テンプレ参照写真におけるラベル要素実測 bbox
// - 黄枠  : field_extractor.dart _acV1Windows の実測列窓
//           （アンカー cx + window・上下は cy ± 行許容 0.012）
// - シアン帯: frameRight 実測帯（x ∈ [0.80, 0.94]・全高）
//
// WHY: 幾何描画は生成 AI ではなく image パッケージの決定論的描画で行う
//（精密座標の可視化に生成モデルは不適）。

import 'dart:io';

import 'package:image/image.dart';

/// アンカー定義（実測校正・正規化座標）。
class _Anchor {
  const _Anchor(this.id, this.x, this.y, this.w, this.h, this.cx, this.cy);

  final String id;
  final double x;
  final double y;
  final double w;
  final double h;
  final double cx;
  final double cy;
}

/// tool/generate_ac_anchor_templates.dart の実測校正値（2026-11-23）と同一値。
/// bbox はテンプレ参照写真におけるラベル要素実測 bbox（2048x1536 基準）、
/// cx/cy は主群 4:3横バケット（23 枚）中央値 canonical。
const List<_Anchor> _anchors = [
  _Anchor('labelScore', 0.3691, 0.5254, 0.0645, 0.0202, 0.4028, 0.5365),
  _Anchor('labelBest', 0.3726, 0.6029, 0.0435, 0.0169, 0.3940, 0.6110),
  _Anchor('labelCool', 0.3911, 0.6569, 0.0557, 0.0215, 0.4180, 0.6673),
  _Anchor('labelGreat', 0.3911, 0.6973, 0.0684, 0.0202, 0.4250, 0.7122),
  _Anchor('labelGood', 0.3896, 0.7363, 0.0591, 0.0208, 0.4185, 0.7553),
  _Anchor('labelBad', 0.3887, 0.7760, 0.0444, 0.0228, 0.4103, 0.7975),
  _Anchor('labelCombo', 0.3882, 0.8184, 0.0732, 0.0215, 0.4246, 0.8411),
];

/// field_extractor.dart _acV1Windows の実測列窓（window.min/max・同一値）。
const Map<String, List<double>> _windows = {
  'labelScore': [0.12, 0.22],
  'labelCool': [0.11, 0.20],
  'labelGreat': [0.11, 0.19],
  'labelGood': [0.12, 0.21],
  'labelBad': [0.12, 0.22],
  'labelCombo': [0.11, 0.19],
};

/// 列窓の x 拡張量（実測窓に将来ヘッドルーム ±0.01 込みのため追加なし）。
const double _xMargin = 0.0;

/// 行許容（field_extractor.dart _sameRowTolerance のミラー）。
const double _yMargin = 0.012;

/// frameRight 実測帯（generate_ac_anchor_templates.dart の測定帯と同一）。
const double _frameRightX0 = 0.80;
const double _frameRightX1 = 0.94;

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/generate_ac_overlay.dart <photo> <outPng>',
    );
    exit(2);
  }
  _generate(args[0], args[1]);
  stdout.writeln('ok: ${args[1]}');
}

void _generate(String photoPath, String outPath) {
  final bytes = File(photoPath).readAsBytesSync();
  final image = decodeJpg(bytes);
  if (image == null) {
    stderr.writeln('decode failed: $photoPath');
    exit(1);
  }

  final w = image.width;
  final h = image.height;

  // frameRight 探索帯（シアン・全高）。
  drawRect(
    image,
    x0: (_frameRightX0 * w).round(),
    x1: (_frameRightX1 * w).round(),
    y0: 0,
    y1: h - 1,
    color: ColorRgb8(0, 180, 220),
    thickness: 3,
  );

  // ラベルアンカー探索枠（緑）＋列窓（黄）。
  for (final a in _anchors) {
    drawRect(
      image,
      x0: (a.x * w).round(),
      x1: ((a.x + a.w) * w).round(),
      y0: (a.y * h).round(),
      y1: ((a.y + a.h) * h).round(),
      color: ColorRgb8(0, 200, 60),
      thickness: 3,
    );
    final win = _windows[a.id];
    if (win == null) {
      continue;
    }
    final left = (a.cx + win[0] - _xMargin).clamp(0.0, 1.0) * w;
    final right = (a.cx + win[1] + _xMargin).clamp(0.0, 1.0) * w;
    final top = (a.cy - _yMargin).clamp(0.0, 1.0) * h;
    final bottom = (a.cy + _yMargin).clamp(0.0, 1.0) * h;
    drawRect(
      image,
      x0: left.round(),
      x1: right.round(),
      y0: top.round(),
      y1: bottom.round(),
      color: ColorRgb8(230, 200, 0),
      thickness: 3,
    );
  }

  File(outPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(encodePng(image));
}

/// 枠線を描く（fillRect を 4 辺に分解。thickness はピクセル数）。
void drawRect(
  Image image, {
  required int x0,
  required int x1,
  required int y0,
  required int y1,
  required ColorRgb8 color,
  required int thickness,
}) {
  fillRect(image, x0: x0, y0: y0, x1: x1, y1: y0 + thickness - 1, color: color);
  fillRect(image, x0: x0, y0: y1 - thickness + 1, x1: x1, y1: y1, color: color);
  fillRect(image, x0: x0, y0: y0, x1: x0 + thickness - 1, y1: y1, color: color);
  fillRect(image, x0: x1 - thickness + 1, y0: y0, x1: x1, y1: y1, color: color);
}

void fillRect(
  Image image, {
  required int x0,
  required int y0,
  required int x1,
  required int y1,
  required ColorRgb8 color,
}) {
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      if (x >= 0 && x < image.width && y >= 0 && y < image.height) {
        image.setPixel(x, y, color);
      }
    }
  }
}
