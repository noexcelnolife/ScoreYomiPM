// バッチ OCR 精度測定ツール（integration test・ac_v1 用）。
//
// testimage/AC-HC-photo/ の実機写真 30 枚を emulator-5554 上の
// /data/local/tmp/poc_ac/ へ push しておき、それを 1 枚ずつ
// MlKitOcrEngine().recognize()（既定スクリプト: japanese）に通して、
// 日本語ラベル語彙（スコア/難易度/LEVEL 等）の出現有無・頻度を実測する。
// 1 画像ごとの認識結果 JSON を print（stdout）に出すとともに、
// 端末のアプリ専用外部ストレージに ocr_batch_ac_results.json として保存する。
//
// このファイルは追加条件 1（ラベル語アンカーの実証検証）のために作成した
// 計測ハーネスである。ac_v1 アンカーパック生成の前提（日本語ラベルが
// ML Kit でテキスト要素として抽出できるか否か）を実測する。
//
// 実行手順（push → test → pull）:
//   powershell -ExecutionPolicy Bypass -File scripts\push_ac_test_images.ps1
//   flutter test integration_test/ocr_batch_ac_test.dart -d emulator-5554
//   adb -s emulator-5554 pull /data/local/tmp/poc_ac/ocr_batch_ac_results.json ./testimage/AC-HC-photo/
//
// 注意: 端末 / エミュレータ接続が必須。ホストの `flutter test` では
// 実行されない。

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:scoreyomipm/ocr/mlkit_engine.dart';

import 'ocr_batch_result_builder.dart';

/// adb push でテスト画像を配置するディレクトリ。
const String _deviceImageDir = '/data/local/tmp/poc_ac';

/// 保存する結果 JSON のファイル名。
const String _resultFileName = 'ocr_batch_ac_results.json';

/// 想定するテスト画像数（testimage/AC-HC-photo/ の枚数）。
const int _expectedImageCount = 30;

/// 対象とする画像拡張子。
const List<String> _imageExtensions = <String>['.jpg', '.jpeg', '.png'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'batch OCR accuracy measurement over $_expectedImageCount ac images',
    (WidgetTester tester) async {
      // ---- 画像の列挙 ------------------------------------------------
      final imageFiles = _collectImages();

      // ---- 逐次 OCR --------------------------------------------------
      final results = await _runBatch(imageFiles);

      // ---- サマリ & レポート JSON ------------------------------------
      final summary = buildSummary(results);
      final report = encodeBatchReport(
        results: results,
        summary: summary,
        script: 'MlKitScript.japanese',
        imageDir: _deviceImageDir,
      );

      print('--- summary ---');
      print(jsonEncode(summary.toJson()));

      // ---- 結果ファイルの保存 ----------------------------------------
      final (savedPaths, saveErrors) = await _saveReport(report);

      print('--- saved ---');
      for (final path in savedPaths) {
        print(path);
      }
      if (saveErrors.isNotEmpty) {
        print('WARN: 一部の保存先で失敗: ${saveErrors.join('; ')}');
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// テスト画像を列挙する。前提を満たさない場合はテストを失敗させる。
List<File> _collectImages() {
  final imageDir = Directory(_deviceImageDir);
  if (!imageDir.existsSync()) {
    fail(
      '$_deviceImageDir が存在しません。先にテスト画像を push してください:\n'
      '  powershell -ExecutionPolicy Bypass -File scripts\\push_ac_test_images.ps1',
    );
  }

  final imageFiles =
      imageDir
          .listSync()
          .whereType<File>()
          .where(
            (file) => _imageExtensions.any(
              (ext) => file.path.toLowerCase().endsWith(ext),
            ),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (imageFiles.isEmpty) {
    fail('$_deviceImageDir に画像ファイル (.jpg/.jpeg/.png) がありません。');
  }
  if (imageFiles.length != _expectedImageCount) {
    print(
      'WARN: 画像ファイル数が想定と異なります '
      '(expected=$_expectedImageCount, actual=${imageFiles.length})。'
      'このまま続行します。',
    );
  }
  return imageFiles;
}

/// 画像を順次 OCR し、1 画像ごとに結果 JSON を stdout へ出力する。
/// エンジンはここで 1 つ生成し、終了時に dispose する。
Future<List<OcrBatchImageResult>> _runBatch(List<File> imageFiles) async {
  final engine = MlKitOcrEngine(); // 既定: MlKitScript.japanese
  final results = <OcrBatchImageResult>[];
  try {
    for (final imageFile in imageFiles) {
      final result = await _recognizeOne(engine, imageFile);
      results.add(result);
      // 1 画像ごとに stdout へも出力する。
      print(result.encodeJson());
    }
  } finally {
    await engine.dispose();
  }
  return results;
}

/// 1 画像を OCR する。
/// 失敗してもバッチを止めないよう、error を記録した結果を返す。
Future<OcrBatchImageResult> _recognizeOne(
  MlKitOcrEngine engine,
  File imageFile,
) async {
  final fileName = imageFile.uri.pathSegments.last;
  final stopwatch = Stopwatch()..start();
  try {
    final page = await engine.recognize(imageFile);
    stopwatch.stop();
    return OcrBatchImageResult(
      file: fileName,
      elementCount: page.elements.length,
      elements: page.elements.map(ocrElementToJson).toList(),
      fullText: page.fullText,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } catch (error) {
    // 1 枚の失敗でバッチを止めない。error を記録して続行する。
    stopwatch.stop();
    return OcrBatchImageResult(
      file: fileName,
      elementCount: 0,
      elements: const <Map<String, Object?>>[],
      fullText: '',
      elapsedMs: stopwatch.elapsedMilliseconds,
      error: error.toString(),
    );
  }
}

/// レポート JSON を外部ストレージと documents の両方へ書き込み、
/// 保存に成功したパスと失敗理由の一覧を返す。
/// すべての保存に失敗した場合はテストを失敗させる。
Future<(List<String>, List<String>)> _saveReport(String report) async {
  final savedPaths = <String>[];
  final saveErrors = <String>[];
  // 主: 外部ストレージのアプリ専用ディレクトリ（adb pull 可能 / root 不要）。
  // 副フォールバック: アプリの documents ディレクトリ（run-as で取得）。
  try {
    final externalDir = await getExternalStorageDirectory();
    if (externalDir != null) {
      final outFile = File('${externalDir.path}/$_resultFileName');
      await outFile.writeAsString(report, flush: true);
      savedPaths.add(outFile.path);
    } else {
      saveErrors.add('getExternalStorageDirectory() returned null');
    }
  } catch (error) {
    saveErrors.add('external storage: $error');
  }
  try {
    final documentsDir = await getApplicationDocumentsDirectory();
    final outFile = File('${documentsDir.path}/$_resultFileName');
    await outFile.writeAsString(report, flush: true);
    savedPaths.add(outFile.path);
  } catch (error) {
    saveErrors.add('documents: $error');
  }

  if (savedPaths.isEmpty) {
    fail('結果ファイルの保存にすべて失敗しました: ${saveErrors.join('; ')}');
  }
  return (savedPaths, saveErrors);
}
