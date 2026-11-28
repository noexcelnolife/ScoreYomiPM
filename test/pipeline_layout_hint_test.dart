// v3 種別選択フロー: OcrPipeline.run への layoutHint 受け口と不一致フラグの検証。
// 設計: docs/v3_input_source_flow_design_2026-11-23.md §2（ユーザー裁定済み 2026-11-23）。
// タスク: 01a20785-89a5（OCR-Core 着手中断のためリードが引き取り実装）。
//
// WHY 実在画像を使う: ST-1 分類（classify）は実ファイルの低解像度デコードで
// アスペクト比を測る。存在しないパスは _readBytesSafely が null を返し全件
// landscapePlayShare フォールバックになるため、hint 不一致の検証が成立しない。
// 分類が実測で確定済みの 3 クラスの代表画像を用いる:
// - landscapePlayShare: testimage/playshare/ の実画像 30 枚（≒1.5・回帰ガード済み）
// - portraitWithEmbedded: testimage/playshare/Screenshot_20261122-124336.png
//   （scr001・1080x2400・埋め込み直立）
// - arcadeResultFrame: testimage/AC-HC-photo/HE8eMwTb0AAwJOV.jpg（2048x1536・4:3）
//
// 不一致フラグの仕様（裁定 D「警告表示して処理継続・遮断しない」）:
//   期待レイアウト対応: landscapePlayShare→hcV1 / portraitWithEmbedded→hcV1
//   （前処理で埋め込み横写真に刈り出されるため）/ rotatedPortrait→hcV1 /
//   arcadeResultFrame→acV1。hint が期待レイアウトと異なるとき true。
//   hint 未指定時は常に false（共有インテント経由 = 現行挙動完全不変・裁定 A）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/input_preprocessing.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

import 'support/image_fixture_skip.dart';

/// 実ファイル寸法を返す最小 fake engine。
///
/// WHY: ST-4 は pageResult の寸法欠落時に領域 OCR・レイアウト決定ごとスキップ
/// するため、寸法を返さない fake では hint 経路の検証ができない。各呼び出しで
/// 渡されたファイル（full-page 画像と領域クロップの両方）を実デコードし、
/// 実寸法を返す。要素は空でよい（本テストの検証対象は layoutKind と不一致
/// フラグのみ・ML Kit 代替）。
class _SizeAwareFakeEngine extends OcrEngine {
  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    final bytes = encodedImageBytes;
    final image = img.decodeImage(bytes);
    return OcrPageResult(
      elements: const [],
      fullText: '',
      // WHY: デコード失敗時も null 寸法で返す（ST-4 の寸法欠落スキップ経路に
      // 合流する。分類は完了しているため hint 関連フィールドは検証可能）。
      imageWidth: image?.width,
      imageHeight: image?.height,
    );
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    ui.Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    final bytes = encodedImageBytes;
    final image = img.decodeImage(bytes);
    return OcrPageResult(
      elements: const [],
      fullText: '',
      imageWidth: image?.width,
      imageHeight: image?.height,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// 分類代表画像の一覧（上記の WHY コメントの分類根拠と対応）。
final Map<String, InputImageClass> _classRepresentatives = {
  // playshare 実画像 30 枚は全件 landscapePlayShare（回帰ガード実績）。
  'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg':
      InputImageClass.landscapePlayShare,
  'testimage/AC-HC-photo/HE8eMwTb0AAwJOV.jpg':
      InputImageClass.arcadeResultFrame,
  'testimage/playshare/Screenshot_20261122-124336.png':
      InputImageClass.portraitWithEmbedded,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 実画像が無い環境（公開リポジトリの clone など）では丸ごと skip する
  group('OcrPipeline.run layoutHint 受け口（01a20785-89a5）', () {
    test('hint=acV1 + 横長プレーシェア画像 → layoutKind acV1・不一致フラグ true', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File(
        'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg',
      );

      // Act
      final context = await pipeline.run(file.readAsBytesSync(),
        layoutHint: InputLayoutHint.acV1,
      );

      // Assert（hint 優先で acV1 が採用される・分類とは不一致）
      expect(context.layoutHint, InputLayoutHint.acV1);
      expect(context.layoutKind, LayoutKind.acV1);
      expect(context.layoutMismatchFlag, isTrue);
    });

    test('hint=hcV1 + 4:3 実機写真 → layoutKind hcV1・不一致フラグ true', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File('testimage/AC-HC-photo/HE8eMwTb0AAwJOV.jpg');

      // Act
      final context = await pipeline.run(file.readAsBytesSync(),
        layoutHint: InputLayoutHint.hcV1,
      );

      // Assert（hint 優先で hcV1・分類 arcadeResultFrame との不一致）
      expect(context.layoutHint, InputLayoutHint.hcV1);
      expect(context.layoutKind, LayoutKind.hcV1);
      expect(context.layoutMismatchFlag, isTrue);
    });

    test('hint=hcV1 + 横長プレーシェア画像 → layoutKind hcV1・不一致フラグ false', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File(
        'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg',
      );

      // Act
      final context = await pipeline.run(file.readAsBytesSync(),
        layoutHint: InputLayoutHint.hcV1,
      );

      // Assert（hint と分類の期待レイアウトが一致）
      expect(context.layoutHint, InputLayoutHint.hcV1);
      expect(context.layoutKind, LayoutKind.hcV1);
      expect(context.layoutMismatchFlag, isFalse);
    });

    test('hint=acV1 + 4:3 実機写真 → layoutKind acV1・不一致フラグ false', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File('testimage/AC-HC-photo/HE8eMwTb0AAwJOV.jpg');

      // Act
      final context = await pipeline.run(file.readAsBytesSync(),
        layoutHint: InputLayoutHint.acV1,
      );

      // Assert
      expect(context.layoutHint, InputLayoutHint.acV1);
      expect(context.layoutKind, LayoutKind.acV1);
      expect(context.layoutMismatchFlag, isFalse);
    });

