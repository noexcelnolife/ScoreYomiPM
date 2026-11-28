// PaddleOcrEngine（Web 版 OCR のプラットフォーム非依存層）のテスト。
//
// WHY(VM で動かすか): この層は JS もブラウザも知らない。認識の意味論
// （要素の写像・クロップ座標・再試行条件・失敗型）はここで全部検証でき、
// ブラウザを起動しないぶん速く、環境差でも揺れない。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/paddle_ocr_engine.dart';

import 'fake_paddle_ocr_client.dart';
import 'test_image_helper.dart';

void main() {
  // WHY: クロップと PNG エンコードは dart:ui の画像機能を使う。
  TestWidgetsFlutterBinding.ensureInitialized();

  const OcrElement title = OcrElement(
    text: '千本桜',
    boundingBox: ui.Rect.fromLTWH(10, 20, 60, 12),
    confidence: 0.97,
  );
  const OcrElement score = OcrElement(
    text: '1,234,567',
    boundingBox: ui.Rect.fromLTWH(10, 40, 80, 12),
    confidence: 0.93,
  );

  group('recognize', () {
    test('要素を OcrPageResult に写し、寸法は渡した画像から取る', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[
          <OcrElement>[title, score],
        ],
      );
      final engine = PaddleOcrEngine(client);

      final result = await engine.recognize(createTestImageBytes());

      expect(result.elements.length, 2);
      expect(result.elements.first.text, '千本桜');
      expect(result.elements.first.boundingBox, title.boundingBox);
      expect(result.elements.first.confidence, closeTo(0.97, 1e-9));
      // WHY(行区切りか): 1 要素 = 1 行なので、改行で連結するのが構造に忠実。
      expect(result.fullText, '千本桜\n1,234,567');
      // createTestImageBytes() は 3x2 の PNG。
      expect(result.imageWidth, 3);
      expect(result.imageHeight, 2);
      // 認識は渡された画像そのもので 1 回だけ。
      expect(client.receivedBytes.length, 1);
    });

    test('要素 0 件なら fullText は空文字', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[<OcrElement>[]],
      );

      final result = await PaddleOcrEngine(client).recognize(
        createTestImageBytes(),
      );

      expect(result.elements, isEmpty);
      expect(result.fullText, isEmpty);
      expect(result.imageWidth, 3);
    });

    test('空のバイト列は OcrEngineException', () async {
      final client = FakePaddleOcrClient(responses: <Object>[]);

      await expectLater(
        PaddleOcrEngine(client).recognize(Uint8List(0)),
        throwsA(isA<OcrEngineException>()),
      );
      expect(client.receivedBytes, isEmpty);
    });
  });

  group('recognizeRegion', () {
    test('クロップ内座標のまま返し、寸法はクロップのものになる', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[
          <OcrElement>[
            const OcrElement(
              text: '12',
              boundingBox: ui.Rect.fromLTWH(0, 0, 8, 4),
              confidence: 0.5,
            ),
          ],
        ],
      );
      final engine = PaddleOcrEngine(client);

      final result = await engine.recognizeRegion(
        createTestImageBytes(),
        const ui.Rect.fromLTWH(1, 0, 2, 2),
        script: OcrScript.japanese,
        pixelScale: 2,
      );

      // 元画像 3x2 のうち (1,0) から 2x2 を 2 倍 → 4x4。
      expect(await _sizeOf(client.receivedBytes.single), (4, 4));
      expect(result.imageWidth, 4);
      expect(result.imageHeight, 4);
      // WHY(この一致が契約か): 呼び出し側は返り値の bbox に元画像のオフセットを
      // 足して使う。ここで領域原点 (1,0) を加えてしまうと二重にずれる。
      expect(result.elements.single.boundingBox, const ui.Rect.fromLTWH(0, 0, 8, 4));
    });

    test('画像の外にはみ出す領域は画像内に丸めてクロップする', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[<OcrElement>[]],
      );

      await PaddleOcrEngine(client).recognizeRegion(
        createTestImageBytes(),
        const ui.Rect.fromLTWH(1, 0, 100, 100),
        script: OcrScript.japanese,
      );

      // 3x2 の画像なので、はみ出し分は切り捨てられて 2x2 になる。
      expect(await _sizeOf(client.receivedBytes.single), (2, 2));
    });

    test('完全に画像の外の領域は ArgumentError', () async {
      final client = FakePaddleOcrClient(responses: <Object>[]);

      await expectLater(
        PaddleOcrEngine(client).recognizeRegion(
          createTestImageBytes(),
          const ui.Rect.fromLTWH(50, 50, 10, 10),
          script: OcrScript.japanese,
        ),
        throwsArgumentError,
      );
    });

    test('pixelScale が 0 以下なら ArgumentError', () async {
      final client = FakePaddleOcrClient(responses: <Object>[]);

      await expectLater(
        PaddleOcrEngine(client).recognizeRegion(
          createTestImageBytes(),
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          script: OcrScript.japanese,
          pixelScale: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('contrastRetry', () {
    test('要素が 1 つでもあれば再試行しない', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[
          <OcrElement>[title],
        ],
      );

      final result = await PaddleOcrEngine(client).recognizeRegion(
        createTestImageBytes(),
        const ui.Rect.fromLTWH(0, 0, 3, 2),
        script: OcrScript.japanese,
        contrastRetry: true,
      );

      expect(result.elements.single.text, '千本桜');
      expect(client.receivedBytes.length, 1);
    });

    test('contrastRetry が false なら 0 件でも再試行しない', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[<OcrElement>[]],
      );

      final result = await PaddleOcrEngine(client).recognizeRegion(
        createTestImageBytes(),
        const ui.Rect.fromLTWH(0, 0, 3, 2),
        script: OcrScript.japanese,
      );

      expect(result.elements, isEmpty);
      expect(client.receivedBytes.length, 1);
    });

    test('0 件かつ二値化できる画像なら二値化して 1 度だけ再試行する', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[
          <OcrElement>[],
          <OcrElement>[title],
        ],
      );

      final result = await PaddleOcrEngine(client).recognizeRegion(
        await _twoToneImageBytes(),
        const ui.Rect.fromLTWH(0, 0, 8, 4),
        script: OcrScript.japanese,
        contrastRetry: true,
      );

      expect(result.elements.single.text, '千本桜');
      expect(client.receivedBytes.length, 2);
      // 再試行の入力も同じ寸法（寸法を変えると bbox の基準が変わる）。
      expect(await _sizeOf(client.receivedBytes.last), (8, 4));
      expect(result.imageWidth, 8);
      expect(result.imageHeight, 4);
    });

    test('単色画像では二値化できず 1 次結果をそのまま返す', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[<OcrElement>[]],
      );

      final result = await PaddleOcrEngine(client).recognizeRegion(
        createTestImageBytes(),
        const ui.Rect.fromLTWH(0, 0, 3, 2),
        script: OcrScript.japanese,
        contrastRetry: true,
      );

      expect(result.elements, isEmpty);
      // WHY(1 回で終わることを確かめるか): 二値化が縮退したときに、
      // 無意味な再認識コストを払わないことが契約（ContrastPreprocess の
      // 「前処理不能なら null」）。
      expect(client.receivedBytes.length, 1);
    });
  });

  group('dispose', () {
    test('破棄後は StateError', () async {
      final client = FakePaddleOcrClient(responses: <Object>[]);
      final engine = PaddleOcrEngine(client);
      await engine.dispose();

      await expectLater(
        engine.recognize(createTestImageBytes()),
        throwsStateError,
      );
      await expectLater(
        engine.recognizeRegion(
          createTestImageBytes(),
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          script: OcrScript.japanese,
        ),
        throwsStateError,
      );
      expect(client.disposeCount, 1);
    });

    test('2 回呼んでもクライアントの dispose は 1 回', () async {
      final client = FakePaddleOcrClient(responses: <Object>[]);
      final engine = PaddleOcrEngine(client);

      await engine.dispose();
      await engine.dispose();

      expect(client.disposeCount, 1);
    });
  });

  group('失敗の型', () {
    test('クライアントの例外は OcrEngineException に包まれる', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[Exception('worker が落ちた')],
      );

      await expectLater(
        PaddleOcrEngine(client).recognize(createTestImageBytes()),
        throwsA(isA<OcrEngineException>()),
      );
    });

    test('OcrEngineException はそのまま伝わる（二重に包まない）', () async {
      const OcrEngineException original = OcrEngineException('元の失敗');
      final client = FakePaddleOcrClient(responses: <Object>[original]);

      await expectLater(
        PaddleOcrEngine(client).recognize(createTestImageBytes()),
        throwsA(
          isA<OcrEngineException>().having(
            (OcrEngineException error) => error.message,
            'message',
            '元の失敗',
          ),
        ),
      );
    });

    test('区間 OCR でもクライアントの例外は OcrEngineException になる', () async {
      final client = FakePaddleOcrClient(
        responses: <Object>[Exception('推論に失敗')],
      );

      await expectLater(
        PaddleOcrEngine(client).recognizeRegion(
          createTestImageBytes(),
          const ui.Rect.fromLTWH(0, 0, 2, 2),
          script: OcrScript.japanese,
        ),
        throwsA(isA<OcrEngineException>()),
      );
    });
  });

  group('isPreparing', () {
    test('既定のクライアントでは false', () {
      final engine = PaddleOcrEngine(
        FakePaddleOcrClient(responses: <Object>[]),
      );

      expect(engine.isPreparing, isFalse);
    });

    test('クライアントの値をそのまま返す', () {
      final engine = PaddleOcrEngine(
        LoadStateFakePaddleOcrClient(
          responses: <Object>[],
          isPreparing: true,
        ),
      );

      expect(engine.isPreparing, isTrue);
    });

    test('dispose 後も問い合わせ自体は例外にならない', () async {
      final engine = PaddleOcrEngine(
        LoadStateFakePaddleOcrClient(
          responses: <Object>[],
          isPreparing: false,
        ),
      );

      await engine.dispose();

      // WHY: UI は実行中に何度か読むことがある。破棄で状態が変わるのは
      // 認識だけであり、名乗りまで例外になると画面側の分岐が増える。
      expect(engine.isPreparing, isFalse);
    });
  });
}

/// 画像の寸法を読む。
Future<(int, int)> _sizeOf(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  try {
    final ui.Image image = (await codec.getNextFrame()).image;
    try {
      return (image.width, image.height);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// 二値化が成立する（占有輝度が 2 つ以上ある）テスト画像の PNG バイト列。
///
/// WHY(単色画像では駄目か): 大津法は占有 bin が 1 つだと閾値を決められず
/// null を返す（縮退契約）。再試行経路を実際に通すには濃淡が要る。
Future<Uint8List> _twoToneImageBytes() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 4),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(1, 1, 3, 2),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(8, 4);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
