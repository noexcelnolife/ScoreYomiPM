// Lively 経路（統合 4 パス）の単体テスト。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/lively/lively_geometry.dart';
import 'package:scoreyomipm/ocr/lively/lively_ocr_route.dart';
import 'package:scoreyomipm/ocr/lively/lively_panel_rectifier.dart';

import '../../fake_ocr_engine.dart';

/// パネル切り出しを差し替える（座標系を固定してテストを決定的にする）。
class _FixedRectifier extends LivelyPanelRectifier {
  const _FixedRectifier(this.panel);

  final img.Image panel;

  @override
  img.Image? rectify(img.Image photo, Rect box) => panel;
}

OcrElement _text(String text, Rect box) =>
    OcrElement(text: text, boundingBox: box, confidence: 0.9);

/// P 座標をブロック出力（[width] x [height]）の px へ落とす。
Rect _blockBox(
  Rect blockP,
  double xP,
  double yP, {
  required int width,
  required int height,
  double boxWidth = 80,
  double boxHeight = 20,
}) {
  final cx = (xP - blockP.left) / blockP.width * width;
  final cy = (yP - blockP.top) / blockP.height * height;
  return Rect.fromLTRB(
    cx - boxWidth / 2,
    cy - boxHeight / 2,
    cx + boxWidth / 2,
    cy + boxHeight / 2,
  );
}

