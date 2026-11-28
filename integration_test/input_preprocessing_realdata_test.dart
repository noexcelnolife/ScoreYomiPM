// ST-1 実データ検証・前処理統合テスト（39枚）
//
// 1. 既存30枚の JPG がすべて landscapePlayShare と分類されること（1枚でも違えば FAIL）
// 2. scr001-009 全9枚が portraitWithEmbedded と分類されること
// 3. 前処理済み scr 画像で OcrPipeline を実行し、GT（docs/ground_truth_template.csv）
//    と照合してフィールド別命中率を報告
//
// 制約: testimage/ と docs/ は読み取り専用。lib/ui と test/ocr_result_screen_test.dart は触らない。
//
// 実行: flutter test integration_test/input_preprocessing_realdata_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/input_preprocessing.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

const String _playshareDir = '/data/local/tmp/pm_test/testimage';
const String _gtCsvPath =
    '/data/local/tmp/pm_test/docs/ground_truth_template.csv';

final List<String> _scrIds = <String>[
  'scr001',
  'scr002',
  'scr003',
  'scr004',
  'scr005',
  'scr006',
  'scr007',
  'scr008',
  'scr009',
];

final Map<String, String> _scrTimestamps = <String, String>{
  'scr001': '124336',
  'scr002': '124345',
  'scr003': '124356',
  'scr004': '124401',
  'scr005': '124405',
  'scr006': '124410',
  'scr007': '124414',
  'scr008': '124418',
  'scr009': '124421',
};

String _scrPath(String id) =>
    '$_playshareDir/Screenshot_20261122-${_scrTimestamps[id] ?? ''}.png';

/// GT CSV 行
class GtRow {
  final String id;
  final String filename;
  final int level;
  final int score;
  final int cool;
  final int great;
  final int good;
  final int bad;
  final int maxCombo;

  GtRow({
    required this.id,
    required this.filename,
    required this.level,
    required this.score,
    required this.cool,
    required this.great,
    required this.good,
    required this.bad,
    required this.maxCombo,
  });
}

/// GT CSV をパースして scr 行のみ返す
Map<String, GtRow> _parseScrGt() {
  final lines = File(_gtCsvPath).readAsLinesSync();
  final result = <String, GtRow>{};
  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final cols = line.split(',');
    if (cols.length < 13) continue;
    final id = cols[0];
    if (!id.startsWith('scr')) continue;
    result[id] = GtRow(
      id: id,
      filename: cols[1],
      level: int.tryParse(cols[6]) ?? 0,
      score: int.tryParse(cols[7]) ?? 0,
      cool: int.tryParse(cols[8]) ?? 0,
      great: int.tryParse(cols[9]) ?? 0,
      good: int.tryParse(cols[10]) ?? 0,
      bad: int.tryParse(cols[11]) ?? 0,
      maxCombo: int.tryParse(cols[12]) ?? 0,
    );
  }
  return result;
}

/// GT 値をフィールド名で取得
int _gtValue(GtRow gt, String fieldName) {
  switch (fieldName) {
    case 'score':
      return gt.score;
    case 'cool':
      return gt.cool;
    case 'great':
      return gt.great;
    case 'good':
      return gt.good;
    case 'bad':
      return gt.bad;
    case 'maxCombo':
      return gt.maxCombo;
    case 'level':
      return gt.level;
    default:
      throw ArgumentError('Unknown field: $fieldName');
  }
}

