import 'dart:io';
import 'dart:typed_data';
import 'dart:ui'
    as ui
    show ImageByteFormat, ImageDescriptor, ImmutableBuffer, PixelFormat;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';

/// recognizeWithScript を差し替えた記録用 fake（ML Kit プラグイン非依存）。
///
/// WHY: 再試行チェーンの呼び出し回数・script 遷移・各段に渡る画像寸法を
/// 固定するため、ML Kit 本体を呼ばずに呼び出し記録と canned 結果を返す
/// （ST-5 2-H 連鎖剥離・01a2036e・r7 相当への回帰）。渡された PNG の寸法は
/// ヘッダ読み（ImageDescriptor.encoded）で実測する。なおダミー画像は
/// headless でピクセルデコード可能なため本物の PNG を使う
/// （mlkit_engine_region_test.dart と同一の方針）。
class _RecordingScriptEngine extends MlKitOcrEngine {
  _RecordingScriptEngine(this._results);

  final List<OcrPageResult> _results;
  final List<String> scripts = <String>[];
  final List<String> dims = <String>[];
  int _callIndex = 0;

  @override
  Future<OcrPageResult> recognizeWithScript(
    File imageFile,
    MlKitScript script,
  ) async {
    final bytes = await imageFile.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    scripts.add(script.name);
    dims.add('${descriptor.width}x${descriptor.height}');
    descriptor.dispose();
    buffer.dispose();
    return _results[_callIndex++];
  }
}

/// (v, v, 255) の市松 16×8 RGBA。luma が 30/200 の 2 ビンになるため、
/// 二値化（binarize）が縮退 null にならずチェーンが 2 次以降へ進む。
Uint8List _checkerboardRgba() {
  final rgba = Uint8List(16 * 8 * 4);
  var o = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 16; x++) {
      final v = (x + y) % 2 == 0 ? 30 : 200;
      rgba[o] = v;
      rgba[o + 1] = v;
      rgba[o + 2] = v;
      rgba[o + 3] = 255;
      o += 4;
    }
  }
  return rgba;
}

/// 市松 16×8 の PNG を一時ディレクトリへ書き出す。
Future<File> _writeFixturePng(Directory dir) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(_checkerboardRgba());
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: 16,
    height: 8,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  codec.dispose();
  frame.image.dispose();
  descriptor.dispose();
  buffer.dispose();
  final file = File('${dir.path}/source.png');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

OcrPageResult _emptyResult() => OcrPageResult(
  elements: const [],
  fullText: '',
  imageWidth: 16,
  imageHeight: 8,
);

