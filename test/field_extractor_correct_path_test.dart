// 正種別（hcV1）経路の固定テスト【01a208f7 再スコープ 最終訂正】
//
// WHY: 指示 3 は「23bjim fixture に hcV1 相当（layoutKind=hcV1）で extract
//   + extractWithRegions をホスト実行し、正種別経路の挙動を固定する」。
//   検証ターゲット: (a) bad の実測値（44 を取らないこと）(b) 汚染が
//   hcV1 でも再現するかの結論。App-UI の報告によれば、汚染（bad=44，
//   レベル「44」が BAD バンドに流入）は acV1-hint × プレーシェア
//   （裁定 D の設計範囲）での現象で、正種別（hcV1）では dy ゲートで
//   除外される見込み。本テストは hcV1 経路の期待値を host で固定し、
//   汚染が hcV1 でも再現したら初めての真の red として扱う。
//
// 最終訂正（リード 2026-11-24）:
//   * 「誤」ラベルの dx/dy 実測表は正 GT では逆である。COOL↔975
//     (dy=0.0013/dx=0.1349)・GREAT↔58 (dy=0.0027/dx=0.1357)・
//     maxCombo↔733 (dy=0.0001/dx=0.1464) は正しいペアリング。
//   * 「本来の値（削除済み要素）」は実在しない（実 fixture の COOL 行に
//     値要素は 975 の一つだけ）。
//   * GOOD↔975 dy=0.0995・BAD↔58 dy=0.017 で _sameRowTolerance 0.012
//     のゲートにより排除済み → hcV1 は回転しない、を本テストで検証する。
//   * region 合成は実 region クロップのダンプが存在しないため廃止する。
//     ホスト検証の期待値は full-page のみで、good=2/bad=1 の充填正確性は
//     ホスト対象外として、実機 end-to-end（App-UI が正種別で実施）で
//     確認する。
//
// 検証方法:
//   * hcV1: FieldExtractor(layoutKind: LayoutKind.hcV1).extract — full-page
//     要素は実機 dump（test/fixtures/ocr/23bjim_repro_elements.json）から
//     得た生要素 47 件（imageWidth/Height は 1182x754）。期待は
//     score=98108 / cool=975 / great=58 / maxCombo=733 / good=null / bad=null。
//   * 44 汚染の確認: full-page 要素に "44" は存在しない（実機 dump に
//     level の要素はあるが LevelAnchorScanner で level アンカーとして
//     消費され、数値 44 は label としては扱われない）。したがって hcV1 の
//     extract では
//     bad は 44 にならない（検証実施）。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

/// 実機ダンプ fixture のパス（生成手順は repro テスト冒頭コメント）。
const String _fixturePath = 'test/fixtures/ocr/23bjim_repro_elements.json';

/// 画像寸法（ML Kit の要素 extent から算出・実測 W=1182,H=754）。
const int _width = 1182;
const int _height = 754;

/// fixture から OcrPageResult を読み込む（生要素そのもの）。
OcrPageResult _loadPage(String path) {
  final raw = File(path).readAsStringSync();
  final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
  final elements = <OcrElement>[];
  for (final e in (j['elements'] as List).cast<Map<String, dynamic>>()) {
    final b = e['boundingBox'] as Map<String, dynamic>;
    elements.add(
      OcrElement(
        text: e['text'] as String,
        boundingBox: Rect.fromLTRB(
          (b['l'] as num).toDouble(),
          (b['t'] as num).toDouble(),
          (b['r'] as num).toDouble(),
          (b['b'] as num).toDouble(),
        ),
        confidence:
            (e['confidence'] as num?)?.toDouble() ??
            OcrElement.confidenceUnknown,
      ),
    );
  }
  return OcrPageResult(
    elements: elements,
    fullText: '',
    imageWidth: _width,
    imageHeight: _height,
  );
}

void main() {
  group('correct path fixation: hcV1(host)', () {
    test('hcV1 extract(full-page のみ): good/bad are null, bad != 44, '
        'cool/great/maxCombo match correct GT', () {
      final page = _loadPage(_fixturePath);
      final result = const FieldExtractor(layoutKind: LayoutKind.hcV1)
          .extract(page);

      // 正 GT（975/58/2/1/733）との照合。COOL↔975 は正しいペアリング
      // （リード最終訂正：誤ラベルは幻 GT の残骸）。
      expect(result.score?.value, 98108, reason: 'score');
      expect(result.cool?.value, 975, reason: 'cool is 975');
      expect(result.great?.value, 58, reason: 'great is 58');
      expect(result.maxCombo?.value, 733, reason: 'maxCombo is 733');

      // GOOD/BAD の行値（2/1）は full-page に要素が無いため null。
      // GOOD↔975 dy=0.0995、BAD↔58 dy=0.017 は dy ゲート（0.012）で
      // 排除済みであることを本テストで検証する。
      expect(result.good, isNull, reason: 'GOOD value (2) not in full-page');
      expect(
        result.bad,
        isNull,
        reason: 'BAD value (1) not in full-page; must not be 44',
      );

      // 44 の汚染がないこと：要素に 44 は無い（dump に元源がない）。
      expect(
        page.elements.any((e) => e.text == '44'),
        isFalse,
        reason: 'full-page elements contain no 44',
      );
      expect(
        result.bad?.value,
        isNot(44),
        reason: 'bad must not be 44 in hcV1 path',
      );
    });

    test('hcV1 vs acV1 feature comparison: acV1/hcV1 differ in column window '
        'geometry of the playshare 1.5 image (design-scope documentation)', () {
      // NOTE（設計記録）: acV1 列窓（cool 0.11-0.20 / great 0.11-0.19 /
      // good 0.12-0.21 / bad 0.12-0.22 / maxCombo 0.11-0.19 / score 0.12-0.22）が
      // 1.5 のプレーシェアに適用される場面は裁定 D（不一致→警告+処理継続）の
      // 設計範囲に含まれる。本 fixture では full-page 要素がどちらの窓でも
      // 同一の値を返し、ac/hc の差は本ホスト fixture では検出できない
      // （実機の悪性は region バンド側・別要素の流入であり、full-page の
      // extract 単体では acV1 窓でも同じ抽出になる）。本テストは
      // hcV1 が正 GT に一致し、acV1 の full-page 抽出も本 fixture では
      // 同じ値を返すことを固定し、設計差（列窓の重複）の記録とする。
      final page = _loadPage(_fixturePath);
      final hc = const FieldExtractor(layoutKind: LayoutKind.hcV1)
          .extract(page);
      final ac = const FieldExtractor(layoutKind: LayoutKind.acV1)
          .extract(page);

      // hcV1 は正 GT（975/58/733）に一致する
      expect(hc.score?.value, 98108);
      expect(hc.cool?.value, 975);
      expect(hc.great?.value, 58);
      expect(hc.maxCombo?.value, 733);

      // acV1 はプレーシェア画像に適用される広い列窓で設計されているが、
      // 本 fixture の full-page 要素（47件・値 4件）では列窓の重複が
      // 差を生まない（実機の悪性は region バンド経路）。
      expect(ac.cool?.value, 975, reason: 'acV1 full-page cool');
      expect(ac.great?.value, 58, reason: 'acV1 full-page great');
      expect(ac.maxCombo?.value, 733, reason: 'acV1 full-page maxCombo');
      expect(
        ac.bad?.value,
        isNot(44),
        reason: 'no 44 contamination in acV1 full-page either',
      );
    });
  });
}
