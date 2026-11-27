//
// Wave 2（タスク 01a20108）: 領域クロップ再 OCR の 30 枚計測。
//
// testimage/playshare/ のサンプル画像を scripts/push_test_images.ps1 で
// /data/local/tmp/poc/ へ push しておき、1 枚ずつ:
//   1. 全体 OCR（japanese・Wave 1 と同一条件）でアンカーを取る
//   2. RegionSpecBuilder でクロップ領域を算出
//   3. 領域ごとに recognizeRegion（数値系 Latin・曲名帯 Japanese）
//   4. extractWithRegions でマージした結果も併せて出力
// を行い、1 画像ごとの結果 JSON を print（stdout）に出すとともに、
// 端末のアプリ専用外部ストレージに playshare_region_ocr_results.json
// として保存する（test/fixtures/ocr/ へ配置してフィクスチャ駆動の
// 単体テスト・ベースライン更新に使う）。
//
// 実行手順（push → test → pull）は README
// 「バッチOCR精度測定ツール（integration test）」の節と同じ。
//
// 注意: 端末 / エミュレータ接続が必須。ホストの `flutter test` では
// 実行されない。
//
// WHY: 結果 JSON の組み立てを ocr_batch_result_builder.dart のように
// 別ヘルパーにせずここに置く（KISS）。スキーマの単体検証は、この計測の
// 出力をフィクスチャにした fixture 駆動テスト（Commit G）で行う。

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/region_ocr.dart';
import 'package:scoreyomipm/ocr/region_spec.dart';