OcrPageResult _oneElementResult() => OcrPageResult(
  elements: <OcrElement>[
    OcrElement(
      text: 'T',
      boundingBox: const Rect.fromLTWH(0, 0, 4, 2),
      confidence: 0.9,
    ),
  ],
  fullText: 'T',
  imageWidth: 16,
  imageHeight: 8,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File sourcePng;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scoreyomipm_2h');
    sourcePng = await _writeFixturePng(tempDir);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // WHY: 削除失敗は検証に影響しないため無視する（recognizeRegion の
      // 一時ディレクトリ契約と同一方針・Windows のロック対策）。
    }
  });

  group('MlKitOcrEngine contrastRetry chain (剥離後・r7 相当)', () {
    test('2次でも 0 要素: 3/4 次は発火せず 1 次結果を返す', () async {
      // WHY 剥離後の本体契約（01a2036e・r7 相当）: contrastRetry による再
      // 試行は二値化 2 次まで。2 次が 0 要素なら 1 次結果を返して終端する
      // （かつての 4:3 パッド 3 次 / Latin 4 次は r8（1891a04）のキル基準
      // 裁定で剥離済み・呼び出しは 2 回で止まることを canned 結果 4 個で
      // 固定する）。
      final engine = _RecordingScriptEngine(<OcrPageResult>[
        _emptyResult(),
        _emptyResult(),
        _emptyResult(),
        _emptyResult(),
      ]);

      final result = await engine.recognizeRegion(
        sourcePng.readAsBytesSync(),
        const Rect.fromLTWH(0, 0, 16, 8),
        script: OcrScript.japanese,
        pixelScale: 1.0,
        contrastRetry: true,
      );

      expect(engine.scripts, <String>['japanese', 'japanese']);
      expect(engine.dims, <String>['16x8', '16x8']);
      expect(result.elements, isEmpty);
    });

    test('2次で 1 要素以上: 2次結果を返す', () async {
      // WHY 2 次成功経路の契約（2-G e8c28d3 から通し）: 二値化 2 次が成功
      // した時点で返却し、追加段を発火させない。
      final engine = _RecordingScriptEngine(<OcrPageResult>[
        _emptyResult(),
        _oneElementResult(),
      ]);

      final result = await engine.recognizeRegion(
        sourcePng.readAsBytesSync(),
        const Rect.fromLTWH(0, 0, 16, 8),
        script: OcrScript.japanese,
        pixelScale: 1.0,
        contrastRetry: true,
      );

      expect(engine.scripts, <String>['japanese', 'japanese']);
      expect(engine.dims, <String>['16x8', '16x8']);
      expect(result.elements, hasLength(1));
    });

    test('1 次が Latin でも構造は同一: 呼出は 2 回（パッド段・Latin 再試行なし）', () async {
      // WHY script 因子の剥離固定: かつての 4 次は「同パッド画像で Latin」
      // だったが、剥離後は 1 次スクリプトに関係なく 2 呼出で終端する
      // （Latin 1 次でも 3/4 次相当の追加呼出が復活していないことを固定）。
      final engine = _RecordingScriptEngine(<OcrPageResult>[
        _emptyResult(),
        _emptyResult(),
        _emptyResult(),
        _emptyResult(),
      ]);

      final result = await engine.recognizeRegion(
        sourcePng.readAsBytesSync(),
        const Rect.fromLTWH(0, 0, 16, 8),
        script: OcrScript.latin,
        pixelScale: 1.0,
        contrastRetry: true,
      );

      expect(engine.scripts, <String>['latin', 'latin']);
      expect(engine.dims, <String>['16x8', '16x8']);
      expect(result.elements, isEmpty);
    });

    test('canned 4 段結果が残っていても呼出は 2 回で終端する', () async {
      // WHY 剥離の直接固定: 4 個目の canned 結果（1 要素）を用意しても
      // 使われない＝4 次段が存在しないことを呼び出し記録で検証する。
      final engine = _RecordingScriptEngine(<OcrPageResult>[
        _emptyResult(),
        _emptyResult(),
        _emptyResult(),
        _oneElementResult(),
      ]);

      final result = await engine.recognizeRegion(
        sourcePng.readAsBytesSync(),
        const Rect.fromLTWH(0, 0, 16, 8),
        script: OcrScript.japanese,
        pixelScale: 1.0,
        contrastRetry: true,
      );

      expect(engine.scripts, <String>['japanese', 'japanese']);
      expect(engine.dims, <String>['16x8', '16x8']);
      expect(result.elements, isEmpty);
    });

    test('contrastRetry=false: 再試行チェーン自体を発火させない', () async {
      // WHY 既存 2-G 契約のガード: フラグなし経路の入力は 1 呼出のまま
      // 不変（r6 で復帰済みの成功キーの保護に直結）。
      final engine = _RecordingScriptEngine(<OcrPageResult>[_emptyResult()]);

      final result = await engine.recognizeRegion(
        sourcePng.readAsBytesSync(),
        const Rect.fromLTWH(0, 0, 16, 8),
        script: OcrScript.japanese,
        pixelScale: 1.0,
        contrastRetry: false,
      );

      expect(engine.scripts, <String>['japanese']);
      expect(engine.dims, <String>['16x8']);
      expect(result.elements, isEmpty);
    });
  });
}
