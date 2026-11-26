// OcrPipeline への ST-1.5 ロール補正統合の検証（幾何補正 Phase 1・01a207fc）。
// 設計: docs/geometric_rectification_design_2026-11-23.md §3。
//
// 検証対象:
// - hint ゲート: 補正は layoutHint==acV1（カメラ経路）のときだけ走る。
//   デジタル取り込み（hint 無し/hcV1）は現行バイト等価を維持する。
// - DIP: OcrPipeline は RollCorrector を注入可能（既定生成契約は
//   imagePicker 未注入不具合 a0d6a03 の教訓を踏襲）。
// - 一時ファイル後始末: 補正で作られたファイルは run 完了時に消す。
//   ただし入力と同じパスが返った場合は削除しない（呼び出し元のファイル保護）。
import 'dart:io';
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
class _SizeAwareFakeEngine implements OcrEngine {
  @override
  Future<OcrPageResult> recognize(File imageFile) async {
    final image = img.decodeImage(await imageFile.readAsBytes());
    return OcrPageResult(
      elements: const [],
      fullText: '',
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
    final image = img.decodeImage(await imageFile.readAsBytes());
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
  File? Function(File source)? onCall;

  @override
  File? maybeUpright(File source) {
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

      await pipeline.run(file);
      expect(corrector.callCount, 0, reason: 'hint 無しは補正しない');

      await pipeline.run(file, layoutHint: InputLayoutHint.hcV1);
      expect(corrector.callCount, 0, reason: 'hcV1 は補正しない');

      await pipeline.run(file, layoutHint: InputLayoutHint.acV1);
      expect(corrector.callCount, 1, reason: 'acV1（カメラ経路）のみ補正する');
    }, skip: imageSkip);

    test('補正ファイルへ差し替えられ、run 後に一時ファイルが消される', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final source = File(playsharePath);
      final tempCopy = File(
        '${Directory.systemTemp.path}/roll_pipe_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      tempCopy.writeAsBytesSync(source.readAsBytesSync());
      addTearDown(() {
        if (tempCopy.existsSync()) {
          tempCopy.deleteSync();
        }
      });
      corrector.onCall = (_) => tempCopy;

      final context = await pipeline.run(
        source,
        layoutHint: InputLayoutHint.acV1,
      );

      expect(context.imageFile.path, tempCopy.path);
      // WHY run 完了後: パイプラインが一時ファイルの後始末を持つ（設計 §3）。
      expect(tempCopy.existsSync(), isFalse, reason: 'run 後に一時ファイル削除');
    }, skip: imageSkip);

    test('補正器が入力と同じパスを返したときは削除しない（呼び出し元保護）', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final source = File(playsharePath);
      corrector.onCall = (s) => s;

      await pipeline.run(source, layoutHint: InputLayoutHint.acV1);

      expect(source.existsSync(), isTrue, reason: '入力ファイルは削除されない');
    }, skip: imageSkip);

    test('補正器が例外を出しても run は完走する（fail-safe）', () async {
      final corrector = _CountingRollCorrector();
      final pipeline = OcrPipeline(
        engine: _SizeAwareFakeEngine(),
        rollCorrector: corrector,
      );
      final file = File(playsharePath);
      corrector.onCall = (_) => throw StateError('補正器内部エラーの想定');

      final context = await pipeline.run(
        file,
        layoutHint: InputLayoutHint.acV1,
      );

      expect(context.imageFile.path, file.path);
    }, skip: imageSkip);

    test('acV1 ヒント時は分類駆動の刈り出し前処理をスキップする', () async {
      // WHY 必須: 補正後キャンバス（回転分の黒パディング込み）は分類が
      // rotatedPortrait と誤判定し、刈り出し前処理が OCR 入力を破壊する
      // （2026-11-23 回復測定で実証: rotatedPortrait 誤判定 3 ランが全滅、
      // arcadeResultFrame 判定ランは完全回復）。カメラ経路はヒントを信頼し、
      // 元画像のまま acV1 領域で抽出する。
      final pipeline = OcrPipeline(engine: _SizeAwareFakeEngine());
      final file = File('testimage/playshare/Screenshot_20261122-124336.png');

      final hinted = await pipeline.run(file, layoutHint: InputLayoutHint.acV1);
      expect(hinted.preprocessedImageFile, isNull);

      // WHY 回帰ガード: hint 無し（共有経路）は現行どおり刈り出し前処理が
      // 走る。スキップが acV1 ヒントに限定されていることを固定する。
      final unhinted = await pipeline.run(file);
      expect(unhinted.preprocessedImageFile, isNotNull);
    }, skip: screenshotSkip);
  });
}
