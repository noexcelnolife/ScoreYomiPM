// Web 版の OCR エンジン（非対応実装）の契約テスト。
//
// OCR を持たない環境でも、失敗が必ず OcrEngineException で表現されることを
// 検証する。UI はこの型だけを「OCR 失敗」として捕捉するため、Error 系
// （UnimplementedError 等）が漏れると赤画面になる。

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/ocr_engine_web.dart';

void main() {
  final Uint8List bytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]);

  group('UnsupportedOcrEngine', () {
    test('OcrEngine を実装している', () {
      expect(createOcrEngine(), isA<OcrEngine>());
    });

    test('recognize は OcrEngineException を投げる', () async {
      final OcrEngine engine = createOcrEngine();

      await expectLater(
        engine.recognize(bytes),
        throwsA(isA<OcrEngineException>()),
      );
    });

    test('recognizeRegion は OcrEngineException を投げる', () async {
      final OcrEngine engine = createOcrEngine();

      await expectLater(
        engine.recognizeRegion(
          bytes,
          const Rect.fromLTWH(0, 0, 10, 10),
          script: OcrScript.japanese,
        ),
        throwsA(isA<OcrEngineException>()),
      );
    });

    test('失敗型は Error ではなく Exception である', () async {
      // WHY(Exception に限るか): 呼び出し側は `on OcrEngineException` で
      // 捕捉する。Error を投げると捕捉をすり抜けて赤画面になる。
      Object? thrown;
      try {
        await createOcrEngine().recognize(bytes);
      } on Object catch (error) {
        thrown = error;
      }

      expect(thrown, isA<Exception>());
      expect(thrown, isNot(isA<Error>()));
    });

    test('dispose は何度呼んでも例外を投げない', () async {
      final OcrEngine engine = createOcrEngine();

      await engine.dispose();
      await engine.dispose();
    });
  });
}