/// テスト結果をレポート出力する（integration_test では print を使用）
void _report(String message) {
  // ignore: avoid_print
  print(message);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('ST-1 実データ検証・前処理統合テスト（39枚）', () {
    test('1. 既存30枚すべて landscapePlayShare と分類される（1枚でも違えば FAIL）', () async {
      final preprocessor = InputPreprocessor();
      final dir = Directory(_playshareDir);
      final jpgFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(
        jpgFiles.length,
        equals(30),
        reason: 'testimage/playshare/ に JPG が 30 枚存在すること',
      );

      final misclassified = <String>[];
      for (final file in jpgFiles) {
        final actual = preprocessor.classify(file.readAsBytesSync());
        if (actual != InputImageClass.landscapePlayShare) {
          misclassified.add('${file.uri.pathSegments.last}: $actual');
        }
      }

      expect(
        misclassified,
        isEmpty,
        reason: '誤分類あり: ${misclassified.join(', ')}',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('2. scr001-009 全9枚 portraitWithEmbedded と分類されること', () async {
      final preprocessor = InputPreprocessor();
      final misclassified = <String>[];
      for (final id in _scrIds) {
        final file = File(_scrPath(id));
        expect(file.existsSync(), isTrue, reason: '$id: ファイルが存在しません');
        final actual = preprocessor.classify(file.readAsBytesSync());
        if (actual != InputImageClass.portraitWithEmbedded) {
          misclassified.add('$id: 期待 portraitWithEmbedded, 実際 $actual');
        }
      }
      expect(misclassified, isEmpty, reason: misclassified.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('3. 前処理済み scr 画像でパイプライン実行・GT照合（フィールド別命中率）', () async {
      final preprocessor = InputPreprocessor();
      final engine = MlKitOcrEngine(defaultScript: MlKitScript.latin);
      final pipeline = OcrPipeline(engine: engine);
      final gtMap = _parseScrGt();

      expect(
        gtMap.length,
        equals(9),
        reason: 'GT CSV に scr001-009 の 9 行が存在すること',
      );

      final fieldKinds = <String, NumericFieldKind>{
        'score': NumericFieldKind.score,
        'cool': NumericFieldKind.cool,
        'great': NumericFieldKind.great,
        'good': NumericFieldKind.good,
        'bad': NumericFieldKind.bad,
        'maxCombo': NumericFieldKind.maxCombo,
        'level': NumericFieldKind.level,
      };

      final fieldNames = fieldKinds.keys.toList();
      final fieldHits = <String, int>{};
      final fieldTotal = <String, int>{};
      int totalFields = 0;
      int hitFields = 0;

      _report('\n=== ST-1 フィールド別命中率（前処理済み scr 9枚） ===');

      for (final id in _scrIds) {
        final file = File(_scrPath(id));
        final gt = gtMap[id]!;

        // 分類検証
        final cls = preprocessor.classify(file.readAsBytesSync());
        expect(
          cls,
          equals(InputImageClass.portraitWithEmbedded),
          reason: '$id 分類エラー: 期待 portraitWithEmbedded, 実際 $cls',
        );

        // パイプライン実行（preProcess + fieldOcr）
        final context = await pipeline.run(file.readAsBytesSync());
        final extractionResult = context.extractionResult;

        // 前処理結果が保持されていることを確認
        expect(
          context.preprocessedImageBytes,
          isNotNull,
          reason: '$id: preprocessedImageBytes が null',
        );

        _report('\n--- $id ---');

        for (final fieldName in fieldNames) {
          final kind = fieldKinds[fieldName]!;
          final extracted = extractionResult?.field(kind);
          final gtValue = _gtValue(gt, fieldName);

          final hit =
              extracted != null &&
              extracted.isValid &&
              extracted.value == gtValue;

          fieldTotal[fieldName] = (fieldTotal[fieldName] ?? 0) + 1;
          totalFields++;
          if (hit) {
            fieldHits[fieldName] = (fieldHits[fieldName] ?? 0) + 1;
            hitFields++;
          }

          _report(
            '  ${fieldName.padRight(10)}: GT=$gtValue '
            'OCR=${extracted?.value ?? '-'} '
            '${hit ? '✓' : '✗'} '
            '(raw: ${extracted?.rawText ?? '-'}, valid: ${extracted?.isValid ?? false})',
          );
        }
      }

      // 命中率サマリー
      _report('\n------------------------------------------------------------');
      _report('フィールド    命中/合計  命中率');
      _report('------------------------------------------------------------');
      for (final fieldName in fieldNames) {
        final hits = fieldHits[fieldName] ?? 0;
        final total = fieldTotal[fieldName] ?? 0;
        final rate = total > 0
            ? (hits / total * 100).toStringAsFixed(1)
            : '0.0';
        _report('${fieldName.padRight(12)} $hits/$total   $rate%');
      }
      _report('------------------------------------------------------------');
      final overallRate = totalFields > 0
          ? (hitFields / totalFields * 100).toStringAsFixed(1)
          : '0.0';
      _report('全体: $hitFields/$totalFields  命中率 $overallRate%');
      _report('============================================================\n');

      await engine.dispose();
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('4. 既存30枚 JPG を同パイプライン経路で計測・scr 9枚との有効抽出率比較', () async {
      final preprocessor = InputPreprocessor();
      final engine = MlKitOcrEngine(defaultScript: MlKitScript.latin);
      final pipeline = OcrPipeline(engine: engine);

      final dir = Directory(_playshareDir);
      final jpgFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(jpgFiles.length, equals(30));

      final fieldKinds = <String, NumericFieldKind>{
        'score': NumericFieldKind.score,
        'cool': NumericFieldKind.cool,
        'great': NumericFieldKind.great,
        'good': NumericFieldKind.good,
        'bad': NumericFieldKind.bad,
        'maxCombo': NumericFieldKind.maxCombo,
        'level': NumericFieldKind.level,
      };

      final fieldNames = fieldKinds.keys.toList();
      final fieldValid = <String, int>{};
      int totalFields = 0;
      int validFields = 0;

      _report('\n=== ST-1 既存30枚 JPG パイプライン有効抽出率（クロップ解像度比較用） ===');

      for (final file in jpgFiles) {
        final cls = preprocessor.classify(file.readAsBytesSync());
        expect(
          cls,
          equals(InputImageClass.landscapePlayShare),
          reason: '${file.uri.pathSegments.last}: 分類エラー',
        );

        final context = await pipeline.run(file.readAsBytesSync());
        final extractionResult = context.extractionResult;

        for (final fieldName in fieldNames) {
          final kind = fieldKinds[fieldName]!;
          final extracted = extractionResult?.field(kind);

          final isValid = extracted != null && extracted.isValid;

          fieldValid[fieldName] =
              (fieldValid[fieldName] ?? 0) + (isValid ? 1 : 0);
          totalFields++;
          if (isValid) validFields++;
        }

        _report(
          '  ${file.uri.pathSegments.last}: '
          'score=${extractionResult?.field(NumericFieldKind.score)?.value ?? '-'} '
          'cool=${extractionResult?.field(NumericFieldKind.cool)?.value ?? '-'} '
          'great=${extractionResult?.field(NumericFieldKind.great)?.value ?? '-'} '
          'good=${extractionResult?.field(NumericFieldKind.good)?.value ?? '-'} '
          'bad=${extractionResult?.field(NumericFieldKind.bad)?.value ?? '-'} '
          'maxCombo=${extractionResult?.field(NumericFieldKind.maxCombo)?.value ?? '-'} '
          'level=${extractionResult?.field(NumericFieldKind.level)?.value ?? '-'}',
        );
      }

      _report('\n------------------------------------------------------------');
      _report('フィールド   有効抽出/30枚  有効抽出率');
      _report('------------------------------------------------------------');
      for (final fieldName in fieldNames) {
        final valid = fieldValid[fieldName] ?? 0;
        final rate = (valid / 30 * 100).toStringAsFixed(1);
        _report('${fieldName.padRight(12)} $valid/30   $rate%');
      }
      _report('------------------------------------------------------------');
      final overallRate = totalFields > 0
          ? (validFields / totalFields * 100).toStringAsFixed(1)
          : '0.0';
      _report('全体: $validFields/$totalFields  有効抽出率 $overallRate%');
      _report('============================================================\n');

      await engine.dispose();
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
