import 'package:material_ui/material_ui.dart';

/// ガイド枠の縦横比（AC リザルト画面想定の横長長方形）。
///
/// WHY 16:9: AC のリザルト画面は横長（16:9 系）で、プレーシェア画像も
/// その比率で切り出される。撮影時に同じ比率で枠へ収めれば、後段の
/// RollCorrector（傾き補正・約 3〜4 秒/枚）の発動頻度と台形歪みが減る
/// （FR-9 案A の目的。パース補正そのものは §10.2 の将来フェーズ）。
const double kCaptureGuideAspectRatio = 16 / 9;

/// ガイド枠の画面端からの余白比率（枠を端に密着させず、指の操作余地を残す）。
const double kCaptureGuideMarginRatio = 0.06;

/// 与えられたキャンバスに収まるガイド枠矩形を返す（中央配置）。
///
/// 横長 16:9 を基本に、縦長画面では幅基準・横長画面では高さ基準で
/// 収まる側を採用する（＝はみ出さない）。余白は全周に [marginRatio] を確保。
Rect guideRectFor(
  Size size, {
  double marginRatio = kCaptureGuideMarginRatio,
  double aspectRatio = kCaptureGuideAspectRatio,
}) {
  final double maxWidth = size.width * (1 - 2 * marginRatio);
  final double maxHeight = size.height * (1 - 2 * marginRatio);
  // WHY clamp: 極小キャンバス（テストの 1x1 等）でも負サイズを作らない。
  double width = maxWidth < 0 ? 0 : maxWidth;
  double height = width / aspectRatio;
  if (height > maxHeight) {
    height = maxHeight < 0 ? 0 : maxHeight;
    width = height * aspectRatio;
  }
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: width,
    height: height,
  );
}

/// 撮影ガイド枠の描画（枠外半透明マスク + 枠線 + 四隅 L 字マーク）。
///
/// WHY L 字: リザルト画面の四隅（スコア枠・判定枠）を合わせやすくするため、
/// 直線の枠より角の位置が読み取りやすい。WHY 静的: 案B（画像ストリームでの
/// エッジ検出）は将来フェーズのため、ここでは再描画不要の固定描画に留める。
class CaptureGuidePainter extends CustomPainter {
  const CaptureGuidePainter();

  /// 枠外を覆うマスク色（撮影対象の外周を落として枠内へ視線を集める）。
  static const Color _maskColor = Color(0x73000000);
  static const Color _frameColor = Color(0xE6FFFFFF);
  static const Color _cornerColor = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final Rect guide = guideRectFor(size);
    if (guide.isEmpty) {
      return;
    }

    // 枠外マスク（全面 − 枠内 の差分パス）。
    final Path outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(guide),
    );
    canvas.drawPath(outside, Paint()..color = _maskColor);

    // 枠線（細）+ 四隅 L 字（太）。
    canvas.drawRect(
      guide,
      Paint()
        ..color = _frameColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final double armLength = (guide.shortestSide * 0.08).clamp(10.0, 48.0);
    final Paint cornerPaint = Paint()
      ..color = _cornerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final List<List<Offset>> corners = <List<Offset>>[
      <Offset>[
        guide.topLeft,
        Offset(guide.left + armLength, guide.top),
        Offset(guide.left, guide.top + armLength),
      ],
      <Offset>[
        guide.topRight,
        Offset(guide.right - armLength, guide.top),
        Offset(guide.right, guide.top + armLength),
      ],
      <Offset>[
        guide.bottomLeft,
        Offset(guide.left, guide.bottom - armLength),
        Offset(guide.left + armLength, guide.bottom),
      ],
      <Offset>[
        guide.bottomRight,
        Offset(guide.right - armLength, guide.bottom),
        Offset(guide.right, guide.bottom - armLength),
      ],
    ];
    for (final List<Offset> corner in corners) {
      canvas.drawLine(corner[0], corner[1], cornerPaint);
      canvas.drawLine(corner[0], corner[2], cornerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CaptureGuidePainter oldDelegate) => false;
}

/// 撮影画面上に重ねるガイド枠オーバーレイ。
///
/// WHY IgnorePointer: ガイドは表示専用。下層のプレビュー・シャッター等の
/// 操作を遮ってはならない。
class CaptureGuideOverlay extends StatelessWidget {
  const CaptureGuideOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: CustomPaint(
        key: ValueKey<String>('capture-guide-overlay'),
        painter: CaptureGuidePainter(),
        child: SizedBox.expand(),
      ),
    );
  }
}
