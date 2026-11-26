// ac_v1 行推定フォールバックのテスト（01a2065a Q3 裁定）。
//
// 実測根拠（tool/ac_row_deltas_output.txt・30 枚実機計測フィクスチャ）:
// - 隣接行ラベル間デルタ（dCy/dCx・正規化座標）はバケットで系統的に異なる
//   （portrait ≈0.021 / main43 ≈0.044 / wide169 ≈0.052-0.089）。単一の定数
//   では推定できないためバケット別表を使用する。
// - HWxJNv（wide169）: COOL ラベルが `CODL` と誤読されアンカー不在・COMBO
//   ラベルが `COMBO0` と連結しアンカー不在。値要素（1091・1106）は検出済み
//   で未ペア。推定は GREAT 基準（cool）・BAD 基準（maxCombo）で実位置誤差
//   cy 0.0022 / 0.0006。
// - 注意: COMBO0 の末尾 0 は値ではない（真値 1106 が別要素で同行に存在）。
//   連結形パターン（GREAT143 型）を COMBO に適用すると偽値 0 を生むため
//   不採用（リード実測確認・2026-11-23）。
// - portrait バケットは行間 dCy ≈ 0.021 で行内容半高 ≈0.010 と同程度の
//   ため、推定誤差が隣行混入に直結する。n=2 標本で行間余裕の検証もできず
//   実例での必要性も未確認のため、推定対象から除外する（YAGNI・安全側。
//   必要化した時点で追加計測して拡張する）。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ac_row_estimator.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/region_spec.dart';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