    test('hint=null + 4:3 実機写真 → layoutKind acV1・不一致フラグ false（現行不変）', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File('testimage/AC-HC-photo/HE8eMwTb0AAwJOV.jpg');

      // Act
      final context = await pipeline.run(file.readAsBytesSync());

      // Assert（hint 未指定は分類由来のレイアウト・フラグは立たない）
      expect(context.layoutHint, isNull);
      expect(context.layoutKind, LayoutKind.acV1);
      expect(context.layoutMismatchFlag, isFalse);
    });

    test(
      'hint=null + 横長プレーシェア画像 → layoutKind hcV1・不一致フラグ false（現行不変）',
      () async {
        // Arrange
        final engine = _SizeAwareFakeEngine();
        final pipeline = OcrPipeline(engine: engine);
        final file = File(
          'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg',
        );

        // Act
        final context = await pipeline.run(file.readAsBytesSync());

        // Assert
        expect(context.layoutHint, isNull);
        expect(context.layoutKind, LayoutKind.hcV1);
        expect(context.layoutMismatchFlag, isFalse);
      },
    );

    test('hint=hcV1 + 縦スクショ（portraitWithEmbedded）→ 不一致フラグ false', () async {
      // Arrange
      final engine = _SizeAwareFakeEngine();
      final pipeline = OcrPipeline(engine: engine);
      final file = File('testimage/playshare/Screenshot_20261122-124336.png');

      // Act
      final context = await pipeline.run(file.readAsBytesSync(),
        layoutHint: InputLayoutHint.hcV1,
      );

      // Assert（前処理で埋め込み横写真に刈り出される前提のため期待 hcV1 → 一致）
      expect(context.layoutHint, InputLayoutHint.hcV1);
      expect(context.layoutKind, LayoutKind.hcV1);
      expect(context.layoutMismatchFlag, isFalse);
    });

    test('分類代表画像の存在確認（テスト前提の固定）', () {
      // WHY: 上記テストが特定実画像の分類実績に依存するため、ファイル存在を
      // 先に固定する（欠落時はこのテストが落ちて原因を切り分けられる）。
      for (final path in _classRepresentatives.keys) {
        expect(File(path).existsSync(), isTrue, reason: '欠落: $path');
      }
    });
  }, skip: skipIfImagesMissing(_classRepresentatives.keys));
}
