// OcrEngine のテスト用フェイク。

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';

/// [OcrEngine] のテスト用フェイク。
///
/// [onRecognize] を渡すと recognize の戻り値・例外をテスト側で制御できる。
/// 未指定の場合は UnimplementedError（呼ばれるはずのないメソッド）。
class FakeOcrEngine implements OcrEngine {
  FakeOcrEngine({this.onRecognize, this.onRecognizeRegion});

  /// recognize の実装。null の場合は呼ばれた時点でテスト失敗扱い。
  final Future<OcrPageResult> Function(Uint8List encodedImageBytes)?
      onRecognize;

  /// recognizeRegion の実装。null の場合は呼ばれた時点でテスト失敗扱い。
  ///
  /// WHY: 再 OCR 経路の matchedSong 渡しテスト（ビルド検証テスト 修正①）で
  /// songTitle 帯の領域 OCR 応答が必要になった（パイプラインの曲照合は
  /// 領域 OCR の曲名帯結果を入力とするため、region 応答を返せないと
  /// matchedSong まで辿れない）。
  final Future<OcrPageResult> Function(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale,
    bool contrastRetry,
  })?
  onRecognizeRegion;

  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    final Future<OcrPageResult> Function(Uint8List encodedImageBytes)?
        callback = onRecognize;
    if (callback == null) {
      throw UnimplementedError('recognize は呼ばれる想定ではありません');
    }
    return callback(encodedImageBytes);
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    final Future<OcrPageResult> Function(
      Uint8List encodedImageBytes,
      Rect region, {
      required OcrScript script,
      double pixelScale,
      bool contrastRetry,
    })?
    callback = onRecognizeRegion;
    if (callback == null) {
      throw UnimplementedError('recognizeRegion は呼ばれる想定ではありません');
    }
    return callback(
      encodedImageBytes,
      region,
      script: script,
      pixelScale: pixelScale,
      contrastRetry: contrastRetry,
    );
  }

  @override
  Future<void> dispose() async {}
}
