// ac_v1 抽出検証テスト（30 枚実機写真・01a2060d Phase 7 校正の回帰ゲート）。
//
// フィクスチャ:
// - test/fixtures/ocr/ac_hc_batch_results.json
//   （エミュレータ実機 30 枚一括計測の ML Kit OCR 結果・画像寸法焼き込み済み。
//    tool/build_ac_fixture.dart が lib/ocr/batch_measurement_output.txt から構築）
//
// 校正の根拠（WHY 窓値がこの値であるか）:
// - ラベル↔値の相対 dx は写真フレーミング（画面写り込み割合）に不変で、
//   実測の真同一行ペア（|dy|<=0.012）の p5..p95 を _acV1Windows に反映済み
//   （tool/measure_ac_windows.dart で再現可能）
// - 同一直行許容 0.012 は hc_v1 と共通値のまま維持: 実測で |dy| 0.045 前後の
//   ペアは隣接行の誤ペア（実値が ML Kit で未検出の写真）であり、緩めると
//   誤値を取り込むため緩和は不正解と確認した
//
// 期待抽出率（ML Kit 全体 OCR の実測限界・30 枚・_parseNumericValue 正規化込み）:
// - score 27/30・cool 29/30・great 26/30・good 17/30・bad 14/30・maxCombo 29/30
// - 未抽出の実体: 小桁数値の検出漏れ（good/bad の 1 桁値）・2 文字以上の誤読
//   （IO0000・枠線混入 B8/S5/Y6/り5/も は 1 文字正規化で回復済み）・ラベル未検出
//   （HWxJNv の COOL）・連結形（COMBO0）。回復手段は Wave 2 クロップ再 OCR
//   （実機検証）と 2 文字誤読の追加ルール（タスク 01a2065a・Q2 裁定）に属し、
//   本テストは Wave 1 の実測基線を固定する。
//
// 一致率は NFR-4（OCR 精度 KPI）の ac_v1 基線であり、これを下回る回帰を
// 検出するゲートとして固定する。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

/// 校正時の実測抽出数（30 枚あたり・ランタイム基線）。WHY: 厳密一致ゲートと
/// する（フィクスチャ凍結 + 抽出は決定的なので、値がずれたら窓/許容の回帰）。
///
/// 計算根拠: tool/measure_ac_windows.dart の真同一行ペア（int.tryParse 基線）
/// に、_parseNumericValue の 1 文字誤読正規化で回復される分を加算。
/// - score 26 + も9767→9767 = 27（未抽出: HJS4/HV8q/HWSQ・HV8q は IO0000 の
///   2 文字誤読で正規化対象外）
/// - cool 29（未抽出: HWxJNv はラベル自体が ML Kit 未検出）
/// - great 26（未抽出: HV8q/HWSQ/HXAfz/HXfcDN は値が ML Kit 未検出）
/// - good 14 + 7O→70 + Y6→6 + B0→0 = 17
/// - bad 12 + り5→5 + B0→0 = 14
/// - maxCombo 24 + B8→8 + S5→5 + B90→90 + Y84→84 + B33→33 = 29
///   （未抽出: HWxJNv は COMBO0 の連結形・ラベル単独要素なし）
const Map<NumericFieldKind, int> _expectedExtractedCount = {
  NumericFieldKind.score: 27,
  NumericFieldKind.cool: 29,
  NumericFieldKind.great: 26,
  NumericFieldKind.good: 17,
  NumericFieldKind.bad: 14,
  NumericFieldKind.maxCombo: 29,
};

const List<NumericFieldKind> _numericKinds = [
  NumericFieldKind.score,
  NumericFieldKind.cool,
  NumericFieldKind.great,
  NumericFieldKind.good,
  NumericFieldKind.bad,
  NumericFieldKind.maxCombo,
];

void main() {
  final fixtureJson = File(_fixturePath).readAsStringSync();
  final fixture = jsonDecode(fixtureJson) as Map<String, dynamic>;
  final results = (fixture['results'] as List).cast<Map<String, dynamic>>();

  test('fixture sanity: 30 records with image dims', () {
    expect(results, hasLength(30));
    for (final r in results) {
      expect(r['imageWidth'], isNotNull, reason: '${r['file']}');
      expect(r['imageHeight'], isNotNull, reason: '${r['file']}');
    }
  });

  test('extraction rate matches calibrated measurement per field', () {
    final counts = <NumericFieldKind, int>{for (final k in _numericKinds) k: 0};
    final table = <String>[];
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    for (final r in results) {
      final page = _pageFromRecord(r);
      final extracted = extractor.extract(page);
      final file = (r['file'] as String).split('/').last;
      final cells = <String>[];
      for (final k in _numericKinds) {
        final f = extracted.field(k);
        if (f != null) {
          counts[k] = counts[k]! + 1;
          cells.add('${k.name}=${f.value}');
        } else {
          cells.add('${k.name}=-');
        }
      }
      table.add('$file ${cells.join(' ')}');
    }
    for (final line in table) {
      debugPrint(line);
    }
    for (final k in _numericKinds) {
      expect(
        counts[k],
        _expectedExtractedCount[k],
        reason: '${k.name} 抽出数が校正基線と不一致（窓/許容の回帰疑い）',
      );
    }
  });

  test('every extracted value passes the extractor validation', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    for (final r in results) {
      final page = _pageFromRecord(r);
      final extracted = extractor.extract(page);
      for (final k in _numericKinds) {
        final f = extracted.field(k);
        if (f == null) {
          continue;
        }
        expect(
          f.isValid,
          isTrue,
          reason:
              '${r['file']} ${k.name}=${f.value} '
              '(${f.validationMessage})',
        );
      }
    }
  });
}

/// フィクスチャ 1 記録を OcrPageResult に変換する。
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
