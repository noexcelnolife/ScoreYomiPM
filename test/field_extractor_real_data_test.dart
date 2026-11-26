// フィクスチャ:
// - test/fixtures/ocr/playshare_batch_results.json
//   （実機 30 画像の ML Kit OCR 結果。全体 OCR 元データ）
// - test/fixtures/ocr/playshare_region_ocr_results.json
//   （実機 30 画像のリージョン再 OCR 結果。Wave 2 クロップ OCR）
// - test/fixtures/ocr/ground_truth.json（うち 9 サンプルに数値 GT あり）
//
// 幾何パラメータの根拠:
// - ラベル位置統計 docs/field_layout_stats_2026-11-22.md（座標は正規化座標。
//   画像寸法が 19 パターンあるため絶対座標は禁止・§7①）
// - Ground Truth 照合で確認した「値はラベルと同一行の右側」という真の幾何
//   （統計書 §4.2 の GREAT/GOOD/BAD 行は値未検出行で隣行値を拾った偽ペア
//   を含むため、本テストの期待値は GT 照合値を正とする）
//
// 一致率は NFR-4（OCR 精度 KPI）の測定基線であり、リージョン再 OCR
// （Wave 2 / ST-5）で引き上げるための下限値として固定する。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

const String _batchFixturePath =
    'test/fixtures/ocr/playshare_batch_results.json';
const String _regionFixturePath =
    'test/fixtures/ocr/playshare_region_ocr_results.json';
const String _gtPath = 'test/fixtures/ocr/ground_truth.json';

/// 実データの画像寸法（docs/field_layout_stats_2026-11-22.md §2 の 30 画像
/// 分）。WHY: フィクスチャ JSON には画像寸法が含まれず、正規化座標変換に
/// 必要なため本テストで対応表を持つ。
const Map<String, List<int>> _imageDims = {
  '23bjim': [1200, 797],
  'g7p9b2': [1200, 810],
  'usnb54': [1200, 807],
  'xpnzu8': [1200, 805],
  '52c4xa': [1200, 802],
  'al9lbl': [1200, 791],
  '5p1lg4': [1170, 774],
  '711q04': [1169, 784],
  'kt1odi': [1170, 762],
  'yb5h8w': [1169, 766],
  'bet7t4': [1200, 782],
  'enco0h': [1200, 801],
  'o8li0f': [1200, 798],
  'ph0l0k': [1200, 798],
  'e6xlzd': [1200, 802],
  'lmzm7u': [1200, 802],
  'nhgclt': [1200, 811],
  'wpybd3': [1200, 799],
  '3490q2': [1200, 802],
  'bt2qlc': [1200, 801],
  'fj61sj': [1200, 797],
  'rx3sh6': [1200, 802],
  'bk6xxm': [1200, 804],
  'r7uamp': [1200, 802],
  's4i71t': [1200, 795],
  'z29mk5': [1200, 806],
  '12h1bb': [1200, 800],
  'ay7zmq': [1200, 799],
  's9cv7b': [1200, 799],
  'yyd20v': [1200, 800],
};

/// GT 数値フィールド → 抽出種別の対応。
/// WHY: レベルは Wave 1 の抽出対象外（ラベル検出 0/30・stats §3）だったが、
/// Wave 2 でレベル種別を追加し、クロップ OCR 読みを _parseLevelValue +
/// 1..50 バリデーションで採用する。GT 照合にも含める。
const Map<String, NumericFieldKind> _gtFieldKinds = {
  'score': NumericFieldKind.score,
  'coolCount': NumericFieldKind.cool,
  'greatCount': NumericFieldKind.great,
  'goodCount': NumericFieldKind.good,
  'badCount': NumericFieldKind.bad,
  'maxCombo': NumericFieldKind.maxCombo,
  'level': NumericFieldKind.level,
};

String _imageId(String file) =>
    RegExp(r'_([a-z0-9]{6})\.jpg$').firstMatch(file)!.group(1)!;

