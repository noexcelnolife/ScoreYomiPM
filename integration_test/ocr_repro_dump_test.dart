// rel23bjim.jpg の実機 ML Kit 生要素ダンプ（integration test・一点計測）。
//
// 生成手順（リード指示 01a208f7 手順 1）:
//   デバイス: emulator-5554（API 35）
//   画像: /sdcard/DCIM/rel23bjim.jpg（222923 bytes・2026-11-23 23:21 配置）
//   エンジン: MlKitOcrEngine（既定スクリプト japanese）
//   実行: flutter test integration_test/ocr_repro_dump_test.dart -d emulator-5554
//   出力: stdout に REPRO_DUMP_JSON:<json> 行を表示。python 側で抽出し
//         test/fixtures/ocr/23bjim_repro_elements.json として取り込む。
//
// 注意: 実行環境（エミュ・ファイル・初回モデル DL）の存続が前提。失敗時は
//   fail する（握りつぶして重ね掛けしない）。

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/ocr/mlkit_engine.dart';

import 'ocr_batch_result_builder.dart';

/// 計測対象（実機：批処理の standard 配置 /data/local/tmp/poc/）
///
/// WHY: /sdcard/DCIM はアプリ uid にとって開けない（errno 13）ため、
///   rel23bjim.jpg と同内容（222923 bytes）の標準配置を読みに行く。
const String _targetPath =
    '/data/local/tmp/poc/p2039987434814058511_media_1795266589578_23bjim.jpg';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repro: 23bjim.jpg の生要素ダンプ', (WidgetTester tester) async {
    final file = File(_targetPath);
    expect(file.existsSync(), isTrue, reason: '対象画像が存在しない: $_targetPath');
    final engine = MlKitOcrEngine();
    OcrBatchImageResult result;
    try {
      result = await _runOcr(engine, file);
    } finally {
      await engine.dispose();
    }
    print('REPRO_DUMP_JSON:${result.encodeJson()}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<OcrBatchImageResult> _runOcr(MlKitOcrEngine engine, File file) async {
  final sw = Stopwatch()..start();
  final page = await engine.recognize(file);
  sw.stop();
  return OcrBatchImageResult(
    file: 'rel23bjim.jpg',
    elementCount: page.elements.length,
    elements: page.elements.map(ocrElementToJson).toList(),
    fullText: page.fullText,
    elapsedMs: sw.elapsedMilliseconds,
  );
}
