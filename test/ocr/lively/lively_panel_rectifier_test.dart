// Lively パネル切り出し（ロール推定 + ワープ）の単体テスト。
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/ocr/lively/lively_panel_rectifier.dart';

/// 傾いた明るい帯を 5 本持つ合成画像（文字行の代わり）。
img.Image _bandImage({required double slopeDeg}) {
  const size = 400;
  const bandHeight = 12;
  const bands = 5;
  final image = img.Image(width: size, height: size, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(20, 20, 20));
  final slope = math.tan(slopeDeg * math.pi / 180);
  for (var x = 0; x < size; x++) {
    for (var band = 0; band < bands; band++) {
      final top = 60.0 + band * 60 + (x - size / 2) * slope;
      for (var dy = 0; dy < bandHeight; dy++) {
        final y = (top + dy).round();
        if (y < 0 || y >= size) continue;
        image.setPixelRgb(x, y, 230, 230, 230);
      }
    }
  }
  return image;
}

int _brightestRow(img.Image image) {
  var bestRow = 0;
  var bestCount = -1;
  for (var y = 0; y < image.height; y++) {
    var count = 0;
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      if (p.r > 128) count++;
    }
    if (count > bestCount) {
      bestCount = count;
      bestRow = y;
    }
  }
  return bestRow;
}

void main() {
  const rectifier = LivelyPanelRectifier();
  const box = Rect.fromLTRB(0, 0, 400, 400);

  group('estimateRoll', () {
    test('水平な帯なら 0 度', () {
      final roll = rectifier.estimateRoll(_bandImage(slopeDeg: 0), box);

      expect(roll, closeTo(0, 0.3));
    });

    test('+3 度傾いた帯は +3 度と推定する', () {
      final roll = rectifier.estimateRoll(_bandImage(slopeDeg: 3), box);

      expect(roll, closeTo(3, 0.6));
    });

    test('-4 度傾いた帯は -4 度と推定する', () {
      final roll = rectifier.estimateRoll(_bandImage(slopeDeg: -4), box);

      expect(roll, closeTo(-4, 0.6));
    });

    test('小さすぎる枠では推定しない（0 を返す）', () {
      final roll = rectifier.estimateRoll(
        _bandImage(slopeDeg: 3),
        const Rect.fromLTRB(0, 0, 4, 4),
      );

      expect(roll, 0);
    });
  });

  group('rectify', () {
    test('2 倍のサイズで切り出す', () {
      final out = rectifier.rectify(_bandImage(slopeDeg: 0), box)!;

      expect(out.width, 800);
      expect(out.height, 800);
    });

    test('傾きを直して帯を水平に戻す', () {
      final out = rectifier.rectify(_bandImage(slopeDeg: 3), box)!;

      // 元画像の 1 本目の帯は中心 x で y=60 付近。回転補正後は全幅で
      // 同じ行に集まるので、最明行の明るい画素が幅の大半を占める。
      final row = _brightestRow(out);
      var count = 0;
      for (var x = 0; x < out.width; x++) {
        if (out.getPixel(x, row).r > 128) count++;
      }
      expect(count, greaterThan(out.width * 0.8));
    });

    test('長辺上限を超える拡大率は落とす', () {
      const limited = LivelyPanelRectifier(maxOutputSide: 400);
      final out = limited.rectify(_bandImage(slopeDeg: 0), box)!;

      expect(out.width, 400);
      expect(out.height, 400);
    });

    test('小さすぎる枠は null', () {
      expect(rectifier.rectify(_bandImage(slopeDeg: 0), Rect.zero), isNull);
    });
  });
}
