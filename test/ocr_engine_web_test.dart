// ブラウザ版 OCR エンジンの「失敗の型」の契約テスト。
//
// WHY(プラットフォーム非依存層を検証するか): 以前このファイルは Web 専用の
// 非対応スタブを直接 import していた。本実装は `dart:js_interop` を使うため
// VM（`flutter test`）ではコンパイルできない。失敗の意味論——「認識の失敗は
// 必ず OcrEngineException で表す」——は JS を知らない層で決まるので、
// そちらを検証対象にすれば同じ契約を VM で守れる。
//
// 画面側は `on OcrEngineException` だけで OCR 失敗を捕まえる。Error が
// 漏れると捕捉をすり抜けて赤画面になるため、ここは退行させてはいけない。

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/paddle_ocr_engine.dart';

import 'fake_paddle_ocr_client.dart';
import 'test_image_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PaddleOcrEngine（Web 版）の失敗契約', () {
    test('OcrEngine を実装している', () {
      final PaddleOcrEngine engine = PaddleOcrEngine(
        FakePaddleOcrClient(responses: <Object>[]),
      );

      expect(engine, isA<OcrEngine>());
    });

    test('どの失敗も OcrEngineException で表される', () async {
      // WHY(列挙するか): 失敗の入口は「空入力」「転送層の例外」「転送層の
      // 想定外呼び出し」「転送層の Error」と複数ある。どれか 1 つが素の
      // 例外を漏らすと、その経路だけ記録が失われる。
      final List<Future<Object?> Function()> failures =
          <Future<Object?> Function()>[
            () => PaddleOcrEngine(
              FakePaddleOcrClient(responses: <Object>[]),
            ).recognize(Uint8List(0)),
            () => PaddleOcrEngine(
              FakePaddleOcrClient(responses: <Object>[Exception('通信断')]),
            ).recognize(createTestImageBytes()),
            () => PaddleOcrEngine(
              FakePaddleOcrClient(responses: <Object>[]),
            ).recognize(createTestImageBytes()),
            () => PaddleOcrEngine(
              FakePaddleOcrClient(responses: <Object>[StateError('worker 異常')]),
            ).recognize(createTestImageBytes()),
            () => PaddleOcrEngine(
              FakePaddleOcrClient(responses: <Object>[Exception('推論失敗')]),
            ).recognizeRegion(
              createTestImageBytes(),
              const Rect.fromLTWH(0, 0, 2, 2),
              script: OcrScript.japanese,
            ),
          ];

      for (final failure in failures) {
        Object? thrown;
        try {
          await failure();
        } on Object catch (error) {
          thrown = error;
        }
        expect(thrown, isNotNull, reason: '失敗が起きていない');
        expect(thrown, isA<OcrEngineException>(), reason: '$thrown');
        expect(thrown, isNot(isA<Error>()), reason: '$thrown');
      }
    });

    test('dispose は何度呼んでも例外を投げない', () async {
      final PaddleOcrEngine engine = PaddleOcrEngine(
        FakePaddleOcrClient(responses: <Object>[]),
      );

      await engine.dispose();
      await engine.dispose();
    });

    test('破棄後の呼び出しは StateError（入力ではなくプログラムの誤り）', () async {
      // WHY(ここだけ Error か): 破棄後に呼ぶのは利用者の操作では起こりえず、
      // 呼び出し順の誤りである。OcrEngineException に混ぜると「OCR 失敗」
      // として扱われ、未確定レコードの保存に倒れてしまう。
      final PaddleOcrEngine engine = PaddleOcrEngine(
        FakePaddleOcrClient(responses: <Object>[]),
      );
      await engine.dispose();

      await expectLater(
        engine.recognize(createTestImageBytes()),
        throwsStateError,
      );
    });
  });
}
