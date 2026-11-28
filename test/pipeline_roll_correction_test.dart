// OcrPipeline への ST-1.5 ロール補正統合の検証（幾何補正 Phase 1・01a207fc）。
// 設計: docs/geometric_rectification_design_2026-11-23.md §3。
//
// 検証対象:
// - hint ゲート: 補正は layoutHint==acV1（カメラ経路）のときだけ走る。
//   デジタル取り込み（hint 無し/hcV1）は現行バイト等価を維持する。
// - DIP: OcrPipeline は RollCorrector を注入可能（既定生成契約は
//   imagePicker 未注入不具合 a0d6a03 の教訓を踏襲）。
// - 入力の保持: 補正は入力バイト列を差し替えるだけで、入力そのものは
//   書き換えない・消さない（バイト列渡しなので削除という失敗モードが無い）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';
import 'package:scoreyomipm/ocr/roll_corrector.dart';

import 'support/image_fixture_skip.dart';

/// 実ファイル寸法を返す最小 fake engine（pipeline_layout_hint_test と同型）。
///
/// WHY: ST-4 は寸法欠落で領域 OCR をスキップするため、寸法を返さない fake では
/// run が完了しない。要素は空でよい（本テストの対象は補正のゲートと後始末）。
class _SizeAwareFakeEngine extends OcrEngine {
  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    final image = img.decodeImage(encodedImageBytes);
    return OcrPageResult(
      elements: const [],
      fullText: '',
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
    final image = img.decodeImage(encodedImageBytes);
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

/// 呼び出しを数える fake 補正器。
class _CountingRollCorrector extends RollCorrector {
  int callCount = 0;

  /// maybeUpright の戻り値（null = 補正なし・非 null = 差し替え）。
  Uint8List? Function(Uint8List source)? onCall;

  @override
  Uint8List? maybeUpright(Uint8List source) {
    callCount++;
    return onCall?.call(source);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 分類代表画像（pipeline_layout_hint_test と同一の分類根拠）。
  const String playsharePath =
      'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg';

  // 実画像が無い環境（公開リポジトリの clone など）では実画像テストを skip する
  final String? imageSkip = skipIfImagesMissing(<String>[playsharePath]);
  final String? screenshotSkip = skipIfImagesMissing(const <String>[
    'testimage/playshare/Screenshot_20261122-124336.png',
  ]);

  group('OcrPipeline ST-1.5 ロール補正の hint ゲート（01a207fc）', () {
    test('既定生成契約: rollCorrector 未注入でも非 null の既定実装を持つ', () {
      final pipeline = OcrPipeline(engine: _SizeAwareFakeEngine());
      expect(pipeline.rollCorrector, isNotNull);
    });

    test('hint=acV1 のときだけ補正器が呼ばれる（hint 無し/hcV1 では呼ばれない）', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final file = File(playsharePath);
      expect(file.existsSync(), isTrue, reason: '欠落: $playsharePath');
      final bytes = file.readAsBytesSync();

      await pipeline.run(bytes);
      expect(corrector.callCount, 0, reason: 'hint 無しは補正しない');

      await pipeline.run(bytes, layoutHint: InputLayoutHint.hcV1);
      expect(corrector.callCount, 0, reason: 'hcV1 は補正しない');

      await pipeline.run(bytes, layoutHint: InputLayoutHint.acV1);
      expect(corrector.callCount, 1, reason: 'acV1（カメラ経路）のみ補正する');
    }, skip: imageSkip);

    test('補正結果のバイト列へ差し替えられ、入力バイト列は書き換わらない', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final source = File(playsharePath).readAsBytesSync();
      final corrected = Uint8List.fromList(source);
      corrector.onCall = (_) => corrected;

      final context = await pipeline.run(
        source,
        layoutHint: InputLayoutHint.acV1,
      );

      expect(context.imageBytes, same(corrected));
      expect(context.sourcePath, isNull);
      // WHY: 補正は入力の複製ではなく差し替え。呼び出し元が渡した配列は
      // パイプラインの都合で書き換わらない（呼び出し元が後で再利用できる）。
      expect(source, equals(corrected));
    }, skip: imageSkip);

    test('補正器が入力をそのまま返しても入力バイト列は失われない', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final bytes = File(playsharePath).readAsBytesSync();
      corrector.onCall = (source) => source;

      final context = await pipeline.run(
        bytes,
        layoutHint: InputLayoutHint.acV1,
      );

      // WHY: 以前は補正結果を一時ファイルで受け渡していたため「入力ファイルを
      // 誤って消さない」ことを守る必要があった。バイト列渡しでは削除が起きない。
      expect(context.imageBytes, same(bytes));
    }, skip: imageSkip);

    test('補正器が例外を出しても run は完走する（fail-safe）', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final bytes = File(playsharePath).readAsBytesSync();
      corrector.onCall = (_) => throw StateError('補正器内部エラーの想定');

      final context = await pipeline.run(
        bytes,
        layoutHint: InputLayoutHint.acV1,
      );

      expect(context.imageBytes, same(bytes));
    }, skip: imageSkip);

    test('acV1 ヒント時は分類駆動の刈り出し前処理をスキップする', () async {
      // WHY 必須: 補正後キャンバス（回転分の黒パディング込み）は分類が
      // rotatedPortrait と誤判定し、刈り出し前処理が OCR 入力を破壊する
      // （2026-11-23 回復測定で実証: rotatedPortrait 誤判定 3 ランが全滅、
      // arcadeResultFrame 判定ランは完全回復）。カメラ経路はヒントを信頼し、
      // 元画像のまま acV1 領域で抽出する。
      final pipeline = OcrPipeline(engine: _SizeAwareFakeEngine());
      final file = File('testimage/playshare/Screenshot_20261122-124336.png');
      final bytes = file.readAsBytesSync();

      final hinted = await pipeline.run(bytes, layoutHint: InputLayoutHint.acV1);
      expect(hinted.preprocessedImageBytes, isNull);

      // WHY 回帰ガード: hint 無し（共有経路）は現行どおり刈り出し前処理が
      // 走る。スキップが acV1 ヒントに限定されていることを固定する。
      final unhinted = await pipeline.run(bytes);
      expect(unhinted.preprocessedImageBytes, isNotNull);
    }, skip: screenshotSkip);
  });
}
