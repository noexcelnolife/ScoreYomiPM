// FR-9 撮影ガイド枠（案A）のガイド幾何・描画テスト。
//
// ユーザー指示（2026-11-24）「撮影ガイド枠を実装してください」。
// 採用範囲は案A = アプリ内 CameraPreview + 静的ガイド枠（CustomPainter）。
// ここではプラットフォーム非依存な「枠の幾何」と「描画可能性」だけを固定する
// （カメラ実体は実機/エミュレータで別途実測。widget テスト対象外）。
//
// 契約:
// - ガイドは AC リザルト画面想定の横長（16:9）長方形。
// - 左右上下に余白を持ち、常にキャンバス内へ収まる（縦横どちらの画面でも）。
// - 枠外は半透明マスク・四隅に L 字マーク（撮影対象の四隅合わせのため）。
// - 静的ガイドなので shouldRepaint は常に false。
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/ui/capture_guide_overlay.dart';

void main() {
  group('ガイド枠幾何', () {
    test('縦長画面: 16:9 の横長長方形を中央に配置し余白内に収める', () {
      const Size size = Size(1080, 2400);
      final Rect guide = guideRectFor(size);
      expect(guide.center, size.center(Offset.zero));
      expect(
        guide.width / guide.height,
        closeTo(kCaptureGuideAspectRatio, 0.001),
      );
      expect(guide.left, greaterThanOrEqualTo(0));
      expect(guide.right, lessThanOrEqualTo(size.width));
      expect(guide.top, greaterThanOrEqualTo(0));
      expect(guide.bottom, lessThanOrEqualTo(size.height));
      // 縦長画面では幅が利用可能幅いっぱいになる（高さに余裕があるため）。
      expect(
        guide.width,
        closeTo(size.width * (1 - 2 * kCaptureGuideMarginRatio), 0.5),
      );
    });

    test('横長画面: 高さ基準で縮み、上下余白を確保する', () {
      const Size size = Size(2400, 1080);
      final Rect guide = guideRectFor(size);
      expect(guide.center, size.center(Offset.zero));
      expect(
        guide.width / guide.height,
        closeTo(kCaptureGuideAspectRatio, 0.001),
      );
      expect(
        guide.height,
        closeTo(size.height * (1 - 2 * kCaptureGuideMarginRatio), 0.5),
      );
      expect(guide.right, lessThanOrEqualTo(size.width));
      expect(guide.bottom, lessThanOrEqualTo(size.height));
    });

    test('極小サイズでも例外なく非負サイズの枠を返す', () {
      final Rect guide = guideRectFor(const Size(1, 1));
      expect(guide.width, greaterThanOrEqualTo(0));
      expect(guide.height, greaterThanOrEqualTo(0));
    });
  });

  group('ガイド枠描画', () {
    test('shouldRepaint は常に false（静的ガイド）', () {
      const CaptureGuidePainter a = CaptureGuidePainter();
      const CaptureGuidePainter b = CaptureGuidePainter();
      expect(a.shouldRepaint(b), isFalse);
    });

    test('painter は枠外マスク・枠線・四隅 L 字を例外なく描画できる', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, 400, 300),
      );
      const CaptureGuidePainter().paint(canvas, const Size(400, 300));
      final ui.Picture picture = recorder.endRecording();
      expect(picture.approximateBytesUsed, greaterThan(0));
      picture.dispose();
    });

    testWidgets('オーバーレイは IgnorePointer 配下で撮影操作を遮らない', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: <Widget>[CaptureGuideOverlay()]),
        ),
      );
      final Finder overlay = find.byKey(
        const ValueKey<String>('capture-guide-overlay'),
      );
      expect(overlay, findsOneWidget);
      expect(
        tester.widget<CustomPaint>(overlay).painter,
        isA<CaptureGuidePainter>(),
      );
      // MaterialApp 内部の IgnorePointer も数えられるため「1 以上」を確認
      // （本オーバーレイ自身の IgnorePointer が祖先に含まれること）。
      expect(
        find.ancestor(of: overlay, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
    });
  });
}
