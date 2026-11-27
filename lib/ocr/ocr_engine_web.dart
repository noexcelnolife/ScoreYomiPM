/// Web 向けの [OcrEngine] 生成口。
///
/// Web ビルドには ML Kit が無いため、「認識できないこと」を明示する実装を返す。
/// 呼び出し側（UI）は失敗を [OcrEngineException] として扱うので、ここでも同じ型で
/// 投げる。`UnimplementedError` のような Error を投げると、`on OcrEngineException`
/// の捕捉をすり抜けて赤画面になる。
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../models/ocr_models.dart';
import 'ocr_engine.dart';

/// 認識を提供しない Web 用エンジン。
class UnsupportedOcrEngine implements OcrEngine {
  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    throw OcrEngineException('OCR は Web 版では利用できません。');
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    throw OcrEngineException('領域 OCR は Web 版では利用できません。');
  }

  @override
  Future<void> dispose() async {}
}

/// 非対応エンジンを生成する（UI 側では事前に OCR の可否を判定している前提）。
OcrEngine createOcrEngine() => UnsupportedOcrEngine();
