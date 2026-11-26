// 正 GT 検証（23bjim 実機ダンプ由来・host 再生）【01a208f7 再スコープ 最終訂正】
//
// 前提の訂正（リード 2026-11-23・最終訂正 2026-11-24）:
//   従来「cool 733 / great 33 / good 975 / bad 58 / combo 2」は誤 GT
//   （ground_truth.json のどの版にも存在しない値）。正 GT（503d882 も現行も
//   含む）: 98108/975/58/2/1/733。本ファイルは正 GT に基づき、23bjim の
//   「回転」は幻影であったことを固定する。
//
// fixture（test/fixtures/ocr/23bjim_repro_elements.json）:
//   emulator-5554・integration_test/ocr_repro_dump_test.dart で
//   ML Kit 生要素 47 件をダンプ（2026-11-23・実機）。生要素に含まれる値と
//   正 GT の対応（最終訂正・真 GT で逆転済み）:
//   * 98108（SCORE 行・cx 0.8448, cy 0.4987）= score ✓
//   * 975（cx 0.6603, cy 0.6293）= cool 行の値（COOL ラベル cx 0.5254 同 cy）✓
//     dx=0.1349, dy=0.0013 — 正しいペアリング
//   * 58（cx 0.6709, cy 0.6777）= great 行の値（GREAT ラベル cy 0.6751 と同行）✓
//     dx=0.1357, dy=0.0027
//   * 733（cx 0.9416, cy 0.7195）= maxCombo 行の値（COMBO ラベル cy 0.7195）✓
//     dx=0.1464, dy=0.0001
//   * GOOD 行（GOOD ラベル cx 0.5271, cy 0.7288）: 値は全画面に無い（2）
//     GOOD↔975 dy=0.0995 で dy ゲート（0.012）から外れる
//   * BAD 行（BAD ラベル cx 0.7720, cy 0.6605）: 値は全画面に無い（1）
//     BAD↔58 dy=0.017 で dy ゲートから外れる
//
// 最終訂正: region 合成は実 region クロップのダンプが存在しないため廃止する。
//   ホスト検証の期待値は full-page のみで、good=2/bad=1 の充填正確性は
//   ホスト対象外として、実機 end-to-end（App-UI が正種別で実施）で確認する。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';

/// 実機ダンプ fixture のパス（生成手順は冒頭コメント）。
const String _fixturePath = 'test/fixtures/ocr/23bjim_repro_elements.json';

/// 画像寸法（ML Kit の要素 extent から算出・実測 W=1182,H=754）。
const int _width = 1182;
const int _height = 754;

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
  group('repro: 23bjim correct GT(host replay, full-page only)', () {
    test('extract on raw device elements reproduces the correct values: '
        'score=98108 / cool=975 / great=58 / maxCombo=733 and '
        'good/bad null (full-page has no values)', () {
      final page = _loadPage(_fixturePath);
      final result = const FieldExtractor().extract(page);

      // 正 GT と完全一致（回転はなかった）: score=98108 / cool=975 /
      // great=58 / maxCombo=733。全画面の good=2・bad=1 は要素なし。
      expect(result.score?.value, 98108, reason: 'score');
      expect(result.cool?.value, 975, reason: 'cool (975) is correct');
      expect(result.great?.value, 58, reason: 'great (58) is correct');
      expect(result.maxCombo?.value, 733, reason: 'maxCombo (733) is correct');
      expect(result.good, isNull, reason: 'GOOD value (2) not in full-page');
      expect(
        result.bad,
        isNull,
        reason:
            'BAD value (1) not in full-page (dy gate excludes GREAT-row 58)',
      );
      expect(result.level, isNull);
    });

    test(
      'extractWithRegions with empty region map keeps full-page values '
      '(region synthesis abolished; supplement accuracy is out of host scope)',
      () {
        // 実 region クロップのダンプが存在しないため、region 合成は廃止。
        // 空の region map で full-page 値のみを確認し、good/bad=2/1 の
        // 充填正確性は end-to-end に委ねる（リード最終訂正）。
        final page = _loadPage(_fixturePath);
        final result = const FieldExtractor().extractWithRegions(
          page,
          const {},
        );

        expect(result.score?.value, 98108, reason: 'score stays 98108');
        expect(
          result.cool?.value,
          975,
          reason: 'cool stays 975 (not overwritten)',
        );
        expect(result.great?.value, 58, reason: 'great stays 58');
        expect(result.maxCombo?.value, 733, reason: 'maxCombo stays 733');
        expect(
          result.good,
          isNull,
          reason:
              'good remains null without region OCR (checked in e2e, not host)',
        );
        expect(
          result.bad,
          isNull,
          reason:
              'bad remains null without region OCR (checked in e2e, not host)',
        );
        expect(result.bad?.value, isNot(44), reason: 'bad must not be 44');
      },
    );
  });
}