const String _deviceImageDir = '/data/local/tmp/poc';
const String _resultFileName = 'playshare_region_ocr_results.json';
const int _expectedImageCount = 30;
const List<String> _imageExtensions = <String>['.jpg', '.jpeg', '.png'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('region re-OCR measurement over $_expectedImageCount images', (
    WidgetTester tester,
  ) async {
    final imageFiles = _collectImages();

    final lines = <String>[];
    final engine = MlKitOcrEngine(); // 既定: japanese（全体 OCR 用）
    try {
      for (final imageFile in imageFiles) {
        final line = await _measureOne(engine, imageFile);
        lines.add(line);
        print(line);
      }
    } finally {
      await engine.dispose();
    }

    final report = '{"results": [${lines.join(",\n")}]}';
    final (savedPaths, saveErrors) = await _saveReport(report);
    print('--- saved ---');
    for (final path in savedPaths) {
      print(path);
    }
    if (saveErrors.isNotEmpty) {
      print('WARN: 一部の保存先で失敗: ${saveErrors.join('; ')}');
    }
    print('--- summary ---');
    print(_summaryJson(lines));
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// テスト画像を列挙する。前提を満たさない場合はテストを失敗させる。
List<File> _collectImages() {
  final imageDir = Directory(_deviceImageDir);
  if (!imageDir.existsSync()) {
    fail(
      '$_deviceImageDir が存在しません。先にテスト画像を push してください:\n'
      '  powershell -ExecutionPolicy Bypass -File scripts\\push_test_images.ps1',
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
  if (imageFiles.length != _expectedImageCount) {
    print(
      'WARN: 画像ファイル数が想定と異なります '
      '(expected=$_expectedImageCount, actual=${imageFiles.length})。'
      'このまま続行します。',
    );
  }
  return imageFiles;
}

/// 1 画像の全体 OCR → クロップ再 OCR → マージを測定し JSON 1 行を返す。
/// 失敗してもバッチを止めない（error フィールドに記録）。
Future<String> _measureOne(MlKitOcrEngine engine, File imageFile) async {
  final fileName = imageFile.uri.pathSegments.last;
  try {
    // WHY(バイト列で渡すか): OcrEngine と RegionOcrRunner の入力契約は
    // バイト列に統一した。ファイル名は結果の識別子としてのみ使う。
    // 読み出しは 1 回だけにして、全体 OCR と領域 OCR に同じ画素を渡す。
    final imageBytes = await imageFile.readAsBytes();
    final page = await engine.recognize(imageBytes);
    final runner = RegionOcrRunner(engine: engine);
    final regionOcr = await runner.run(page, imageBytes);
    return jsonEncode(_toJson(page, regionOcr, fileName));
  } catch (error) {
    return jsonEncode({'file': fileName, 'error': error.toString()});
  }
}

/// 1 画像分の結果を JSON マップへ組み立てる。
Map<String, Object?> _toJson(
  OcrPageResult page,
  RegionOcrResult regionOcr,
  String fileName,
) {
  final full = const FieldExtractor().extract(page);
  final merged = const FieldExtractor().extractWithRegions(
    page,
    regionOcr.results,
  );
  return {
    'file': fileName,
    'imageWidth': page.imageWidth,
    'imageHeight': page.imageHeight,
    'fullFieldValues': _fieldValues(full),
    'mergedFieldValues': _fieldValues(merged),
    'specs': regionOcr.specs.map(_specToJson).toList(),
    'regions': regionOcr.results.entries.map(_regionToJson).toList(),
    'failures': regionOcr.failures,
  };
}

/// 抽出結果を kind → 値/生値/信頼度 のマップへ変換する。
Map<String, Object?> _fieldValues(FieldExtractionResult result) {
  final values = <String, Object?>{};
  for (final kind in NumericFieldKind.values) {
    final field = result.field(kind);
    if (field != null) {
      values[kind.name] = {
        'value': field.value,
        'rawText': field.rawText,
        'confidence': field.confidence,
      };
    }
  }
  return values;
}

/// 領域算出根拠（reason 含む）を JSON マップへ変換する。
Map<String, Object?> _specToJson(RegionSpec spec) {
  final r = spec.region;
  return {
    'target': spec.target.name,
    'script': spec.script.name,
    'regionNorm': {'l': r.left, 't': r.top, 'r': r.right, 'b': r.bottom},
    'reason': spec.reason,
  };
}

/// 1 領域の認識結果（クロップ座標系）を JSON マップへ変換する。
Map<String, Object?> _regionToJson(
  MapEntry<RegionTarget, OcrPageResult> entry,
) {
  final page = entry.value;
  return {
    'target': entry.key.name,
    'cropWidth': page.imageWidth,
    'cropHeight': page.imageHeight,
    'elementCount': page.elements.length,
    'elements': page.elements.map(_elementToJson).toList(),
    'fullText': page.fullText,
  };
}

/// 要素を JSON マップへ変換する。
Map<String, Object?> _elementToJson(OcrElement element) {
  final b = element.boundingBox;
  return {
    'text': element.text,
    'boundingBox': {'l': b.left, 't': b.top, 'r': b.right, 'b': b.bottom},
    'confidence': element.confidence,
  };
}

/// 結果 JSON 行からマージ後の検出数を集計する。
///
/// 数値はバッチ全体での「値が取れた枚数」を数える（全体 OCR 比較用に
/// full / merged の両方）。
String _summaryJson(List<String> lines) {
  var fullValid = 0;
  var mergedValid = 0;
  var score5Digit = 0;
  final mergedKinds = <String, int>{};
  for (final line in lines) {
    final map = jsonDecode(line) as Map<String, dynamic>;
    final full = map['fullFieldValues'] as Map<String, dynamic>?;
    final merged = map['mergedFieldValues'] as Map<String, dynamic>?;
    if (full != null) {
      fullValid += full.length;
    }
    if (merged != null) {
      mergedValid += merged.length;
      for (final key in merged.keys) {
        mergedKinds[key] = (mergedKinds[key] ?? 0) + 1;
      }
      final score = merged['score'] as Map<String, dynamic>?;
      if (score != null && (score['value'] as num) >= 10000) {
        score5Digit++;
      }
    }
  }
  mergedKinds['score5Digit'] = score5Digit;
  return jsonEncode({
    'fullValidFieldCount': fullValid,
    'mergedValidFieldCount': mergedValid,
    'perKind': mergedKinds,
  });
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
