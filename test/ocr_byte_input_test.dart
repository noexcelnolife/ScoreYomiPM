// OCR-D: OCR パイプラインの入出力がバイト列で完結することを固定する。
//
// WHY 一時ファイルの有無まで見るか: 以前は前処理・傾き補正・再 OCR が
// それぞれ temp にファイルを作り、パイプラインが最後に消す設計だった。
// バイト列化の目的は「Web で動くこと」だけではなく、その削除漏れという
// 失敗モード自体を無くすこと。だから「動く」ではなく「作らない」を固定する。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/input_preprocessing.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';
import 'package:scoreyomipm/ocr/roll_corrector.dart';
import 'package:scoreyomipm/ocr/ui_anchor.dart';

/// 旧実装が temp に作っていたファイル名の接頭辞。
///
/// WHY 接頭辞で絞るか: systemTemp には他プロセス（OS・他テスト）のファイルが
/// 常に出入りする。増減をそのまま比べると誤検知するので、旧実装が作っていた
/// 名前だけを見る。
const List<String> _formerTempPrefixes = <String>[
  'scoreyomipm_preprocessed_',
  'roll_upright_',
  'scoreyomipm_rerun_ocr',
  'scoreyomipm_test_',
];

/// temp に残っている「旧実装が作り得た名前」の集合。
Set<String> _tempArtifacts() {
  final directory = Directory.systemTemp;
  if (!directory.existsSync()) {
    return <String>{};
  }
  return directory
      .listSync()
      .map((entity) => entity.path.split(Platform.pathSeparator).last)
      .where((name) => _formerTempPrefixes.any(name.startsWith))
      .toSet();
}

/// 横縞（水平線）の合成画像。無傾きなので傾き補正は不要と判定される。
img.Image _horizontalStripes({int width = 640, int height = 320}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    final value = (y ~/ 8).isEven ? 255 : 0;
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image;
}

/// 横長の単色画像（landscapePlayShare に分類される）。
img.Image _landscapeFlat({int width = 1620, int height = 1080}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, 150, 150, 150);
    }
  }
  return image;
}

/// 何も認識しない最小の fake エンジン。
class _EmptyEngine extends OcrEngine {
  Uint8List? lastBytes;

  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    lastBytes = encodedImageBytes;
    return OcrPageResult(elements: const [], fullText: '');
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    return OcrPageResult(elements: const [], fullText: '');
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Set<String> before;

  setUp(() {
    before = _tempArtifacts();
  });

  tearDown(() {
    // テスト自身が temp を汚していないことを毎回確かめる。
    expect(
      _tempArtifacts().difference(before),
      isEmpty,
      reason: 'OCR 経路が一時ファイルを作っている',
    );
  });

  group('バイト列入力の往復', () {
    test('classify はバイト列だけを受け取り、分類を返す', () {
      final preprocessor = InputPreprocessor();
      final bytes = img.encodePng(_landscapeFlat());

      expect(
        preprocessor.classify(bytes),
        equals(InputImageClass.landscapePlayShare),
      );
    });

    test('preprocess は前処理不要なら同じバイト列を返す', () async {
      final preprocessor = InputPreprocessor();
      final bytes = img.encodePng(_landscapeFlat());

      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.landscapePlayShare));
      expect(result.preprocessedBytes, same(bytes));
    });

    test('maybeUpright は無傾きなら null（補正しない）', () {
      final corrector = RollCorrector();
      final bytes = img.encodePng(_horizontalStripes());

      expect(corrector.maybeUpright(bytes), isNull);
    });

    test('AnchorRegistration.detect はバイト列から登録結果を返す', () {
      final bytes = img.encodePng(_horizontalStripes(width: 400, height: 200));
      const pack = AnchorPack(
        version: 'byte_input_test',
        definitions: <AnchorDefinition>[],
        templates: <String, UiAnchorTemplate>{},
      );

      final registration = AnchorRegistration.detect(bytes, pack);

      expect(registration, isNotNull);
      expect(registration!.hits, isEmpty);
    });

    test('OcrPipeline.run はバイト列を受け取り、同じ実体を保持する', () async {
      final engine = _EmptyEngine();
      final pipeline = OcrPipeline(engine: engine);
      final bytes = img.encodePng(_landscapeFlat());

      final context = await pipeline.run(bytes, sourcePath: 'memory://sample');

      // エンジンへも同じ画素が渡る（途中で別のファイルを読み直していない）。
      expect(engine.lastBytes, isNotNull);
      // 前処理不要の画像なので、入力バイト列がそのまま保持される（コピーしない）。
      expect(context.imageBytes, same(bytes));
      expect(context.sourcePath, equals('memory://sample'));
      // 認識結果が空なので抽出結果は null。ここで見たいのは「入力がバイト列でも
      // パイプラインが最後まで走る」ことなので、pageResult の生成までを固定する。
      expect(context.pageResult, isNotNull);
    });
  });

  group('保存済みバイト列から再 OCR する経路', () {
    test('リポジトリが返したバイト列をそのままパイプラインへ渡せる', () async {
      // WHY この形か: 詳細画面の再 OCR は
      //   リポジトリ.readImage(相対キー) → バイト列 → pipeline.run
      // という経路を辿る。以前はこの間で一時ファイルを作っていた。
      final Uint8List savedBytes = img.encodePng(_landscapeFlat());
      final engine = _EmptyEngine();
      final pipeline = OcrPipeline(engine: engine);

      final context = await pipeline.run(
        savedBytes,
        sourcePath: 'play_records/2026/11/sample.png',
      );

      expect(context.pageResult, isNotNull);
      expect(context.sourcePath, equals('play_records/2026/11/sample.png'));
    });
  });
}
