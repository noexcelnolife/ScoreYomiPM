// ac_v1 Wave-2 クロップ文脈の数値ポスト処理テスト（01a2065a Q2 裁定）。
//
// 対象: FieldExtractor.extractWithRegions のクロップ結果パースに追加する
// 2 文字語彙復旧（I→1・O→0）。
//
// 実測根拠（30 枚実機計測フィクスチャ・
// docs/ocr_ac_field_remeasurement_design_2026-11-23.md §4-5）:
// - HV8q_4WaEAEbLHQ の score 値は ML Kit が `IO0000` と読む（GT = 100000）。
//   非数字 2 文字のため _parseNumericValue は拒否し、全体 OCR・クロップ OCR
//   の両経路で score 未抽出になる（基線 27/30）。
// - 主経路（extract）の厳格拒否は変更しない（WHY: あいまい照合の偽値は
//   全体 OCR の要素海で増幅される。stats §3「あいまい照合は偽アンカーを
//   生む」の方針を値パースにも踏襲する）。
// - クロップ文脈は列窓で絞られた小領域の再認識結果であり、誤値の混入面が
//   狭いため、そこでのみ 2 文字復旧を許す（Wave-2 専用ルール）。
//   ガード: 文字種は [0-9IO] のみ・元テキストに数字 3 桁以上を含む・
//   種別検証範囲（score 0..100000 / 判定 0..9999）通過。
//   WHY 元数字 3 桁以上: 実測インスタンス IO0000 は元数字 4 桁。`IO` のような
//   数字なし読みや `IO5` のような 1 桁読みはラベル片/ノイズの可能性が高く
//   復旧しない（保守的側に倒す）。
// - 適用は ac_v1 レイアウトに限定する（WHY: 実測インスタンスが ac_v1 のみで
//   hc_v1 のクロップ入力分布は未測定。影響範囲を実測のある経路に留める）。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

void main() {
  final fixtureJson = File(_fixturePath).readAsStringSync();
  final fixture = jsonDecode(fixtureJson) as Map<String, dynamic>;
  final results = (fixture['results'] as List).cast<Map<String, dynamic>>();

  /// HV8q_4WaEAEbLHQ（score 値が IO0000 と誤読される 16:9 横写真）のページ。
  final hv8q = results.singleWhere(
    (r) => (r['file'] as String).contains('HV8q'),
  );

  test('主経路 extract は IO0000 を拒否し続ける（厳格拒否の維持）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final extracted = extractor.extract(_pageFromRecord(hv8q));
    expect(
      extracted.score,
      isNull,
      reason: '主経路の 2 文字非数字拒否は Wave-2 専用ルール追加でも変えない',
    );
  });

  test('クロップ結果 IO0000 から score 100000 を復旧する', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('IO0000'),
    });
    final score = merged.score;
    expect(score, isNotNull, reason: 'Wave-2 専用の 2 文字語彙復旧で回復する');
    expect(score!.value, 100000);
    expect(score.isValid, isTrue);
    expect(score.rawText, 'IO0000');
  });

  test('クロップ結果に元数字がない読みは復旧しない', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('IO'),
    });
    expect(merged.score, isNull, reason: 'IO のような数字なし読みはノイズとして拒否');
  });

  test('元数字が 3 桁未満のクロップ読みは復旧しない', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('IO5'),
    });
    expect(merged.score, isNull, reason: '1 桁読みはラベル片/ノイズの可能性が高いため拒否');
  });

  test('許可外の文字を含むクロップ読みは復旧しない', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('IO5A'),
    });
    expect(merged.score, isNull, reason: 'I/O 以外の非数字混入は語彙ルールの対象外');
  });

  test('クロップ読みは既存の有効な全体値を上書きしない（マージ規則の維持）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.cool: _cropPage('I000'),
    });
    // HV8q の cool 全体値は実測 1306（有効）。`I000` は 1 文字ルールで
    // パース可能だが、全体で有効な値はクロップで上書きしない（マージ規則）。
    // なお 2 文字ルールの元数字 3 桁ゲートは実質 score 専用になる
    // （判定数/コンボは 4 桁上限で、2 文字非数字と 3 桁以上の元数字は両立
    // しないため）。
    final cool = merged.cool;
    expect(cool, isNotNull);
    expect(cool!.value, 1306);
    expect(cool.isValid, isTrue);
  });

  test('クロップ部分読み 000 による score 0 を拒否する（HV8q 実測の偽値防止）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('000'),
    });
    // 実測（run-2・HV8q）: score 表示の部分読み「000」が 1 文字正規化で
    // 偽値 0 になった。真の 0 点は実測コーパス 30 枚に不在（最小 99802）
    // で、クロップは補完経路にすぎないため、score の 0 はクロップでは
    // 採用しない（誤値より null。真の 0 点は全体 OCR 経路で抽出される）。
    expect(merged.score, isNull, reason: '部分読みによる偽値 0 より null を優先');
  });

  test('score クロップ読みの 0 値拒否は全桁の 0 読みでも同様', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('000000'),
    });
    // 桁数が揃った 0 読みでも score 0 の採用はクロップ経路では行わない
    // （スコア 0 の真値抽出は全体 OCR 経路の責務。経路間で役割を分離し、
    // クロップ側の判定を単純に保つ = KISS）。
    expect(merged.score, isNull);
  });

  test('score 以外の種別はクロップの 0 値を許す（真値 0 を壊さない）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.bad: _cropPage('0'),
    });
    // 判定数の 0 は通常表示（BAD 0 等）。HV8q の bad 全体値は null なので
    // クロップ値が採用される。拒否を score に限定する根拠テスト。
    final bad = merged.bad;
    expect(bad, isNotNull);
    expect(bad!.value, 0);
    expect(bad.isValid, isTrue);
  });

  test('hc_v1 では 2 文字復旧を適用しない（影響範囲の限定）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.hcV1);
    final merged = extractor.extractWithRegions(_pageFromRecord(hv8q), {
      RegionTarget.score: _cropPage('IO0000'),
    });
    expect(
      merged.score,
      isNull,
      reason: '実測インスタンスが ac_v1 のみのため hc_v1 の入力経路は変えない',
    );
  });
}

/// クロップ再 OCR 結果の合成ページ（単一要素・寸法付き）。
OcrPageResult _cropPage(String text) {
  return OcrPageResult(
    elements: [
      OcrElement(
        text: text,
        boundingBox: const Rect.fromLTRB(0, 0, 100, 40),
        confidence: 0.9,
      ),
    ],
    fullText: text,
    imageWidth: 100,
    imageHeight: 40,
  );
}

/// フィクスチャ 1 記録を OcrPageResult に変換する
/// （test/ac_batch_extraction_test.dart と同一の変換規則）。
OcrPageResult _pageFromRecord(Map<String, dynamic> result) {
  final elements = (result['elements'] as List).map((e) {
    final map = e as Map<String, dynamic>;
    final box = map['boundingBox'] as Map<String, dynamic>;
    return OcrElement(
      text: (map['text'] as String?) ?? '',
      boundingBox: Rect.fromLTRB(
        (box['l'] as num).toDouble(),
        (box['t'] as num).toDouble(),
        (box['r'] as num).toDouble(),
        (box['b'] as num).toDouble(),
      ),
      confidence:
          (map['confidence'] as num?)?.toDouble() ??
          OcrElement.confidenceUnknown,
    );
  }).toList();
  return OcrPageResult(
    elements: elements,
    fullText: result['fullText'] as String? ?? '',
    imageWidth: (result['imageWidth'] as num).toInt(),
    imageHeight: (result['imageHeight'] as num).toInt(),
  );
}
