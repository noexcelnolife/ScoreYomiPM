// ac GT 30 枚（2026-11-23・docs/gt_input_template_ac30_2026-11-23.xlsx の
// ユーザー記入を test/fixtures/ocr/ac_ground_truth.json に JSON 化）で検証された
// 1 文字誤読復元（先頭 B→3 / S→5 / Y→4・acV1 限定）の回帰テスト。
//
// WHY: 実機写真の判定数/MAX COMBO の桁が B/S/Y に誤読される実測があり、
// GT 記入値との一致を固定する。B は末尾では 0（プレーシェア計測
// 6926B→69260・field_extractor_test 凍結）、先頭では 3（ac GT 5 例）という
// 位置依存の実測で、プレーシェア画面では先頭 B がノイズ（B7147→7147・
// region_merge_fixture_test 凍結）のため acV1 でのみ分岐を追加する。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

/// GT 検証済み誤読ケース（写真情報 key, 生テキスト, 期待値, 種別）。
/// WHY: 生テキストも GT 記入の根拠と一致を断言することで、別要素からの
/// 偶然一致を検出できる。
const List<(String, String, int, NumericFieldKind)> _gtCases = [
  ('HE9FveQa', 'B8', 38, NumericFieldKind.maxCombo),
  ('HGRWuJeak', 'S5', 55, NumericFieldKind.maxCombo),
  ('HW7cJQabk', 'B90', 390, NumericFieldKind.maxCombo),
  ('HXtt8jga', 'Y84', 484, NumericFieldKind.maxCombo),
  ('HXurIAL', 'B33', 333, NumericFieldKind.maxCombo),
  ('HXurIAL', 'B0', 30, NumericFieldKind.bad),
  ('HSi7ZNDb', 'Y6', 46, NumericFieldKind.good),
  ('HXuql59', 'B0', 30, NumericFieldKind.good),
];

void main() {
  final fixtureJson = File(_fixturePath).readAsStringSync();
  final fixture = jsonDecode(fixtureJson) as Map<String, dynamic>;
  final results = (fixture['results'] as List).cast<Map<String, dynamic>>();

  test('ac GT 誤読 1 文字（先頭 B→3 / S→5 / Y→4）が GT 値に復元される', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    for (final (photo, raw, expected, kind) in _gtCases) {
      final record = results.firstWhere(
        (r) => (r['file'] as String).contains(photo),
        orElse: () => throw StateError('fixture に $photo が見つかりません'),
      );
      final extracted = extractor.extract(_pageFromRecord(record));
      final field = extracted.field(kind);
      expect(field, isNotNull, reason: '$photo ${kind.name}: 未抽出（回帰）');
      expect(
        field!.rawText,
        raw,
        reason: '$photo ${kind.name}: GT の誤読要素と別要素から取得',
      );
      expect(field.value, expected, reason: '$photo ${kind.name}');
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
