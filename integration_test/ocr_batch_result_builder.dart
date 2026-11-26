// 純 Dart のバッチ OCR 結果組み立てロジック。
//
// integration_test/ocr_batch_test.dart（バッチ OCR 精度測定ツール）から使う
// JSON 組み立て処理を、Flutter / プラグイン非依存の pure Dart としてここに
// 切り出している。ホスト上の `flutter test` でユニットテスト可能
// （test/ocr_batch_result_builder_test.dart 参照）。
//
// 出力 JSON スキーマは README「バッチOCR精度測定ツール（integration test）」
// の節を参照。

import 'dart:convert';

import 'package:scoreyomipm/models/ocr_models.dart';

/// 1 画像分の測定結果。
class OcrBatchImageResult {
  /// [error] は OCR 失敗時のみ非 null（成功時は null）。
  OcrBatchImageResult({
    required this.file,
    required this.elementCount,
    required this.elements,
    required this.fullText,
    required this.elapsedMs,
    this.error,
  });

  /// 画像ファイル名（ディレクトリ部分を除く）。
  final String file;

  /// 認識できた要素数（失敗時は 0）。
  final int elementCount;

  /// 認識要素（ocrElementToJson の出力）。
  final List<Map<String, Object?>> elements;

  /// ページ全体の連結テキスト（失敗時は空文字列）。
  final String fullText;

  /// recognize() 1 回の所要時間（ミリ秒）。
  final int elapsedMs;

  /// OCR 失敗時のエラー内容（成功時は null）。
  final String? error;

  /// OCR が成功したか。
  bool get isSuccess => error == null;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'file': file,
      'elementCount': elementCount,
      'elements': elements,
      'fullText': fullText,
      'elapsedMs': elapsedMs,
      if (error != null) 'error': error,
    };
  }

  /// 1 画像分の JSON 文字列（stdout 出力用）。
  String encodeJson() => jsonEncode(toJson());
}

/// バッチ全体のサマリ。
class OcrBatchSummary {
  OcrBatchSummary({
    required this.totalImages,
    required this.successCount,
    required this.errorCount,
    required this.avgConfidence,
    required this.unknownConfidenceCount,
    required this.totalElapsedMs,
  });

  /// 処理した画像数。
  final int totalImages;

  /// OCR 成功数。
  final int successCount;

  /// OCR 失敗数。
  final int errorCount;

  /// 取得できた confidence のみの平均（1 件もなければ null）。
  final double? avgConfidence;

  /// confidence を取得できなかった要素数（センチネル値の件数）。
  final int unknownConfidenceCount;

  /// 全画像の elapsedMs 合計。
  final int totalElapsedMs;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'totalImages': totalImages,
      'successCount': successCount,
      'errorCount': errorCount,
      'avgConfidence': avgConfidence,
      'unknownConfidenceCount': unknownConfidenceCount,
      'totalElapsedMs': totalElapsedMs,
    };
  }
}

/// [OcrElement] を測定結果用の JSON マップに変換する。
///
/// boundingBox は left / top / right / bottom を l / t / r / b として出力する。
Map<String, Object?> ocrElementToJson(OcrElement element) {
  return <String, Object?>{
    'text': element.text,
    'boundingBox': <String, Object?>{
      'l': element.boundingBox.left,
      't': element.boundingBox.top,
      'r': element.boundingBox.right,
      'b': element.boundingBox.bottom,
    },
    'confidence': element.confidence,
  };
}

/// 測定結果リストからサマリを集計する。
OcrBatchSummary buildSummary(List<OcrBatchImageResult> results) {
  var successCount = 0;
  var unknownConfidenceCount = 0;
  var confidenceSum = 0.0;
  var confidenceCount = 0;
  var totalElapsedMs = 0;

  for (final result in results) {
    if (result.isSuccess) {
      successCount++;
    }
    totalElapsedMs += result.elapsedMs;
    for (final element in result.elements) {
      final confidence = element['confidence'];
      if (confidence is num) {
        if (confidence == OcrElement.confidenceUnknown) {
          unknownConfidenceCount++;
        } else {
          confidenceSum += confidence;
          confidenceCount++;
        }
      } else {
        unknownConfidenceCount++;
      }
    }
  }

  return OcrBatchSummary(
    totalImages: results.length,
    successCount: successCount,
    errorCount: results.length - successCount,
    avgConfidence: confidenceCount > 0 ? confidenceSum / confidenceCount : null,
    unknownConfidenceCount: unknownConfidenceCount,
    totalElapsedMs: totalElapsedMs,
  );
}

/// バッチ全体のレポート JSON を生成する（インデント付き pretty print）。
String encodeBatchReport({
  required List<OcrBatchImageResult> results,
  required OcrBatchSummary summary,
  required String script,
  required String imageDir,
  DateTime? generatedAt,
}) {
  final report = <String, Object?>{
    'generatedAt': (generatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'script': script,
    'imageDir': imageDir,
    'summary': summary.toJson(),
    'results': results.map((result) => result.toJson()).toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(report);
}
