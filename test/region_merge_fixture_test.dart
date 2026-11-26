// Wave 2 フォールバック専用セマンティクス：30枚プレーシェアフィクスチャ検証
// 実測した playshare_region_ocr_results.json の region OCR 結果を extractWithRegions に
// 再投入し、クロップ由来フィールドの値が実測 merged 値と一致することを検証する
// （マージロジックの決定性回帰テスト）。
// full 由来（merged == full 値）は full 側の生要素が fixture に無いため再現不可 → skip。
// 関数≤50行・CC≤15・WHYコメント必須（AIDD規約）。

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

const String _fixturePath =
    'test/fixtures/ocr/playshare_region_ocr_results.json';

/// fixture の 1 画像分から RegionTarget → クロップ OCR 結果を復元する。
///
/// WHY: fixture の regions にはクロップ OCR の生要素が入っており、
/// これをそのまま OcrPageResult に復元することでマージ入力を実測と同一にする。
Map<RegionTarget, OcrPageResult> _buildRegionResults(
  Map<String, dynamic> entry,
) {
  final imageWidth = (entry['imageWidth'] as num).toInt();
  final imageHeight = (entry['imageHeight'] as num).toInt();
  final regions = entry['regions'] as List;
  final regionResults = <RegionTarget, OcrPageResult>{};
  for (final region in regions) {
    final target = RegionTarget.values.byName(region['target'] as String);
    final elements = (region['elements'] as List)
        .map(
          (e) => OcrElement(
            text: e['text'] as String,
            boundingBox: Rect.fromLTRB(
              (e['boundingBox']['l'] as double),
              (e['boundingBox']['t'] as double),
              (e['boundingBox']['r'] as double),
              (e['boundingBox']['b'] as double),
            ),
            confidence: (e['confidence'] as num).toDouble(),
          ),
        )
        .toList();
    regionResults[target] = OcrPageResult(
      elements: elements,
      fullText: elements.map((e) => e.text).join(' '),
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }
  return regionResults;
}

/// クロップ由来フィールドについて、replay 結果の値が実測 merged 値と一致することを検証する。
///
/// WHY: クロップ由来判定は「full 値が無い OR merged ≠ full」。この場合、full が空の
/// replay では必ずクロップ値が採用されるため、値の一致がマージロジックの正しさを直接示す。
/// full 由来（merged == full 値）はクロップが合意値か競合値かを fixture から判別できない
/// ため検証対象外とする（マージの full 側は別の単体テストで担保）。
void _assertCropDerivedValues(
  FieldExtractor extractor,
  Map<String, dynamic> entry,
) {
  final fileName = entry['file'] as String? ?? '(unknown)';
  final imageWidth = (entry['imageWidth'] as num).toInt();
  final imageHeight = (entry['imageHeight'] as num).toInt();
  final mergedValues = entry['mergedFieldValues'] as Map<String, dynamic>;
  final fullValues = entry['fullFieldValues'] as Map<String, dynamic>?;
  final regionResults = _buildRegionResults(entry);
  final emptyPage = OcrPageResult(
    elements: const [],
    fullText: '',
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  final result = extractor.extractWithRegions(emptyPage, regionResults);

  for (final kind in NumericFieldKind.values) {
    final mergedEntry = mergedValues[kind.name];
    if (mergedEntry == null || mergedEntry is! Map) continue;
    final mergedValueRaw = mergedEntry['value'];
    if (mergedValueRaw == null) continue;
    final mergedValue = (mergedValueRaw as num).toInt();

    final fullEntry = fullValues?[kind.name];
    final hasFull =
        fullEntry != null && fullEntry is Map && fullEntry['value'] != null;
    final fullValue = hasFull ? (fullEntry['value'] as num).toInt() : null;
    final isCropDerived = !hasFull || mergedValue != fullValue;
    if (!isCropDerived) continue;

    final extracted = result.numericFields[kind];
    expect(
      extracted,
      isNotNull,
      reason: '$fileName ${kind.name}: クロップ由来の値が再現できていない',
    );
    expect(
      extracted!.value,
      equals(mergedValue),
      reason: '$fileName ${kind.name}: マージ結果が実測 merged 値と不一致',
    );
  }
}

/// fixture 自身の検出数が承認済みベースラインと一致することを検証する。
///
/// WHY: ベースライン（637e845 承認: good=23, bad=24, level=9, score5Digit=28）は
/// 実測の成果物。fixture が差し替えられた場合に気づけるようにする自己整合ガード。
void _assertBaselineCounts(List<dynamic> fixture) {
  var good = 0, bad = 0, level = 0, score5Digit = 0;
  for (final entry in fixture) {
    // WHY: fixture 配列の末尾には集計エントリ（mergedFieldValues 無し）が含まれる。
    // null キャストで落ちないよう null 安全に読み、集計エントリはカウント対象外とする。
    final mergedValues = entry['mergedFieldValues'] as Map<String, dynamic>?;
    if (mergedValues == null) continue;
    if (mergedValues.containsKey(NumericFieldKind.good.name)) good++;
    if (mergedValues.containsKey(NumericFieldKind.bad.name)) bad++;
    if (mergedValues.containsKey(NumericFieldKind.level.name)) level++;
    final scoreEntry = mergedValues[NumericFieldKind.score.name];
    if (scoreEntry is Map &&
        scoreEntry['value'] != null &&
        (scoreEntry['value'] as num).toInt() >= 10000) {
      score5Digit++;
    }
  }
  print(
    'Wave 2 fixture baseline: good=$good/30 bad=$bad/30 '
    'level=$level/30 score5Digit=$score5Digit/30',
  );
  expect(good, equals(23), reason: 'GOOD 検出数がベースラインと不一致');
  expect(bad, equals(24), reason: 'BAD 検出数がベースラインと不一致');
  expect(level, equals(9), reason: 'レベル検出数がベースラインと不一致');
  expect(score5Digit, equals(28), reason: '5桁スコア数がベースラインと不一致');
}

void main() {
  test('Wave 2 リージョン再 OCR: 30枚プレーシェア merged 値と extractWithRegions 結果の照合', () {
    final fixture = jsonDecode(File(_fixturePath).readAsStringSync()) as List;
    final extractor = FieldExtractor();

    _assertBaselineCounts(fixture);
    for (final entry in fixture) {
      // WHY: 末尾の集計エントリ（file 無し）は replay 検証の対象外。
      if (entry is! Map || entry['file'] == null) continue;
      _assertCropDerivedValues(extractor, entry as Map<String, dynamic>);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
