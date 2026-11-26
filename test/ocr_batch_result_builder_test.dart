// バッチ OCR 精度測定ツールの純 Dart ロジックのユニットテスト。
//
// integration_test/ocr_batch_test.dart は端末でのみ実行可能なため、
// JSON 組み立て部分を integration_test/ocr_batch_result_builder.dart に
// 切り出し、ホスト上の flutter test で検証できるようにしている。

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';

import '../integration_test/ocr_batch_result_builder.dart';

void main() {
  group('ocrElementToJson', () {
    test('text / boundingBox(l,t,r,b) / confidence を出力する', () {
      final json = ocrElementToJson(
        OcrElement(
          text: 'GOOD',
          boundingBox: Rect.fromLTRB(10, 20, 110, 40),
          confidence: 0.95,
        ),
      );

      expect(json['text'], 'GOOD');
      expect(json['confidence'], 0.95);
      final boundingBox = json['boundingBox']! as Map<String, Object?>;
      expect(boundingBox['l'], 10.0);
      expect(boundingBox['t'], 20.0);
      expect(boundingBox['r'], 110.0);
      expect(boundingBox['b'], 40.0);
    });

    test('confidence 不明のセンチネル値をそのまま保持する', () {
      final json = ocrElementToJson(
        OcrElement(
          text: 'x',
          boundingBox: Rect.fromLTRB(0, 0, 1, 1),
          confidence: OcrElement.confidenceUnknown,
        ),
      );

      expect(json['confidence'], OcrElement.confidenceUnknown);
    });
  });

  group('OcrBatchImageResult', () {
    test('成功レコードが JSON ラウンドトリップする', () {
      final result = OcrBatchImageResult(
        file: 'a.jpg',
        elementCount: 1,
        elements: <Map<String, Object?>>[
          ocrElementToJson(
            OcrElement(
              text: 'MEDAL',
              boundingBox: Rect.fromLTRB(1, 2, 3, 4),
              confidence: 0.9,
            ),
          ),
        ],
        fullText: 'MEDAL',
        elapsedMs: 123,
      );

      expect(result.isSuccess, isTrue);

      final decoded = jsonDecode(result.encodeJson()) as Map<String, Object?>;
      expect(decoded['file'], 'a.jpg');
      expect(decoded['elementCount'], 1);
      expect(decoded['fullText'], 'MEDAL');
      expect(decoded['elapsedMs'], 123);
      expect(decoded.containsKey('error'), isFalse);

      final elements = decoded['elements']! as List<Object?>;
      expect(elements, hasLength(1));
      final boundingBox =
          (elements.first! as Map<String, Object?>)['boundingBox']!
              as Map<String, Object?>;
      expect(boundingBox['l'], 1.0);
      expect(boundingBox['t'], 2.0);
      expect(boundingBox['r'], 3.0);
      expect(boundingBox['b'], 4.0);
    });

    test('失敗レコードは error を持ち elements が空', () {
      final result = OcrBatchImageResult(
        file: 'b.jpg',
        elementCount: 0,
        elements: const <Map<String, Object?>>[],
        fullText: '',
        elapsedMs: 5,
        error: 'OcrEngineException: boom',
      );

      expect(result.isSuccess, isFalse);

      final decoded = jsonDecode(result.encodeJson()) as Map<String, Object?>;
      expect(decoded['error'], 'OcrEngineException: boom');
      expect(decoded['elementCount'], 0);
      expect(decoded['elements'], isEmpty);
    });
  });

  group('buildSummary', () {
    test('成功数・エラー数・平均 confidence・合計時間を集計する', () {
      final results = <OcrBatchImageResult>[
        OcrBatchImageResult(
          file: 'a.jpg',
          elementCount: 2,
          elements: <Map<String, Object?>>[
            ocrElementToJson(
              OcrElement(
                text: 'a1',
                boundingBox: Rect.fromLTRB(0, 0, 1, 1),
                confidence: 0.8,
              ),
            ),
            ocrElementToJson(
              OcrElement(
                text: 'a2',
                boundingBox: Rect.fromLTRB(0, 0, 1, 1),
                confidence: 0.6,
              ),
            ),
          ],
          fullText: 'a1 a2',
          elapsedMs: 100,
        ),
        OcrBatchImageResult(
          file: 'b.jpg',
          elementCount: 0,
          elements: const <Map<String, Object?>>[],
          fullText: '',
          elapsedMs: 50,
          error: 'boom',
        ),
      ];

      final summary = buildSummary(results);

      expect(summary.totalImages, 2);
      expect(summary.successCount, 1);
      expect(summary.errorCount, 1);
      expect(summary.avgConfidence, closeTo(0.7, 1e-9));
      expect(summary.unknownConfidenceCount, 0);
      expect(summary.totalElapsedMs, 150);
    });

    test('confidence 未取得の要素は unknownConfidenceCount に数える', () {
      final results = <OcrBatchImageResult>[
        OcrBatchImageResult(
          file: 'a.jpg',
          elementCount: 3,
          elements: <Map<String, Object?>>[
            ocrElementToJson(
              OcrElement(
                text: 'a1',
                boundingBox: Rect.fromLTRB(0, 0, 1, 1),
                confidence: 0.5,
              ),
            ),
            ocrElementToJson(
              OcrElement(
                text: 'a2',
                boundingBox: Rect.fromLTRB(0, 0, 1, 1),
                confidence: OcrElement.confidenceUnknown,
              ),
            ),
            // confidence キー自体が無いデータも unknown 扱い。
            <String, Object?>{
              'text': 'a3',
              'boundingBox': <String, Object?>{
                'l': 0.0,
                't': 0.0,
                'r': 1.0,
                'b': 1.0,
              },
            },
          ],
          fullText: 'a1 a2 a3',
          elapsedMs: 10,
        ),
      ];

      final summary = buildSummary(results);

      expect(summary.unknownConfidenceCount, 2);
      expect(summary.avgConfidence, 0.5);
    });

    test('confidence が 1 件も取得できないと avgConfidence は null', () {
      final results = <OcrBatchImageResult>[
        OcrBatchImageResult(
          file: 'a.jpg',
          elementCount: 0,
          elements: const <Map<String, Object?>>[],
          fullText: '',
          elapsedMs: 10,
        ),
      ];

      final summary = buildSummary(results);

      expect(summary.totalImages, 1);
      expect(summary.successCount, 1);
      expect(summary.avgConfidence, isNull);
      expect(summary.unknownConfidenceCount, 0);
      expect(summary.totalElapsedMs, 10);
    });
  });

  group('encodeBatchReport', () {
    test('サマリと結果を含む pretty JSON を生成する', () {
      final results = <OcrBatchImageResult>[
        OcrBatchImageResult(
          file: 'a.jpg',
          elementCount: 1,
          elements: <Map<String, Object?>>[
            ocrElementToJson(
              OcrElement(
                text: 'EX',
                boundingBox: Rect.fromLTRB(2, 3, 4, 5),
                confidence: 0.99,
              ),
            ),
          ],
          fullText: 'EX',
          elapsedMs: 20,
        ),
      ];
      final summary = buildSummary(results);

      final report = encodeBatchReport(
        results: results,
        summary: summary,
        script: 'MlKitScript.japanese',
        imageDir: '/data/local/tmp/poc',
        generatedAt: DateTime.utc(2026, 11, 21, 12, 0, 0),
      );

      final decoded = jsonDecode(report) as Map<String, Object?>;
      expect(decoded['generatedAt'], '2026-11-21T12:00:00.000Z');
      expect(decoded['script'], 'MlKitScript.japanese');
      expect(decoded['imageDir'], '/data/local/tmp/poc');
      expect(decoded['summary'], <String, Object?>{
        'totalImages': 1,
        'successCount': 1,
        'errorCount': 0,
        'avgConfidence': 0.99,
        'unknownConfidenceCount': 0,
        'totalElapsedMs': 20,
      });
      expect(decoded['results']! as List<Object?>, hasLength(1));
      // pretty print（インデント付き）であること。
      expect(report, contains('\n  "summary"'));
    });
  });
}
