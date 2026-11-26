// Lively 幾何（P 単位）の単体テスト。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/lively/lively_geometry.dart';

OcrElement _label(
  String text, {
  required double left,
  required double centerY,
  double width = 60,
  double height = 30,
}) {
  return OcrElement(
    text: text,
    boundingBox: Rect.fromLTRB(
      left,
      centerY - height / 2,
      left + width,
      centerY + height / 2,
    ),
    confidence: 1.0,
  );
}

void main() {
  group('LivelyAnchor.detect', () {
    test('COOL/GREAT/GOOD/BAD の実測位置から oy と pitch を復元する', () {
      // oy=500（GREAT 中心）, pitch=100 で各行ラベルを配置する。
      const oy = 500.0;
      const pitch = 100.0;
      const ox = 300.0;
      final elements = <OcrElement>[
        _label('COOL', left: ox, centerY: oy + -0.85 * pitch),
        _label('GREAT', left: ox, centerY: oy + 0.05 * pitch),
        _label('GOOD', left: ox, centerY: oy + 0.95 * pitch),
        _label('BAD', left: ox, centerY: oy + 1.90 * pitch),
      ];

      final anchor = LivelyAnchor.detect(elements);

      expect(anchor, isNotNull);
      expect(anchor!.ox, closeTo(ox, 0.001));
      expect(anchor.oy, closeTo(oy, 0.001));
      expect(anchor.pitch, closeTo(pitch, 0.001));
      expect(anchor.labelCount, 4);
    });

    test('GREAT が無ければ基準点は作らない（誤った位置で読まない）', () {
      final elements = <OcrElement>[
        _label('COOL', left: 100, centerY: 400),
        _label('GOOD', left: 100, centerY: 600),
        _label('BAD', left: 100, centerY: 690),
      ];

      expect(LivelyAnchor.detect(elements), isNull);
    });

    test('ラベルが 1 つだけなら pitch を決められないので null', () {
      final elements = <OcrElement>[_label('GREAT', left: 100, centerY: 400)];

      expect(LivelyAnchor.detect(elements), isNull);
    });

    test('COOL が欠けても GREAT/GOOD/BAD で pitch を決める', () {
      const oy = 200.0;
      const pitch = 80.0;
      final elements = <OcrElement>[
        _label('GREAT', left: 50, centerY: oy + 0.05 * pitch),
        _label('GOOD', left: 50, centerY: oy + 0.95 * pitch),
        _label('BAD', left: 50, centerY: oy + 1.90 * pitch),
      ];

      final anchor = LivelyAnchor.detect(elements);

      expect(anchor, isNotNull);
      expect(anchor!.pitch, closeTo(pitch, 0.001));
      expect(anchor.oy, closeTo(oy, 0.001));
      expect(anchor.labelCount, 3);
    });

    test('GREAT143 のような結合文字列でも GREAT 行として拾う', () {
      final elements = <OcrElement>[
        _label('GREAT143', left: 100, centerY: 405),
        _label('GOOD', left: 100, centerY: 495),
      ];

      final anchor = LivelyAnchor.detect(elements);

      expect(anchor, isNotNull);
      expect(anchor!.pitch, closeTo(100, 0.001));
    });

    test('文字なし要素（数字だけ）はラベルとして扱わない', () {
      final elements = <OcrElement>[
        _label('12345', left: 100, centerY: 405),
        _label('67891', left: 100, centerY: 495),
      ];

      expect(LivelyAnchor.detect(elements), isNull);
    });
  });

  group('LivelyAnchor の矩形', () {
    const anchor = LivelyAnchor(ox: 300, oy: 500, pitch: 100);

    test('COOL の値セルは値列 x 範囲と行バンドで決まる', () {
      final rect = anchor.valueCellOf(LivelyRow.cool);

      expect(rect.left, closeTo(300 + livelyValueLeftP * 100, 0.001));
      expect(rect.right, closeTo(300 + livelyValueRightP * 100, 0.001));
      expect(rect.top, closeTo(500 + -1.35 * 100, 0.001));
      expect(rect.bottom, closeTo(500 + -0.35 * 100, 0.001));
    });

    test('P 座標への逆写像が往復する', () {
      expect(anchor.pOfX(anchor.xOf(4.5)), closeTo(4.5, 1e-9));
      expect(anchor.pOfY(anchor.yOf(-2.65)), closeTo(-2.65, 1e-9));
    });
  });

  group('LivelyPanelBox.fromLabels', () {
    test('ラベル外接矩形に余白を足した枠を返す', () {
      final elements = <OcrElement>[
        _label('GREAT', left: 300, centerY: 500, width: 60, height: 30),
      ];

      final box = LivelyPanelBox.fromLabels(elements)!;
      // 高さ 30 のラベル 1 個 → 上 0.80*30=24、下 0.25*30=7.5。
      expect(box.rect.left, closeTo(300 - 0.30 * 30, 0.001));
      expect(box.rect.top, closeTo(485 - 24, 0.001));
      expect(box.rect.right, closeTo(360 + 1.25 * 30, 0.001));
      expect(box.rect.bottom, closeTo(515 + 7.5, 0.001));
    });

    test('ラベルが無ければ null', () {
      final elements = <OcrElement>[_label('12345', left: 300, centerY: 500)];

      expect(LivelyPanelBox.fromLabels(elements), isNull);
    });

    test('画像外にはみ出す枠は画像内に切る', () {
      final elements = <OcrElement>[
        _label('GREAT', left: 5, centerY: 10, width: 60, height: 30),
      ];

      final box = LivelyPanelBox.fromLabels(
        elements,
        imageWidth: 400,
        imageHeight: 300,
      )!;

      expect(box.rect.left, 0);
      expect(box.rect.top, 0);
      expect(box.rect.right, lessThanOrEqualTo(400));
      expect(box.rect.bottom, lessThanOrEqualTo(300));
    });
  });

  group('数値判定', () {
    test('カンマ区切りは数値として扱い、桁を連結する', () {
      expect(livelyIsNumeric('12,345'), isTrue);
      expect(livelyParseInt('12,345'), 12345);
    });

    test('英字を含む要素は数値ではない', () {
      expect(livelyIsNumeric('GREAT'), isFalse);
      expect(livelyIsNumeric('12a'), isFalse);
    });
  });
}
