import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';

import 'support/image_fixture_skip.dart';

void main() {
  // WHY: ML Kit の platform channel 呼び出し（processImage / close）は
  // binding 未初期化だと FlutterError（Error 系）を投げ、engine の
  // `on Exception` ハンドリング（OcrEngineException へのラップ・dispose の
  // 解放失敗無視）の検証対象にならない。binding を初期化しておくことで
  // 未登録チャネルは MissingPluginException（Exception 系）になり、
  // 本番と同じ例外経路をテストできる。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 実画像（GT 測定に使ったものと同一のフィクスチャ群）。
  const realImagePath =
      'testimage/playshare/p2039987434814058511_media_1795266589578_23bjim.jpg';

  group('MlKitOcrEngine.recognizeRegion', () {
    test('disposed 後は StateError（ネイティブリソース保護）', () async {
      final engine = MlKitOcrEngine();
      await engine.dispose();

      // WHY(フィクスチャを読まないか): このテストが見るのは「dispose 済みなら
      // 画素に触れる前に弾く」という順序の契約。入力の中身は結果に影響しない
      // ため、実画像に依存させない（画像が無い環境でも契約を検証できる）。
      await expectLater(
        engine.recognizeRegion(
          Uint8List.fromList(<int>[0x00]),
          const Rect.fromLTWH(0, 0, 100, 50),
          script: OcrScript.latin,
        ),
        throwsStateError,
      );
    });

    // WHY(壊れたバイト列で試すか): 入力がバイト列になったため「ファイルが無い」
    // という失敗は起きない。エンジン境界で起こり得る失敗は「復号できない
    // バイト列」であり、契約どおり OcrEngineException に包まれることを見る。
    test('復号できないバイト列は OcrEngineException（全体 OCR と同一契約）', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognizeRegion(
          Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03]),
          const Rect.fromLTWH(0, 0, 100, 50),
          script: OcrScript.latin,
        ),
        throwsA(isA<OcrEngineException>()),
      );
    });

    test('空 / 負寸法の領域は ArgumentError（クロップ前に検証）', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognizeRegion(
          File(realImagePath).readAsBytesSync(),
          const Rect.fromLTWH(100, 100, 0, 50),
          script: OcrScript.latin,
        ),
        throwsArgumentError,
      );
      await expectLater(
        engine.recognizeRegion(
          File(realImagePath).readAsBytesSync(),
          const Rect.fromLTWH(100, 100, -10, 50),
          script: OcrScript.latin,
        ),
        throwsArgumentError,
      );
    }, skip: skipIfImagesMissing(<String>[realImagePath]));

    test('画像完全外部の領域は ArgumentError（交差なしの早期検出）', () async {
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognizeRegion(
          File(realImagePath).readAsBytesSync(),
          const Rect.fromLTWH(100000, 100000, 50, 50),
          script: OcrScript.latin,
        ),
        throwsArgumentError,
      );
    }, skip: skipIfImagesMissing(<String>[realImagePath]));

    test('画像境界をはみ出す領域は画像側へ clamp される（テスト画像で境界検証）', () async {
      // WHY: ラベル bbox から算出した領域はマージン加算で境界をはみ出す
      // ことがあるため、実装は intersect で clamp する（mlkit_engine の
      // _crop 参照）。ピクセルデコードは headless で実行できるので、
      // はみ出し領域が ArgumentError にならずクロップ処理まで進むことを、
      // プラットフォーム未初期化による例外到達で検証する。
      // NOTE: flutter test 環境には ML Kit のネイティブ実装がないため
      // 認識自体は必ず失敗する。ここでは「クロップ処理が完了し ML Kit 呼び出し
      // まで到達すること」までを検証する（認識結果の検証はエミュレータ上の
      // 統合計測で行う）。
      final engine = MlKitOcrEngine();
      addTearDown(engine.dispose);

      await expectLater(
        engine.recognizeRegion(
          File(realImagePath).readAsBytesSync(),
          const Rect.fromLTWH(-50, -50, 99999, 99999),
          script: OcrScript.latin,
        ),
        throwsA(isA<OcrEngineException>()),
      );
    }, skip: skipIfImagesMissing(<String>[realImagePath]));
  });
}
