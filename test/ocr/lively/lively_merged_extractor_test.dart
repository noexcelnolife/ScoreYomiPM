// Lively 統合（3 パス突き合わせ）の単体テスト。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/lively/lively_geometry.dart';
import 'package:scoreyomipm/ocr/lively/lively_merged_extractor.dart';
import 'package:scoreyomipm/ocr/lively/lively_value_parser.dart';

OcrElement _element({double confidence = 0.9}) => OcrElement(
  text: '1',
  boundingBox: const Rect.fromLTRB(0, 0, 10, 10),
  confidence: confidence,
);

LivelyRead _read(LivelyRow row, int value, {double confidence = 0.9}) =>
    LivelyRead(
      row: row,
      value: value,
      raw: '$value',
      evidence: <OcrElement>[_element(confidence: confidence)],
      boundingBox: const Rect.fromLTRB(0, 0, 10, 10),
    );

void main() {
  const extractor = LivelyMergedExtractor();

  test('両パス一致ならその値を採る', () {
    final result = extractor.extract(
      panel: {LivelyRow.cool: _read(LivelyRow.cool, 123)},
      counterBlock: {LivelyRow.cool: _read(LivelyRow.cool, 123)},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 2,
    );

    expect(result.numericFields[NumericFieldKind.cool]!.value, 123);
  });

  test('片側にしか値が無ければ採る側の値を使う', () {
    final result = extractor.extract(
      panel: {LivelyRow.cool: _read(LivelyRow.cool, 123)},
      counterBlock: {LivelyRow.great: _read(LivelyRow.great, 45)},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 2,
    );

    expect(result.numericFields[NumericFieldKind.cool]!.value, 123);
    expect(result.numericFields[NumericFieldKind.great]!.value, 45);
  });

  test('食い違ったらパネル側を採る（計測時の規則）', () {
    final result = extractor.extract(
      panel: {LivelyRow.bad: _read(LivelyRow.bad, 6)},
      counterBlock: {LivelyRow.bad: _read(LivelyRow.bad, 8)},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 2,
    );

    expect(result.numericFields[NumericFieldKind.bad]!.value, 6);
  });

  test('スコアは専用パスを優先する', () {
    final result = extractor.extract(
      panel: {LivelyRow.score: _read(LivelyRow.score, 98765)},
      counterBlock: const {},
      comboBlock: const {},
      scoreBlock: {LivelyRow.score: _read(LivelyRow.score, 98766)},
      sourceElementCount: 2,
    );

    expect(result.numericFields[NumericFieldKind.score]!.value, 98766);
  });

  test('スコアの片側欠けはパネル側で補う', () {
    final result = extractor.extract(
      panel: {LivelyRow.score: _read(LivelyRow.score, 98765)},
      counterBlock: const {},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 1,
    );

    expect(result.numericFields[NumericFieldKind.score]!.value, 98765);
  });

  test('どちらにも無ければフィールド自体を作らない', () {
    final result = extractor.extract(
      panel: const {},
      counterBlock: const {},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 0,
    );

    expect(result.numericFields, isEmpty);
  });

  test('COMBO は 2 行ブロックと突き合わせる', () {
    final result = extractor.extract(
      panel: const {},
      counterBlock: const {},
      comboBlock: {LivelyRow.combo: _read(LivelyRow.combo, 120)},
      scoreBlock: const {},
      sourceElementCount: 1,
    );

    expect(result.numericFields[NumericFieldKind.maxCombo]!.value, 120);
  });

  test('範囲外の値は採用するが isValid=false とメッセージを付ける', () {
    final result = extractor.extract(
      panel: {LivelyRow.cool: _read(LivelyRow.cool, 123456)},
      counterBlock: const {},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 1,
    );

    final field = result.numericFields[NumericFieldKind.cool]!;
    expect(field.value, 123456);
    expect(field.isValid, isFalse);
    expect(field.validationMessage, isNotNull);
  });

  test('信頼度不明の要素が混ざれば不明を保つ（低い値と偽装しない）', () {
    final result = extractor.extract(
      panel: {
        LivelyRow.cool: _read(
          LivelyRow.cool,
          10,
          confidence: OcrElement.confidenceUnknown,
        ),
      },
      counterBlock: const {},
      comboBlock: const {},
      scoreBlock: const {},
      sourceElementCount: 1,
    );

    expect(
      result.numericFields[NumericFieldKind.cool]!.confidence,
      OcrElement.confidenceUnknown,
    );
  });
}
