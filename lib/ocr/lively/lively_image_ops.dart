import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// 行ブロック / セルの前処理。
///
/// WHY（実測）: Lively のスコア行は白飛び（ブルーム）していて、輝度の
/// 二値化では数字の輪郭が潰れる。RGB の最大値を輝度として使うと、色付きの
/// 数字が背景より明るいまま残り、ML Kit が読めるようになる
/// （`docs/lively_extraction_pipeline_2026-11-25.md §2.1`）。
class LivelyImageOps {
  const LivelyImageOps._();

  /// 指定矩形を切り出し、高さ正規化と RGB 最大値での濃淡化を行う。
  ///
  /// [height] は出力の高さ（幅は縦横比を保って決まる）。ML Kit は文字の
  /// 絶対高さが小さいと検出漏れするため、ブロックは 900px・セルは 260px に
  /// 揃える（計測時と同じ）。縮小してから濃淡化するのは、画素あたりの
  /// 処理を減らすため（順序を入れ替えても結果は同じ）。
  static img.Image? cropEnhanced(img.Image source, Rect rect, int height) {
    final clamped = clipTo(source, rect);
    if (clamped == null) return null;
    final cropped = img.copyCrop(
      source,
      x: clamped.left.floor(),
      y: clamped.top.floor(),
      width: clamped.width.floor(),
      height: clamped.height.floor(),
    );
    final sized = height > 0 && cropped.height != height
        ? img.copyResize(
            cropped,
            height: height,
            interpolation: img.Interpolation.linear,
          )
        : cropped;
    return maxChannel(sized);
  }

  /// 矩形を画像内に収める。小さすぎる場合は null。
  static Rect? clipTo(img.Image source, Rect rect) {
    final clipped = Rect.fromLTRB(
      math.max(0, rect.left),
      math.max(0, rect.top),
      math.min(source.width.toDouble(), rect.right),
      math.min(source.height.toDouble(), rect.bottom),
    );
    if (clipped.width < 8 || clipped.height < 8) return null;
    return clipped;
  }

  /// 各画素を RGB 最大値の灰色にする（彩度を落としてコントラストを上げる）。
  static img.Image maxChannel(img.Image source) {
    final src = source.numChannels == 3
        ? source
        : source.convert(numChannels: 3);
    final bytes = src.getBytes(order: img.ChannelOrder.rgb);
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i += 3) {
      final value = math.max(bytes[i], math.max(bytes[i + 1], bytes[i + 2]));
      out[i] = value;
      out[i + 1] = value;
      out[i + 2] = value;
    }
    return img.Image.fromBytes(
      width: src.width,
      height: src.height,
      bytes: out.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
  }
}