void main() {
  const panelWidth = 1050;
  const panelHeight = 600;

  img.Image panelImage() =>
      img.Image(width: panelWidth, height: panelHeight, numChannels: 3);

  /// 実測相当のラベルと値を持つパネル 1 パスの応答。
  OcrPageResult panelPass({String cool = '123', String bad = '6'}) {
    return OcrPageResult(
      elements: <OcrElement>[
        _text('COOL', const Rect.fromLTRB(100, 155, 160, 175)),
        _text('GREAT', const Rect.fromLTRB(100, 245, 160, 265)),
        _text('GOOD', const Rect.fromLTRB(100, 335, 160, 355)),
        _text('BAD', const Rect.fromLTRB(100, 430, 160, 450)),
        _text('98765', const Rect.fromLTRB(700, 10, 1000, 50)),
        _text(cool, const Rect.fromLTRB(700, 155, 800, 175)),
        _text('45', const Rect.fromLTRB(700, 245, 780, 265)),
        _text('0', const Rect.fromLTRB(700, 335, 740, 355)),
        _text(bad, const Rect.fromLTRB(700, 430, 740, 450)),
        _text('120', const Rect.fromLTRB(700, 560, 800, 580)),
      ],
      fullText: 'COOL GREAT GOOD BAD 98765 123 45 0 6 120',
      imageWidth: panelWidth,
      imageHeight: panelHeight,
    );
  }

  OcrPageResult countersPass({String cool = '124', String bad = '8'}) {
    return OcrPageResult(
      elements: <OcrElement>[
        _text(
          cool,
          _blockBox(livelyCounterBlockP, 6.5, -0.85, width: 1000, height: 900),
        ),
        _text(
          '45',
          _blockBox(livelyCounterBlockP, 6.4, 0.05, width: 1000, height: 900),
        ),
        _text(
          '0',
          _blockBox(livelyCounterBlockP, 6.2, 0.95, width: 1000, height: 900),
        ),
        _text(
          bad,
          _blockBox(livelyCounterBlockP, 6.2, 1.90, width: 1000, height: 900),
        ),
      ],
      fullText: '124 45 0 8',
      imageWidth: 1000,
      imageHeight: 900,
    );
  }

  OcrPageResult combosPass() {
    return OcrPageResult(
      elements: <OcrElement>[
        _text(
          '120',
          _blockBox(livelyComboBlockP, 6.5, 3.20, width: 1000, height: 900),
        ),
      ],
      fullText: '120',
      imageWidth: 1000,
      imageHeight: 900,
    );
  }

  OcrPageResult scorePass() {
    return OcrPageResult(
      elements: <OcrElement>[
        _text(
          '98765',
          _blockBox(livelyScoreBlockP, 7.5, -2.30, width: 1000, height: 260),
        ),
      ],
      fullText: '98765',
      imageWidth: 1000,
      imageHeight: 260,
    );
  }

  late Directory tempDir;
  late File photoFile;
  // WHY(バイト列も持つか): LivelyOcrRoute.run の入力がバイト列になったため。
  // 画像を生成している都合で一時ファイルも残すが、経路にはバイト列を渡す。
  late Uint8List photoBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lively_route_test_');
    photoFile = File('${tempDir.path}${Platform.pathSeparator}photo.jpg');
    final photo = img.Image(width: 1000, height: 800, numChannels: 3);
    img.fill(photo, color: img.ColorRgb8(30, 30, 30));
    photoFile.writeAsBytesSync(img.encodeJpg(photo, quality: 90));
    photoBytes = photoFile.readAsBytesSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('4 パスを回して統合結果を返す', () async {
    final responses = <OcrPageResult>[
      panelPass(),
      countersPass(),
      combosPass(),
      scorePass(),
    ];
    var calls = 0;
    final engine = FakeOcrEngine(
      onRecognize: (Uint8List bytes) async {
        final result = responses[calls.clamp(0, responses.length - 1)];
        calls++;
        return result;
      },
    );
    final route = LivelyOcrRoute(
      engine: engine,
      rectifier: _FixedRectifier(panelImage()),
    );

    final outcome = await route.run(
      imageBytes: photoBytes,
      pageResult: _pageResultWithLabels(),
    );

    expect(calls, 4);
    final fields = outcome.extraction!.numericFields;
    expect(fields[NumericFieldKind.score]!.value, 98765);
    expect(fields[NumericFieldKind.cool]!.value, 123, reason: '食い違いはパネル側');
    expect(fields[NumericFieldKind.great]!.value, 45);
    expect(fields[NumericFieldKind.good]!.value, 0);
    expect(fields[NumericFieldKind.bad]!.value, 6, reason: '食い違いはパネル側');
    expect(fields[NumericFieldKind.maxCombo]!.value, 120);
    expect(outcome.failureReason, isNull);
  });

  test('パネルのラベルが無ければ抽出を諦める', () async {
    var calls = 0;
    final engine = FakeOcrEngine(
      onRecognize: (Uint8List bytes) async {
        calls++;
        return panelPass();
      },
    );
    final route = LivelyOcrRoute(
      engine: engine,
      rectifier: _FixedRectifier(panelImage()),
    );

    final outcome = await route.run(
      imageBytes: photoBytes,
      pageResult: OcrPageResult(
        elements: <OcrElement>[
          _text('12345', const Rect.fromLTRB(0, 0, 50, 20)),
        ],
        fullText: '12345',
        imageWidth: 1000,
        imageHeight: 800,
      ),
    );

    expect(calls, 0);
    expect(outcome.extraction, isNull);
    expect(outcome.failureReason, isNotNull);
  });

  test('基準点が取れないパネル応答なら抽出しない（誤値を登録しない）', () async {
    var calls = 0;
    final engine = FakeOcrEngine(
      onRecognize: (Uint8List bytes) async {
        calls++;
        // ラベルが読めず数値だけが返るパネル（GREAT が無い）。
        return OcrPageResult(
          elements: <OcrElement>[
            _text('98765', const Rect.fromLTRB(700, 10, 1000, 50)),
            _text('123', const Rect.fromLTRB(700, 155, 800, 175)),
          ],
          fullText: '98765 123',
          imageWidth: panelWidth,
          imageHeight: panelHeight,
        );
      },
    );
    final route = LivelyOcrRoute(
      engine: engine,
      rectifier: _FixedRectifier(panelImage()),
    );

    // ラベルはあるが GREAT が無い写真（パネル応答も数値だけ）。
    final outcome = await route.run(
      imageBytes: photoBytes,
      pageResult: _pageResultWithoutGreat(),
    );

    expect(calls, 1, reason: 'パネル 1 パスで基準点が作れず止まる');
    expect(outcome.extraction, isNull);
  });

  test('曲名帯はパネル上方の要素から作る', () async {
    var calls = 0;
    final engine = FakeOcrEngine(
      onRecognize: (Uint8List bytes) async {
        final responses = <OcrPageResult>[
          panelPass(),
          countersPass(),
          combosPass(),
          scorePass(),
        ];
        final result = responses[calls.clamp(0, responses.length - 1)];
        calls++;
        return result;
      },
    );
    final route = LivelyOcrRoute(
      engine: engine,
      rectifier: _FixedRectifier(panelImage()),
    );

    final outcome = await route.run(
      imageBytes: photoBytes,
      pageResult: _pageResultWithLabels(),
    );

    final title = outcome.regionOcr.results[RegionTarget.songTitle];
    expect(title, isNotNull);
    expect(title!.elements, isNotEmpty);
  });
}

/// 写真空間のラベル + 曲名（パネルは 100..200 x 300..450 のあたり）。
OcrPageResult _pageResultWithLabels() {
  return OcrPageResult(
    elements: <OcrElement>[
      _text('テスト曲', const Rect.fromLTRB(100, 100, 400, 140)),
      _text('COOL', const Rect.fromLTRB(100, 300, 200, 330)),
      _text('GREAT', const Rect.fromLTRB(100, 340, 200, 370)),
      _text('GOOD', const Rect.fromLTRB(100, 380, 200, 410)),
      _text('BAD', const Rect.fromLTRB(100, 420, 200, 450)),
    ],
    fullText: 'テスト曲 COOL GREAT GOOD BAD',
    imageWidth: 1000,
    imageHeight: 800,
  );
}

OcrPageResult _pageResultWithoutGreat() {
  return OcrPageResult(
    elements: <OcrElement>[
      _text('COOL', const Rect.fromLTRB(100, 300, 200, 330)),
      _text('GOOD', const Rect.fromLTRB(100, 340, 200, 370)),
    ],
    fullText: 'COOL GOOD',
    imageWidth: 1000,
    imageHeight: 800,
  );
}
