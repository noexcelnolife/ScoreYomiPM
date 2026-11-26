// ac_v1 Wave-2 効果測定ハーネス（01a2065a 完了条件・リード実装 2026-11-23）。
//
// testimage/AC-HC-photo/ の実機写真 30 枚を emulator-5554 上の
// /data/local/tmp/poc_ac/ から 1 枚ずつフルパイプライン
// （preProcess → fieldOcr: フル OCR + アンカー検出 + 領域別 OCR + 抽出マージ）
// で処理し、抽出値を stdout に JSON で出力する。
//
// WHY フルパイプライン: 01a2065a の改修（Q2 クロップ文脈 2 文字語彙復旧・
// Q3 行推定フォールバック spec）は extractWithRegions 経路の改善であり、
// fixture ベースの extract() 単体テスト（ac_batch_extraction_test.dart・
// 改修前基線 score 27/30, cool 29/30, great 26/30, good 17/30, bad 14/30,
// maxCombo 29/30）では効果が現れない。実機 + 領域 OCR を含む本計測で
// 改修前基線からの向上を実測する。
//
// 実行手順（push → test）:
//   powershell -ExecutionPolicy Bypass -File scripts\push_ac_test_images.ps1
//   flutter test integration_test/ocr_ac_wave2_test.dart -d emulator-5554
//
// 注意: 端末 / エミュレータ接続が必須。ホストの `flutter test` では実行されない。

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

/// adb push でテスト画像を配置するディレクトリ。
const String _deviceImageDir = '/data/local/tmp/poc_ac';

/// 想定するテスト画像数（testimage/AC-HC-photo/ の枚数）。
const int _expectedImageCount = 30;

/// 対象とする画像拡張子。
const List<String> _imageExtensions = <String>['.jpg', '.jpeg', '.png'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ac wave2 full pipeline measurement over $_expectedImageCount images',
    (WidgetTester tester) async {
      // ---- 画像の列挙 ------------------------------------------------
      final imageFiles = _collectImages();

      // ---- パイプラインは 1 インスタンスを使い回す（エンジン dispose を
      // ---- 1 回に抑える・辞書ロードのコストを 1 回に近づける）。
      final engine = MlKitOcrEngine();
      final pipeline = OcrPipeline(engine: engine);
      final counts = <String, int>{};
      try {
        for (final imageFile in imageFiles) {
          final context = await pipeline.run(imageFile);
          final extraction = context.extractionResult;
          final record = _recordOf(imageFile.uri.pathSegments.last, extraction);
          _accumulate(counts, extraction);
          print('--- photo ---');
          print(jsonEncode(record));
        }
      } finally {
        await engine.dispose();
      }

      // ---- サマリ ------------------------------------------------------
      print('--- wave2 summary ---');
      print(
        jsonEncode(<String, Object?>{
          'photoCount': imageFiles.length,
          ...counts,
        }),
      );
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

  if (imageFiles.length != _expectedImageCount) {
    print(
      'WARN: 画像ファイル数が想定と異なります '
      '(expected=$_expectedImageCount, actual=${imageFiles.length})。',
    );
  }
  return imageFiles;
}

/// 1 写真分の抽出結果を JSON 出力用のマップにする。
///
/// 値は null（未抽出）または整数。isValid も併せて出力する
/// （検証範囲外の値の検出用）。
Map<String, Object?> _recordOf(
  String fileName,
  FieldExtractionResult? extraction,
) {
  String describe(ExtractedField? field) {
    if (field == null) {
      return 'null';
    }
    // WHY rawText を添える: 誤値の字形診断（例: O0000→0 のような 1 文字
    // 正規化由来の誤値）に必要。値だけでは読み元を特定できない。
    return '${field.value} (valid=${field.isValid}, raw="${field.rawText}")';
  }

  return <String, Object?>{
    'file': fileName,
    'score': describe(extraction?.score),
    'cool': describe(extraction?.cool),
    'great': describe(extraction?.great),
    'good': describe(extraction?.good),
    'bad': describe(extraction?.bad),
    'maxCombo': describe(extraction?.maxCombo),
    'level': describe(extraction?.level),
  };
}

/// 種別ごとの「null 以外の抽出」カウントを累積する。
void _accumulate(Map<String, int> counts, FieldExtractionResult? extraction) {
  void bump(String key, ExtractedField? field) {
    if (field != null) {
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }

  bump('score', extraction?.score);
  bump('cool', extraction?.cool);
  bump('great', extraction?.great);
  bump('good', extraction?.good);
  bump('bad', extraction?.bad);
  bump('maxCombo', extraction?.maxCombo);
}
