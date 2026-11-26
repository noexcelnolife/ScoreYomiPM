// Lively 経路のパイプライン配線（hint → 専用経路 → 共通の確認/登録）の検証。
//
// WHY 合成画像か: 実写真を回すと 2 倍パネルのワープで数秒かかり、この
// テストの目的（ヒントで livelyV1 に入り、領域 OCR を通らずに専用経路へ
// 渡ること）に対して過剰。分類値だけ実寸法から決まれば十分。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

/// どの呼び出しにも「行ラベルだけ」を返すフェイク（値は返さない）。
///
/// ラベルを渡された画像サイズに対する比で置くので、パネルへのワープ後でも
/// 基準点が必ず作れる（= 経路が最後まで進む）。
class _LabelFakeEngine implements OcrEngine {
  int recognizeCalls = 0;
  int regionCalls = 0;

  @override
  Future<OcrPageResult> recognize(File imageFile) async {
    recognizeCalls++;
    final image = img.decodeImage(await imageFile.readAsBytes());
    final width = (image?.width ?? 800).toDouble();
    final height = (image?.height ?? 600).toDouble();
    final left = width * 0.10;
    final labelWidth = width * 0.06;
    final labelHeight = height * 0.012;
    OcrElement label(String text, double centerY) => OcrElement(
      text: text,
      boundingBox: ui.Rect.fromLTRB(
        left,
        centerY - labelHeight / 2,
        left + labelWidth,
        centerY + labelHeight / 2,
      ),
      confidence: 0.9,
    );
    final elements = <OcrElement>[
      label('COOL', height * 0.40),
      label('GREAT', height * 0.45),
      label('GOOD', height * 0.50),
      label('BAD', height * 0.55),
    ];
    return OcrPageResult(
      elements: elements,
      fullText: 'COOL GREAT GOOD BAD',
      imageWidth: image?.width,
      imageHeight: image?.height,
    );
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    File imageFile,
    ui.Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    regionCalls++;
    return const OcrPageResult(elements: [], fullText: '');
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File image;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lively_pipeline_test_');
    image = File('${tempDir.path}${Platform.pathSeparator}lively.jpg');
    final photo = img.Image(width: 800, height: 600, numChannels: 3);
    img.fill(photo, color: img.ColorRgb8(25, 25, 25));
    image.writeAsBytesSync(img.encodeJpg(photo, quality: 90));
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('hint=livelyV1 で livelyV1 経路に入り、領域 OCR を通らない', () async {
    final engine = _LabelFakeEngine();
    final pipeline = OcrPipeline(engine: engine);

    final context = await pipeline.run(
      image,
      layoutHint: InputLayoutHint.livelyV1,
    );

    expect(context.layoutHint, InputLayoutHint.livelyV1);
    expect(context.layoutKind, LayoutKind.livelyV1);
    // WHY false 期待: 分類は Lively を判別できないため、判定不能なフラグを
    // 点灯させない（pipeline の分岐コメント参照）。
    expect(context.layoutMismatchFlag, isFalse);
    // ページ 1 + 統合 4 パス。
    expect(engine.recognizeCalls, 5);
    expect(engine.regionCalls, 0, reason: 'Lively は領域 OCR を使わない');
    expect(context.extractionResult, isNotNull);
    expect(context.regionOcrResult, isNotNull);
  });

  test('hint 無しの写真は従来どおり分類由来の経路（livelyV1 にしない）', () async {
    final engine = _LabelFakeEngine();
    final pipeline = OcrPipeline(engine: engine);

    final context = await pipeline.run(image);

    expect(context.layoutHint, isNull);
    expect(context.layoutKind, isNot(LayoutKind.livelyV1));
  });
}
