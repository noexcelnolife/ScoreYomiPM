// OCR 共通データモデル（lib/models/ocr_models.dart）と
// OCR パイプライン ST-4 パススルー（lib/ocr/pipeline.dart）のユニットテスト。
//
// ML Kit 実装（MlKitOcrEngine）は platform channel 依存のためユニットテスト
// では扱わず、抽象インターフェース OcrEngine の fake を注入して
// パイプラインとの結合を検証する（spec.md §7.3 OCR抽象レイヤー）。

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

import 'test_image_helper.dart';

/// recognize / recognizeRegion の呼び出しを記録し、固定結果または例外を
/// 返す fake エンジン。
class _FakeOcrEngine implements OcrEngine {
  _FakeOcrEngine({this.result, this.exception});

  /// recognize が成功した場合に返す結果。
  final OcrPageResult? result;

  /// recognize が失敗した場合に投げる例外。
  final Object? exception;

  int callCount = 0;
  Uint8List? lastImageBytes;

  /// recognizeRegion の呼び出し記録（Wave 2 の TDD で検証する）。
  // WHY contrastRetry を記録対象に追加（docs/st5_f2_g_contrast_preprocess_
  // design_confirmation_2026-11-22.md・docs コミット 18b2111・リード承認済み）:
  // 狭帯 crop 前処理再試行フラグの pass-through 検証のため（red 段階では
  // runner 未実装で常に default false を記録する）。
  final List<
    ({
      Uint8List encodedImageBytes,
      Rect region,
      OcrScript script,
      double pixelScale,
      bool contrastRetry,
    })
  >
  regionCalls = [];

  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    callCount++;
    lastImageBytes = encodedImageBytes;
    final error = exception;
    if (error != null) {
      throw error;
    }
    return result ?? OcrPageResult.empty();
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    regionCalls.add((
      encodedImageBytes: encodedImageBytes,
      region: region,
      script: script,
      pixelScale: pixelScale,
      contrastRetry: contrastRetry,
    ));
    final error = exception;
    if (error != null) {
      throw error;
    }
    return result ?? OcrPageResult.empty();
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('OcrElement', () {
    const rect = Rect.fromLTWH(10, 20, 100, 30);

    test('生成・プロパティが正しく設定される', () {
      const element = OcrElement(
        text: '1,234,567',
        boundingBox: rect,
        confidence: 0.92,
      );

      expect(element.text, '1,234,567');
      expect(element.boundingBox, rect);
      expect(element.confidence, 0.92);
      expect(element.hasUnknownConfidence, isFalse);
    });

    test('confidenceUnknown は信頼度不明のセンチネル値（-1.0）として扱われる', () {
      expect(OcrElement.confidenceUnknown, -1.0);

      const element = OcrElement(
        text: 'オルビス',
        boundingBox: rect,
        confidence: OcrElement.confidenceUnknown,
      );

      expect(element.hasUnknownConfidence, isTrue);
    });

    test('copyWith は指定フィールドのみ更新し、他のフィールドは維持する', () {
      const element = OcrElement(
        text: '1,234,567',
        boundingBox: rect,
        confidence: 0.92,
      );

      final updatedText = element.copyWith(text: '1.234.567');
      expect(updatedText.text, '1.234.567');
      expect(updatedText.boundingBox, element.boundingBox);
      expect(updatedText.confidence, element.confidence);

      final updatedConfidence = element.copyWith(confidence: 0.5);
      expect(updatedConfidence.text, element.text);
      expect(updatedConfidence.boundingBox, element.boundingBox);
      expect(updatedConfidence.confidence, 0.5);

      final unknown = updatedConfidence.copyWith(
        confidence: OcrElement.confidenceUnknown,
      );
      expect(unknown.hasUnknownConfidence, isTrue);
    });

    test('同値性: 同じフィールドを持つ要素は等しく、hashCode も一致する', () {
      const a = OcrElement(text: 'EX', boundingBox: rect, confidence: 0.9);
      const b = OcrElement(text: 'EX', boundingBox: rect, confidence: 0.9);
      const c = OcrElement(text: 'EX', boundingBox: rect, confidence: 0.8);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('boundingBox が異なる要素は等しくない', () {
      const a = OcrElement(text: 'EX', boundingBox: rect, confidence: 0.9);
      const b = OcrElement(
        text: 'EX',
        boundingBox: Rect.fromLTWH(0, 0, 1, 1),
        confidence: 0.9,
      );

      expect(a, isNot(equals(b)));
    });
  });

  group('OcrPageResult', () {
    test('生成・プロパティが正しく設定される', () {
      const element = OcrElement(
        text: 'オルビス',
        boundingBox: Rect.fromLTWH(0, 0, 50, 20),
        confidence: 0.85,
      );
      const result = OcrPageResult(
        elements: [element],
        fullText: 'オルビス\n1,234,567',
      );

      expect(result.elements, hasLength(1));
      expect(result.elements.first.text, 'オルビス');
      expect(result.fullText, 'オルビス\n1,234,567');
      expect(result.isEmpty, isFalse);
    });

    test('empty() は空の結果を表す', () {
      const result = OcrPageResult.empty();

      expect(result.elements, isEmpty);
      expect(result.fullText, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('同値性と hashCode が正しく動作する', () {
      const e1 = OcrElement(
        text: 'EX',
        boundingBox: Rect.fromLTWH(0, 0, 10, 10),
        confidence: 0.9,
      );
      const a = OcrPageResult(elements: [e1], fullText: 'EX');
      const b = OcrPageResult(elements: [e1], fullText: 'EX');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(OcrPageResult.empty())));
    });

    test('画像寸法は既定で null（既存呼び出し側との互換性維持）', () {
      // WHY: OcrPageResult に寸法を追加した際、テスト用 fake engine 等の
      // 既存の構築側を壊さないため optional named にしている。実エンジンは
      // decode 時に必ず設定する（単一情報源は doc 参照）。
      const result = OcrPageResult(elements: [], fullText: '');

      expect(result.imageWidth, isNull);
      expect(result.imageHeight, isNull);
      expect(OcrPageResult.empty().imageWidth, isNull);
      expect(OcrPageResult.empty().imageHeight, isNull);
    });

    test('画像寸法を保持し、同値性 / hashCode に反映される', () {
      // 同一要素列でも寸法が異なれば正規化座標が変わるため、寸法は
      // 結果の同一性に含まれる（== / hashCode に含める理由は doc 参照）。
      const a = OcrPageResult(
        elements: [],
        fullText: 'EX',
        imageWidth: 1200,
        imageHeight: 800,
      );
      const sameDims = OcrPageResult(
        elements: [],
        fullText: 'EX',
        imageWidth: 1200,
        imageHeight: 800,
      );
      const otherWidth = OcrPageResult(
        elements: [],
        fullText: 'EX',
        imageWidth: 900,
        imageHeight: 800,
      );
      const otherHeight = OcrPageResult(
        elements: [],
        fullText: 'EX',
        imageWidth: 1200,
        imageHeight: 600,
      );

      expect(a, equals(sameDims));
      expect(a.hashCode, equals(sameDims.hashCode));
      expect(a, isNot(equals(otherWidth)));
      expect(a, isNot(equals(otherHeight)));
      expect(
        a,
        isNot(equals(const OcrPageResult(elements: [], fullText: 'EX'))),
      );
    });

    test('同値性: 同要素数でも内容が異なる結果は等しくない（F-A 回帰テスト）', () {
      // WHY: かつて OcrPageResult.== は elements.length のみを比較して
      // いたため、要素数が同じで内容が違う結果が誤って「等しい」と判定
      // され、hashCode（要素内容から計算）との契約違反になっていた。
      // 深い比較（listEquals）修正後もこのケースが等しくならないことを
      // 固定するための回帰テスト。
      const base = OcrElement(
        text: 'EX',
        boundingBox: Rect.fromLTWH(0, 0, 10, 10),
        confidence: 0.9,
      );
      const diffText = OcrElement(
        text: 'MISS',
        boundingBox: Rect.fromLTWH(0, 0, 10, 10),
        confidence: 0.9,
      );
      const diffBoundingBox = OcrElement(
        text: 'EX',
        boundingBox: Rect.fromLTWH(5, 5, 10, 10),
        confidence: 0.9,
      );
      const diffConfidence = OcrElement(
        text: 'EX',
        boundingBox: Rect.fromLTWH(0, 0, 10, 10),
        confidence: 0.8,
      );

      expect(
        const OcrPageResult(elements: [base], fullText: 'EX'),
        isNot(
          equals(const OcrPageResult(elements: [diffText], fullText: 'EX')),
        ),
      );
      expect(
        const OcrPageResult(elements: [base], fullText: 'EX'),
        isNot(
          equals(
            const OcrPageResult(elements: [diffBoundingBox], fullText: 'EX'),
          ),
        ),
      );
      expect(
        const OcrPageResult(elements: [base], fullText: 'EX'),
        isNot(
          equals(
            const OcrPageResult(elements: [diffConfidence], fullText: 'EX'),
          ),
        ),
      );
      // 順序が異なる場合も等しくない（listEquals は順序を含めて比較する）。
      expect(
        const OcrPageResult(elements: [base, diffText], fullText: 'EX MISS'),
        isNot(
          equals(
            const OcrPageResult(
              elements: [diffText, base],
              fullText: 'EX MISS',
            ),
          ),
        ),
      );
    });

    test('信頼度不明の要素を含む結果も同値性で扱える', () {
      const unknown1 = OcrElement(
        text: 'オルビス',
        boundingBox: Rect.fromLTWH(0, 0, 50, 20),
        confidence: OcrElement.confidenceUnknown,
      );
      const unknown2 = OcrElement(
        text: 'オルビス',
        boundingBox: Rect.fromLTWH(0, 0, 50, 20),
        confidence: OcrElement.confidenceUnknown,
      );

      expect(unknown1, equals(unknown2));
      expect(
        OcrPageResult(elements: [unknown1], fullText: 'オルビス'),
        equals(const OcrPageResult(elements: [unknown2], fullText: 'オルビス')),
      );
    });
  });

  group('OcrPipeline（ST-4）', () {
    test('run() は ST-4 でエンジンを 1 回だけ呼び、生結果を context に渡す', () async {
      // スコアのペア（SCORE ラベル + 同一行・右側列の値）。ラベル中心
      // (0.5783, 0.4763)・値中心 (0.8316, 0.4763) は実測ジオメトリ
      // （field_extractor_test.dart のスコア系テストと同一）。
      const label = OcrElement(
        text: 'SCORE',
        boundingBox: Rect.fromLTWH(660, 373, 68, 16),
        confidence: 0.95,
      );
      const value = OcrElement(
        text: '1,234,567',
        boundingBox: Rect.fromLTWH(970, 373, 56, 16),
        confidence: 0.95,
      );
      const pageResult = OcrPageResult(
        elements: [label, value],
        fullText: 'SCORE 1,234,567',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _FakeOcrEngine(result: pageResult);
      final pipeline = OcrPipeline(engine: engine);
      final imageBytes = createTestImageBytes();

      final context = await pipeline.run(imageBytes);

      expect(engine.callCount, 1);
      // WHY(バイト列を検証するか): エンジンの契約がバイト列入力になったため、
      // パイプラインが画像バイト列を渡していることだけを見る。
      expect(engine.lastImageBytes, isNotNull);
      expect(context.pageResult, equals(pageResult));
      expect(context.imageBytes, same(imageBytes));
      // Step 0 で接続済み（タスク 01a20108）: 寸法つきの結果から
      // FieldExtractor によるフィールド化結果が設定される。
      expect(context.extractionResult, isNotNull);
      expect(
        context.extractionResult!.field(NumericFieldKind.score)!.value,
        1234567,
      );
    });

    test('寸法を設定しないエンジン結果では抽出をスキップし null のまま（FR-3 フォールバック維持）', () async {
      // WHY: パイプラインは寸法欠落（fake engine・実装ミス）でも止まらず、
      // extractionResult を null に保つ。FR-3 側は null を「未抽出」として
      // 要素一覧へフォールバックするため UI は壊れない。
      const element = OcrElement(
        text: '1,234,567',
        boundingBox: Rect.fromLTWH(10, 10, 80, 20),
        confidence: 0.95,
      );
      final engine = _FakeOcrEngine(
        result: OcrPageResult(elements: [element], fullText: '1,234,567'),
      );
      final pipeline = OcrPipeline(engine: engine);

      final context = await pipeline.run(createTestImageBytes());

      expect(context.pageResult, isNotNull);
      expect(context.extractionResult, isNull);
    });

    test('エンジンが失敗した場合は例外がそのまま伝播する', () async {
      final engine = _FakeOcrEngine(
        exception: const OcrEngineException('OCR failed'),
      );
      final pipeline = OcrPipeline(engine: engine);

      await expectLater(
        pipeline.run(createTestImageBytes()),
        throwsA(isA<OcrEngineException>()),
      );
    });
  });

  group('OcrPipelineContext', () {
    test('imageBytes を保持し、pageResult / extractionResult の初期値は null', () {
      final imageBytes = createTestImageBytes();

      final context = OcrPipelineContext(imageBytes: imageBytes);

      expect(context.imageBytes, same(imageBytes));
      expect(context.pageResult, isNull);
      expect(context.extractionResult, isNull);
    });

    test('pageResult への代入で ST-4 の結果を保持できる', () {
      const element = OcrElement(
        text: 'オルビス',
        boundingBox: Rect.fromLTWH(0, 0, 50, 20),
        confidence: 0.9,
      );
      const updated = OcrPageResult(elements: [element], fullText: 'オルビス');

      final context = OcrPipelineContext(imageBytes: createTestImageBytes());
      context.pageResult = updated;

      expect(context.pageResult, equals(updated));
    });
  });

  group('OcrEngineException', () {
    test('message と cause を保持し、toString に反映される', () {
      const withoutCause = OcrEngineException('OCR failed');
      expect(withoutCause.message, 'OCR failed');
      expect(withoutCause.cause, isNull);
      expect(withoutCause.toString(), contains('OCR failed'));

      final cause = StateError('native error');
      final withCause = OcrEngineException('OCR failed', cause: cause);
      expect(withCause.cause, same(cause));
      expect(withCause.toString(), contains('(cause:'));
    });
  });
}
