// Lively の値読み取り（値列 x 範囲 + 行バンド）の単体テスト。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/lively/lively_geometry.dart';
import 'package:scoreyomipm/ocr/lively/lively_value_parser.dart';

OcrElement _text(String text, Rect box) =>
    OcrElement(text: text, boundingBox: box, confidence: 0.9);

void main() {
  const anchor = LivelyAnchor(ox: 100, oy: 250, pitch: 100);
  const parser = LivelyValueParser();

  LivelyToP panelToP() =>
      (Offset c) => Offset(anchor.pOfX(c.dx), anchor.pOfY(c.dy));

  test('パネル 1 パスで行ごとの値を読む（ラベル文字は拾わない）', () {
    final elements = <OcrElement>[
      _text('COOL', const Rect.fromLTRB(100, 155, 160, 175)),
      _text('12,345', const Rect.fromLTRB(700, 0, 1000, 40)),
      _text('123', const Rect.fromLTRB(700, 155, 800, 175)),
      _text('45', const Rect.fromLTRB(700, 245, 780, 265)),
      _text('0', const Rect.fromLTRB(700, 335, 740, 355)),
      _text('6', const Rect.fromLTRB(700, 430, 740, 450)),
      _text('120', const Rect.fromLTRB(700, 560, 800, 580)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: LivelyRow.values.toSet(),
    );

    expect(values[LivelyRow.score]!.value, 12345);
    expect(values[LivelyRow.cool]!.value, 123);
    expect(values[LivelyRow.great]!.value, 45);
    expect(values[LivelyRow.good]!.value, 0);
    expect(values[LivelyRow.bad]!.value, 6);
    expect(values[LivelyRow.combo]!.value, 120);
    expect(values[LivelyRow.best], isNull);
  });

  test('値列より左（ラベル側）の数字は読まない', () {
    final elements = <OcrElement>[
      // x 中心 150 → P 0.5。ラベル帯の中なので採用しない。
      _text('9', const Rect.fromLTRB(100, 155, 200, 175)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.cool},
    );

    expect(values, isEmpty);
  });

  test('行バンドの外にある数字は読まない', () {
    final elements = <OcrElement>[
      // y 中心 250 → GREAT 行の中心。COOL 行としては範囲外。
      _text('77', const Rect.fromLTRB(700, 240, 800, 260)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.cool},
    );

    expect(values, isEmpty);
  });

  test('同じ数字が重複して返っても幅の広いほうだけを連結する', () {
    final elements = <OcrElement>[
      _text('12', const Rect.fromLTRB(700, 155, 760, 175)),
      _text('123', const Rect.fromLTRB(700, 155, 800, 175)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.cool},
    );

    expect(values[LivelyRow.cool]!.value, 123);
    expect(values[LivelyRow.cool]!.elementCount, 1);
  });

  test('分割された数字は x 順に連結する', () {
    final elements = <OcrElement>[
      _text('56', const Rect.fromLTRB(900, 155, 960, 175)),
      _text('12', const Rect.fromLTRB(700, 155, 760, 175)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.cool},
    );

    expect(values[LivelyRow.cool]!.value, 1256);
  });

  test('行ブロックは局所座標を P へ逆写像して同じ規則で読む', () {
    const blockP = livelyCounterBlockP;
    const width = 1000.0;
    const heightPx = 900.0;
    // P(4.5, 0.05) は GREAT 行の値列。ブロック内の px に落とす。
    Offset toBlockPx(double xP, double yP) => Offset(
      (xP - blockP.left) / blockP.width * width,
      (yP - blockP.top) / blockP.height * heightPx,
    );
    final center = toBlockPx(5.0, 0.05);
    final elements = <OcrElement>[
      _text(
        '456',
        Rect.fromLTRB(
          center.dx - 60,
          center.dy - 10,
          center.dx + 60,
          center.dy + 10,
        ),
      ),
    ];

    final values = parser.parse(
      elements,
      toP: (c) => Offset(
        blockP.left + c.dx / width * blockP.width,
        blockP.top + c.dy / heightPx * blockP.height,
      ),
      rows: <LivelyRow>{LivelyRow.great},
    );

    expect(values[LivelyRow.great]!.value, 456);
  });

  test('桁が異常な値は捨てる（スコア 8 桁・判定数 6 桁）', () {
    final elements = <OcrElement>[
      _text('12345678', const Rect.fromLTRB(700, 0, 1000, 40)),
      _text('123456', const Rect.fromLTRB(700, 155, 800, 175)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.score, LivelyRow.cool},
    );

    expect(values, isEmpty);
  });

  test('採用要素の外接矩形は連結した全要素を包む', () {
    final elements = <OcrElement>[
      _text('12', const Rect.fromLTRB(700, 155, 760, 175)),
      _text('56', const Rect.fromLTRB(900, 155, 960, 175)),
    ];

    final values = parser.parse(
      elements,
      toP: panelToP(),
      rows: <LivelyRow>{LivelyRow.cool},
    );

    final box = values[LivelyRow.cool]!.boundingBox;
    expect(box.left, 700);
    expect(box.right, 960);
  });
}