void main() {
  final fixtureJson = File(_fixturePath).readAsStringSync();
  final fixture = jsonDecode(fixtureJson) as Map<String, dynamic>;
  final results = (fixture['results'] as List).cast<Map<String, dynamic>>();
  final estimator = const AcRowEstimator();

  /// HWxJNv（COOL/COMBO ラベルがアンカーにならない wide169 写真）。
  final hwxjnv = results.singleWhere(
    (r) => (r['file'] as String).contains('HWxJNv'),
  );

  /// HV8q（全数値ラベルがアンカー検出できる 16:9 横写真）。
  final hv8q = results.singleWhere(
    (r) => (r['file'] as String).contains('HV8q'),
  );

  /// HGRWuJeak（全ラベル検出の主群 4:3 横・測定基準写真）。
  final hgrwu = results.singleWhere(
    (r) => (r['file'] as String).contains('HGRWu'),
  );

  test('HWxJNv の COOL 行位置を GREAT アンカーから推定する', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final page = _pageFromRecord(hwxjnv);
    final estimate = estimator.estimate(page, NumericFieldKind.cool, extractor);
    expect(estimate, isNotNull, reason: 'COOL ラベルは CODL 誤読でアンカー不在');
    // 実位置（CODL 要素中心・実測）は (0.4132, 0.7553)。GREAT 基準の
    // チェーンウォーク誤差は実測 0.0022/0.0019。
    expect(estimate!.cy, closeTo(0.7553, 0.02));
    expect(estimate.cx, closeTo(0.4132, 0.02));
    expect(estimate.reason, contains('GREAT'));
    // 決定性（同一入力なら同一結果）。
    final again = estimator.estimate(page, NumericFieldKind.cool, extractor);
    expect(again!.cx, estimate.cx);
    expect(again.cy, estimate.cy);
  });

  test('HWxJNv の COMBO 行位置を BAD アンカーから推定する', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final page = _pageFromRecord(hwxjnv);
    final estimate = estimator.estimate(
      page,
      NumericFieldKind.maxCombo,
      extractor,
    );
    expect(estimate, isNotNull, reason: 'COMBO ラベルは COMBO0 連結でアンカー不在');
    // 実位置（COMBO0 要素中心・実測）は (0.4200, 0.9705)。BAD 基準の
    // チェーンウォーク誤差は実測 0.0006/0.0004。
    expect(estimate!.cy, closeTo(0.9705, 0.02));
    expect(estimate.cx, closeTo(0.4200, 0.02));
    expect(estimate.reason, contains('BAD'));
  });

  test('HV8q ではアンカー検出済み種別の推定を行わない', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final page = _pageFromRecord(hv8q);
    expect(
      estimator.estimate(page, NumericFieldKind.score, extractor),
      isNull,
      reason: '推定はアンカー不在時のみ意味を持つ（呼び出し側契約の防御）',
    );
    expect(estimator.estimate(page, NumericFieldKind.cool, extractor), isNull);
  });

  test('全ラベル不在の合成ページでは推定しない', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final page = OcrPageResult(
      elements: [
        OcrElement(
          text: 'Nee.',
          boundingBox: const Rect.fromLTRB(100, 100, 200, 140),
          confidence: 0.9,
        ),
      ],
      fullText: 'Nee.',
      imageWidth: 2048,
      imageHeight: 1536,
    );
    expect(
      estimator.estimate(page, NumericFieldKind.cool, extractor),
      isNull,
      reason: '参照アンカーが 1 つもない場合は推定根拠がなく偽位置を出さない',
    );
  });

  test('portrait バケットでは推定しない（行間余裕の実測が未確立）', () {
    final extractor = const FieldExtractor(layoutKind: LayoutKind.acV1);
    final page = OcrPageResult(
      elements: [
        OcrElement(
          text: 'GREAT',
          boundingBox: const Rect.fromLTRB(300, 700, 360, 724),
          confidence: 0.9,
        ),
      ],
      fullText: 'GREAT',
      imageWidth: 800,
      imageHeight: 1200,
    );
    expect(
      estimator.estimate(page, NumericFieldKind.good, extractor),
      isNull,
      reason:
          'portrait は行間 dCy≈0.021 と内容半高が同程度で隣行混入リスクが'
          '排除できない（n=2 標本・YAGNI）',
    );
  });

  test('buildSpecs が ac_v1 のアンカー不在種別に推定 spec を生成する', () {
    final page = _pageFromRecord(hwxjnv);
    final specs = const RegionSpecBuilder().buildSpecs(
      page,
      targets: {RegionTarget.cool, RegionTarget.maxCombo},
      layoutKind: LayoutKind.acV1,
    );
    expect(specs, hasLength(2), reason: '現行はアンカー不在で spec 0 本');
    final coolSpec = specs.singleWhere((s) => s.target == RegionTarget.cool);
    final comboSpec = specs.singleWhere(
      (s) => s.target == RegionTarget.maxCombo,
    );
    expect(coolSpec.reason, contains('row-estimated'));
    expect(comboSpec.reason, contains('row-estimated'));
    expect(
      coolSpec.contrastRetry,
      isTrue,
      reason:
          '0 要素時の二値化再試行を'
          'Wave-2 前処理として有効化（実機計測で効果を検証する）',
    );

    // 成功条件の本体: 実際の未ペア値要素が推定 spec の領域に入ること
    // （cool 値 1091・maxCombo 値 1106 は実測で同行に存在）。
    expect(
      _containsNormalized(coolSpec.region, page, '1091'),
      isTrue,
      reason: 'cool 値 1091 が推定領域に入る=クロップ再 OCR が值を視野に入れる',
    );
    expect(
      _containsNormalized(comboSpec.region, page, '1106'),
      isTrue,
      reason: 'maxCombo 値 1106 が推定領域に入る（COMBO0 の 0 は値ではない）',
    );
  });

  test('hc_v1 ではアンカー不在種別の spec を生成しない（非回帰）', () {
    final page = _pageFromRecord(hwxjnv);
    final specs = const RegionSpecBuilder().buildSpecs(
      page,
      targets: {RegionTarget.cool, RegionTarget.maxCombo},
      layoutKind: LayoutKind.hcV1,
    );
    expect(specs, isEmpty, reason: 'hc_v1 の現行動作（アンカー不在=spec 0 本）を維持');
  });

  test('ac_v1 では GOOD/BAD 底辺拡張 spec を生成しない（隣行誤採用の実測防止）', () {
    // 実測（tool/ac_wave2_verification_output.txt・30 枚フルパイプライン +
    // 行整合性検証）: BAD 拡張 spec（bottom=cy+0.06）が COMBO 行
    // （dy≈0.044）の値を誤採用（625/154/1285/1217/1595/1240 の 6 件・
    // いずれも COMBO 行の同値要素と一致）し、GOOD 拡張 spec が BAD 行の値を
    // 誤採用（1 件）。ac は行間 dCy≈0.044 に対し拡張幅 +0.06 が隣行に届く
    // ため拡張 spec 自体が unsafe。hc_v1 は BAD が判定行の最下段で下に
    // 判定行が存在しないため現行維持（r6 実績）。
    final page = _pageFromRecord(hgrwu);
    final specs = const RegionSpecBuilder().buildSpecs(
      page,
      targets: {RegionTarget.good, RegionTarget.bad},
      layoutKind: LayoutKind.acV1,
    );
    expect(
      specs.where((s) => s.isFallback),
      isEmpty,
      reason: 'ac では拡張 spec が隣行値を誤採用する（実測 8 件）ため生成しない',
    );
    expect(specs, hasLength(2), reason: 'アンカー検出済みの主経路 spec のみ');
  });

  test('ac_v1 のアンカー検出済み主経路 spec は既存経路を変更しない（r6 契約）', () {
    final page = _pageFromRecord(hv8q);
    final specs = const RegionSpecBuilder().buildSpecs(
      page,
      targets: {RegionTarget.score},
      layoutKind: LayoutKind.acV1,
    );
    expect(specs, hasLength(1));
    expect(
      specs.single.reason,
      contains('label anchor'),
      reason: '既存の主経路 spec の算出根拠表記は変えない',
    );
    expect(
      specs.single.contrastRetry,
      isFalse,
      reason:
          'r6 契約「primary/fallback1 には contrastRetry を設定しない」'
          '（検出済みキーの入力経路を 1 バイトも変更しない）。二値化前処理の'
          '有効化は新経路（推定 spec）に限る',
    );
  });
}

/// [region]（正規化座標）が [text] 一致要素の正規化中心を含むか。
bool _containsNormalized(Rect region, OcrPageResult page, String text) {
  final width = page.imageWidth!.toDouble();
  final height = page.imageHeight!.toDouble();
  for (final element in page.elements) {
    if (element.text != text) {
      continue;
    }
    final cx =
        (element.boundingBox.left + element.boundingBox.right) / 2 / width;
    final cy =
        (element.boundingBox.top + element.boundingBox.bottom) / 2 / height;
    return region.left <= cx &&
        cx <= region.right &&
        region.top <= cy &&
        cy <= region.bottom;
  }
  return false;
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