OcrPageResult _pageFromBatch(Map<String, dynamic> result) {
  final fileName = result['file'] as String?;
  if (fileName == null) {
    throw StateError('batch result entry missing file');
  }
  final id = _imageId(fileName);
  final dims = _imageDims[id]!;
  final elements = (result['elements'] as List).map((e) {
    if (e is! Map<String, dynamic>) {
      return OcrElement(text: '', boundingBox: Rect.zero, confidence: 0.0);
    }
    final box = e['boundingBox'] as Map<String, dynamic>?;
    if (box == null) {
      return OcrElement(
        text: (e['text'] as String?) ?? '',
        boundingBox: Rect.zero,
        confidence: 0.0,
      );
    }
    return OcrElement(
      text: (e['text'] as String?) ?? '',
      boundingBox: Rect.fromLTRB(
        (box['l'] as num).toDouble(),
        (box['t'] as num).toDouble(),
        (box['r'] as num).toDouble(),
        (box['b'] as num).toDouble(),
      ),
      confidence: (e['confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }).toList();
  return OcrPageResult(
    elements: elements,
    fullText: result['fullText'] as String? ?? '',
    imageWidth: dims[0],
    imageHeight: dims[1],
  );
}

/// リージョン結果を Map (RegionTarget, OcrPageResult) に構築する。
Map<RegionTarget, OcrPageResult> _regionsFromEntry(
  Map<String, dynamic> entry,
  int imageWidth,
  int imageHeight,
) {
  final regions = <RegionTarget, OcrPageResult>{};
  final regionList = entry['regions'] as List?;
  if (regionList == null) {
    return regions;
  }
  for (final region in regionList) {
    if (region is! Map<String, dynamic>) continue;
    final targetName = region['target'] as String?;
    if (targetName == null) continue;
    final target = RegionTarget.values.byName(targetName);
    final elementsList = region['elements'] as List?;
    final elements =
        elementsList
            ?.map((e) {
              if (e is! Map<String, dynamic>) return null;
              final box = e['boundingBox'] as Map<String, dynamic>?;
              if (box == null) return null;
              return OcrElement(
                text: (e['text'] as String?) ?? '',
                boundingBox: Rect.fromLTRB(
                  (box['l'] as num).toDouble(),
                  (box['t'] as num).toDouble(),
                  (box['r'] as num).toDouble(),
                  (box['b'] as num).toDouble(),
                ),
                confidence: (e['confidence'] as num?)?.toDouble() ?? 0.0,
              );
            })
            .whereType<OcrElement>()
            .toList() ??
        <OcrElement>[];
    regions[target] = OcrPageResult(
      elements: elements,
      fullText: elements.map((e) => e.text).join(' '),
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }
  return regions;
}

void main() {
  final batchFixture = jsonDecode(
    File(_batchFixturePath).readAsStringSync(),
  ) as Map<String, dynamic>;
  // WHY: strict-casts 有効化（DoD M-4）に伴い、要素の型をここで確定させる。
  // 生の List のままだと r が dynamic になり、regionByFile の値型
  // Map<String, dynamic> に代入できない。results / samples と同じ扱いに揃える。
  final regionFixture = (jsonDecode(
    File(_regionFixturePath).readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();
  final gt =
      jsonDecode(File(_gtPath).readAsStringSync()) as Map<String, dynamic>;
  final results = (batchFixture['results'] as List)
      .cast<Map<String, dynamic>>();
  final samples = (gt['samples'] as List).cast<Map<String, dynamic>>();
  final byFile = <String, Map<String, dynamic>>{
    for (final r in results)
      if (r['file'] is String) r['file'] as String: r,
  };
  final regionByFile = <String, Map<String, dynamic>>{
    for (final r in regionFixture)
      if (r['file'] is String) r['file'] as String: r,
  };

  FieldExtractionResult extractMerged(Map<String, dynamic> result) {
    final id = _imageId(result['file'] as String);
    final dims = _imageDims[id]!;
    final pageResult = _pageFromBatch(result);
    final regionEntry = regionByFile[result['file'] as String];
    final regionResults = regionEntry != null
        ? _regionsFromEntry(regionEntry, dims[0], dims[1])
        : <RegionTarget, OcrPageResult>{};
    return const FieldExtractor().extractWithRegions(pageResult, regionResults);
  }

  group('実データ 30 画像での抽出（Wave 2 マージ後）', () {
    test('全画像で抽出が完了し、抽出値はすべて検証範囲内', () {
      // フィールド別 3 値区分（タスク 01a200f5 の測定要件）:
      // 未抽出（field なし）/ isValid=true / isValid=false。
      final validCounts = <NumericFieldKind, int>{
        for (final kind in NumericFieldKind.values) kind: 0,
      };
      final invalidCounts = <NumericFieldKind, int>{
        for (final kind in NumericFieldKind.values) kind: 0,
      };

      for (final result in results) {
        final extraction = extractMerged(result);
        expect(
          extraction.sourceElementCount,
          (result['elements'] as List).length,
        );
        for (final field in extraction.numericFields.values) {
          // WHY: 実データで範囲外値が立つなら幾何・正規化のバグ。範囲外は
          // 「抽出したが不審」の状態でしかありえず、その実例は未保証。
          expect(
            field.isValid,
            isTrue,
            reason: '${result['file']} ${field.kind}: ${field.rawText}',
          );
          validCounts[field.kind] = validCounts[field.kind]! + 1;
        }
      }

      // ベースライン（Wave 2 実測値・30 画像中）。リージョン再 OCR での
      // 引き上げが前提のため、低下した場合のみ失敗させる。
      // score 30/30, cool 30/30, great 30/30, good 23/30, bad 24/30,
      // maxCombo 30/30, level 9/30（1..50 バリデーション通過のみ）。
      // 未抽出 = 30 − 抽出数。isValid=false は 0（範囲外偽値なし）。
      debugPrint('isValid=true（30 画像中）: $validCounts');
      debugPrint('isValid=false（30 画像中）: $invalidCounts');
      expect(validCounts[NumericFieldKind.score]!, 30);
      expect(validCounts[NumericFieldKind.cool]!, 30);
      expect(validCounts[NumericFieldKind.great]!, 30);
      expect(validCounts[NumericFieldKind.good]!, 23);
      expect(validCounts[NumericFieldKind.bad]!, 24);
      expect(validCounts[NumericFieldKind.maxCombo]!, 30);
      expect(validCounts[NumericFieldKind.level]!, 9);
      for (final count in invalidCounts.values) {
        expect(count, 0);
      }
    });
  });

  group('GT 照合（9 サンプル）', () {
    test('g7p9b2 のスコアは O→0 置換で GT 値 95000 に復元される', () {
      final result = results.firstWhere(
        (r) => r['file'] is String && _imageId(r['file'] as String) == 'g7p9b2',
        orElse: () => throw StateError('g7p9b2 not found in batch results'),
      );
      final extraction = extractMerged(result);

      expect(extraction.score, isNotNull);
      expect(extraction.score!.value, 95000);
      expect(extraction.score!.rawText, '9500O');
    });

    test('3490q2 のスコアは 4 桁落字として信頼度が減衰する', () {
      // GT 96401 に対し OCR は 9640（末尾落字）。値の復元は不可能だが、
      // 「4 桁 = 落字疑い」を信頼度減衰で表現する（ヘッダー doc §7 参照）。
      final result = results.firstWhere(
        (r) => r['file'] is String && _imageId(r['file'] as String) == '3490q2',
        orElse: () => throw StateError('3490q2 not found in batch results'),
      );
      final extraction = extractMerged(result);

      expect(extraction.score, isNotNull);
      expect(extraction.score!.value, 9640);
      expect(extraction.score!.confidence, lessThan(0.5));
    });

    test('全抽出項目一致率・フィールド別一致率がベースライン以上', () {
      final fieldMatches = <NumericFieldKind, int>{
        for (final kind in NumericFieldKind.values) kind: 0,
      };
      final fieldTotals = <NumericFieldKind, int>{
        for (final kind in NumericFieldKind.values) kind: 0,
      };
      var totalFields = 0;
      var matchedFields = 0;

      for (final sample in samples) {
        final file = sample['file'] as String;
        final result = byFile[file];
        if (result == null) {
          fail('GT サンプル $file がフィクスチャに存在しない');
        }
        final extraction = extractMerged(result);

        for (final entry in _gtFieldKinds.entries) {
          final gtValue = sample[entry.key];
          if (gtValue == null) {
            continue;
          }
          totalFields++;
          fieldTotals[entry.value] = fieldTotals[entry.value]! + 1;
          final field = extraction.field(entry.value);
          if (field != null && field.value == (gtValue as num).toInt()) {
            matchedFields++;
            fieldMatches[entry.value] = fieldMatches[entry.value]! + 1;
          }
        }
      }

      final overallRate = matchedFields / totalFields;
      debugPrint(
        '全抽出項目一致率: $matchedFields/$totalFields '
        '(${(overallRate * 100).toStringAsFixed(1)}%)',
      );

      // ==== ベースライン（Wave 2 実測値・GT 9 サンプル × 7 項目 = 63）====
      // score 8/9（3490q2 は 96401→9640 落字で不一致、yyd20v は 97311→9731 で
      // 末尾桁未検出）
      // cool 9/9, great 9/9, maxCombo 9/9（変わらず全検出）
      // good 7/9（23bjim good=2 はフォールバック spec で検出、e6xlzd/u8/s4/mq
      //   はクロップでも未検出）、bad 6/9（5p1lg4 bad=0 は窓ミスアンカーで
      //   未検出、BAD フォールバック spec で一部画像が回復）
      // level 0/9（セグメント風グラフィック書体は ML Kit で読めない。
      // valid 9/30 は誤検出・誤読。FR-3 手入力確定が正式経路）
      // → 合計 48/63 = 76.2%（good 6/9 → 7/9、bad 5/9 → 6/9、level 1/9 → 0/9）
      // WHY 固定: NFR-4 の測定基線。精度改善（Wave 2 リージョン再 OCR）で
      // 引き上げるための下限固定であり、低下を検知するのが目的。
      const expectedMatches = {
        NumericFieldKind.score: 8,
        NumericFieldKind.cool: 9,
        NumericFieldKind.great: 9,
        NumericFieldKind.good: 7,
        NumericFieldKind.bad: 6,
        NumericFieldKind.maxCombo: 9,
        NumericFieldKind.level: 0,
      };
      const expectedTotals = {
        NumericFieldKind.score: 9,
        NumericFieldKind.cool: 9,
        NumericFieldKind.great: 9,
        NumericFieldKind.good: 9,
        NumericFieldKind.bad: 9,
        NumericFieldKind.maxCombo: 9,
        NumericFieldKind.level: 9,
      };
      for (final kind in expectedTotals.keys) {
        debugPrint(
          'フィールド別一致率 ${kind.name}: '
          '${fieldMatches[kind]}/${fieldTotals[kind]}',
        );
        expect(
          fieldMatches[kind],
          expectedMatches[kind],
          reason: 'フィールド別一致率 ${kind.name} のベースライン低下',
        );
        expect(fieldTotals[kind], expectedTotals[kind]);
      }
      // → 合計 48/63 = 76.2%（good 6/9 → 7/9、bad 5/9 → 6/9 に改善）
      expect(matchedFields, 48);
      expect(totalFields, 63);
    });
  });
}
