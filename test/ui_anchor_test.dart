// ST-3.5（共通 UI アンカー登録）の unit テスト（TDD red 先行）。
//
// 設計: docs/st3_5_ui_anchor_design_confirmation_2026-11-22.md
// （docs 単独コミット c8c9e00・リード検収承認済み）。
//
// 契約の固定点:
// - 値型（AnchorRegistration/AnchorHit）は純データで、画像デコードなしに
//   構築できること（リード受け入れ条件①・DIP。buildSpecs 側テストは
//   test/region_spec_anchor_test.dart・本ファイルは値型と検出機構を担う）。
// - NCC/columnEdge の検出機構は合成画像で契約を固定する（実画像 39 枚の
//   検出率/位置誤差/コストは integration red で別途検証する。unit は
//   実装の数値契約を守る役割）。
// 実装 lib/ocr/ui_anchor.dart が存在しないため、現状は RED（コンパイルエラー）。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/ocr/ui_anchor.dart';

/// 合成系を構築する縮小率。
///
/// WHY: 実装の探索は /4 縮小画像に対して行う（設計 §1.2）。テストも同じ
/// 縮小率でテンプレート/探索画像を作ることで、実装の内部定数変更時に
/// テンプレート縮小の整合が崩れたことを検出できる。
const int _testDownscale = 4;

/// 単色で埋めた合成画像。
img.Image _flatImage(int width, int height, {int gray = 60}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, gray, gray, gray);
    }
  }
  return image;
}

/// (cx, cy) 中心の上下 2 値ブロック模様（上半分=白・下半分=黒）を描く。
///
/// WHY 上下 2 値: NCC が x 方向の縞の位相に依存しない（縞模様は縮小後の
/// 位相ズレで相関が崩れるため契約テストには不適）。上下非対称で
/// y 反転の誤一致も起こらない。
void _drawPattern(img.Image image, int cx, int cy, int w, int h) {
  final left = cx - w ~/ 2;
  final top = cy - h ~/ 2;
  for (var y = top; y < top + h; y++) {
    for (var x = left; x < left + w; x++) {
      if (x < 0 || y < 0 || x >= image.width || y >= image.height) {
        continue;
      }
      final v = y < cy ? 255 : 0;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
}

/// 実装と同じ縮小（/4・average）をテスト側でも適用する。
img.Image _downscaled(img.Image image) => img.copyResize(
  image,
  width: image.width ~/ _testDownscale,
  height: image.height ~/ _testDownscale,
  interpolation: img.Interpolation.average,
);

/// 縮小画像の (cx, cy) 中心に w×h のテンプレートを作る。
UiAnchorTemplate _templateFrom(
  img.Image downscaled,
  int cx,
  int cy,
  int w,
  int h,
) {
  final left = cx - w ~/ 2;
  final top = cy - h ~/ 2;
  final gray = Uint8List(w * h);
  var i = 0;
  for (var y = top; y < top + h; y++) {
    for (var x = left; x < left + w; x++) {
      // 実装側（ui_anchor.dart _grayscaleOf）と同じ v4 API・輝度式を使う。
      gray[i++] = downscaled.getPixel(x, y).luminance.toInt();
    }
  }
  return UiAnchorTemplate(width: w, height: h, gray: gray);
}

/// 合成画像を PNG バイト列にする。
///
/// WHY ファイルに書かないか: 検出器の入力はバイト列。一時ファイルを作ると
/// 「テストが落ちたとき temp に残る」失敗モードだけが増える。
Uint8List _pngBytes(img.Image image) => img.encodePng(image);

AnchorPack _pack({
  required List<AnchorDefinition> definitions,
  Map<String, UiAnchorTemplate> templates = const {},
}) {
  return AnchorPack(
    version: 'test_v1',
    definitions: definitions,
    templates: templates,
  );
}

void main() {
  test('AnchorRegistration/AnchorHit は画像デコードなしで構築・照会できる', () {
    // リード受け入れ条件①: 幾何層に渡る値はプレーンな位置+スコア。
    const hit = AnchorHit(
      id: 'gaugeHeader',
      position: Offset(0.579, 0.364),
      score: 0.9,
      canonicalPosition: Offset(0.579, 0.352),
    );
    const registration = AnchorRegistration(hits: {'gaugeHeader': hit});
    expect(
      registration.hitOf('gaugeHeader')!.position.dx,
      closeTo(0.579, 1e-9),
    );
    expect(
      registration.hitOf('gaugeHeader')!.position.dy,
      closeTo(0.364, 1e-9),
    );
    expect(registration.hitOf('gaugeHeader')!.score, closeTo(0.9, 1e-9));
    expect(registration.hitOf('unknown'), isNull);
  });

  test('NCC: canonical 位置の同型パターンを score≈1.0・位置一致で検出する', () async {
    // 320x200 合成画像の (160, 60)（縮小後 (40, 15)・正規化 (0.5, 0.3)）。
    final full = _flatImage(320, 200);
    _drawPattern(full, 160, 60, 32, 20);
    final small = _downscaled(full);
    final template = _templateFrom(small, 40, 15, 14, 9);
    final bytes = _pngBytes(full);

    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'gaugeHeader',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.3),
          threshold: 0.55,
          templateAsset: 'gauge.png',
        ),
      ],
      templates: {'gauge.png': template},
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    final hit = registration!.hitOf('gaugeHeader');
    expect(hit, isNotNull);
    expect(hit!.score, greaterThanOrEqualTo(0.90));
    expect(hit.position.dx, closeTo(0.5, 0.04));
    expect(hit.position.dy, closeTo(0.3, 0.05));
  });

  test('NCC: canonical から既知オフセットの位置にあるパターンを検出する', () async {
    // 模様を canonical から (+32, +24) px（縮小後 +8, +6・探索窓 ±24px 内）
    // ずらして描き、探索が位置を追跡できることを固定する。
    // テンプレートは canonical 位置に模様がある系から切り出す（実テンプレ
    // 資産と同様に canonical を基準に切り出す運用の再現）。
    final canonicalFull = _flatImage(320, 200);
    _drawPattern(canonicalFull, 160, 60, 32, 20);
    final template = _templateFrom(_downscaled(canonicalFull), 40, 15, 14, 9);

    final full = _flatImage(320, 200);
    _drawPattern(full, 192, 84, 32, 20);
    final bytes = _pngBytes(full);

    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'gaugeHeader',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.3),
          threshold: 0.55,
          templateAsset: 'gauge.png',
        ),
      ],
      templates: {'gauge.png': template},
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    final hit = registration!.hitOf('gaugeHeader');
    expect(hit, isNotNull);
    expect(hit!.score, greaterThanOrEqualTo(0.80));
    expect(hit.position.dx, closeTo(0.6, 0.04));
    expect(hit.position.dy, closeTo(0.42, 0.05));
  });

  test('NCC: 無地画像ではヒットしない（分散 0 は score 0 扱い・閾値未満）', () async {
    final bytes = _pngBytes(_flatImage(320, 200));
    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'gaugeHeader',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.3),
          threshold: 0.55,
          templateAsset: 'gauge.png',
        ),
      ],
      templates: {
        'gauge.png': UiAnchorTemplate(
          width: 14,
          height: 9,
          // WHY 一様 255: tVar=0 の一様テンプレートは NCC 不成立経路の契約。
          gray: Uint8List.fromList(List<int>.filled(14 * 9, 255)),
        ),
      },
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    expect(registration, isNotNull);
    expect(registration!.hitOf('gaugeHeader'), isNull);
  });

  test('columnEdge: 全高縦線を canonical 近傍 x で検出する', () async {
    // 4px 幅の縦線（縮小後 1px 列が完全に明るくなる）を x=0.45W に引く。
    final full = _flatImage(320, 200);
    for (var y = 0; y < 200; y++) {
      for (var x = 144; x < 148; x++) {
        full.setPixelRgb(x, y, 200, 200, 200);
      }
    }
    final bytes = _pngBytes(full);

    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'frameRight',
          kind: AnchorKind.columnEdge,
          canonicalPosition: Offset(0.45, 0.5),
          threshold: 0.098,
        ),
      ],
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    final hit = registration!.hitOf('frameRight');
    expect(hit, isNotNull);
    // 列強度 |dx| = 200-60 = 140 → 140/255 ≈ 0.549。
    expect(hit!.score, greaterThanOrEqualTo(0.4));
    expect(hit.position.dx, closeTo(0.45, 0.05));
    // 列エッジに y 方向の意味はないため canonical の y を通す（契約）。
    expect(hit.position.dy, closeTo(0.5, 1e-9));
  });

  test('columnEdge: 縦線のない画像では null', () async {
    final bytes = _pngBytes(_flatImage(320, 200));
    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'frameRight',
          kind: AnchorKind.columnEdge,
          canonicalPosition: Offset(0.45, 0.5),
          threshold: 0.098,
        ),
      ],
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    expect(registration, isNotNull);
    expect(registration!.hitOf('frameRight'), isNull);
  });

  test('detect: 成立しないアンカーは hits から漏れ、成立したものだけ入る', () async {
    final full = _flatImage(320, 200);
    _drawPattern(full, 160, 60, 32, 20); // gaugeHeader 位置にのみ模様。
    final bytes = _pngBytes(full);
    final canonicalFull = _flatImage(320, 200);
    _drawPattern(canonicalFull, 160, 60, 32, 20);
    final template = _templateFrom(_downscaled(canonicalFull), 40, 15, 14, 9);

    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'gaugeHeader',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.3),
          threshold: 0.55,
          templateAsset: 'gauge.png',
        ),
        const AnchorDefinition(
          id: 'difficultyEx',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.9),
          threshold: 0.55,
          templateAsset: 'ex.png',
        ),
      ],
      templates: {
        'gauge.png': template,
        // ex.png は同テンプレートだが canonical 近傍に模様がない → 不成立。
        'ex.png': template,
      },
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    expect(registration!.hitOf('gaugeHeader'), isNotNull);
    expect(registration.hitOf('difficultyEx'), isNull);
  });

  test('detect: テンプレ未登録の NCC 定義はスキップされる（クラッシュしない）', () async {
    final bytes = _pngBytes(_flatImage(320, 200));
    final pack = _pack(
      definitions: [
        const AnchorDefinition(
          id: 'gaugeHeader',
          kind: AnchorKind.ncc,
          canonicalPosition: Offset(0.5, 0.3),
          threshold: 0.55,
          templateAsset: 'missing.png',
        ),
        const AnchorDefinition(
          id: 'frameRight',
          kind: AnchorKind.columnEdge,
          canonicalPosition: Offset(0.45, 0.5),
          threshold: 0.098,
        ),
      ],
    );

    final registration = AnchorRegistration.detect(bytes, pack);
    expect(registration, isNotNull);
    expect(registration!.hitOf('gaugeHeader'), isNull);
    expect(registration.hitOf('frameRight'), isNull);
  });

  test('detect: デコード不能なバイト列では null（機能 OFF 経路）', () async {
    final broken = Uint8List.fromList(<int>[0, 1, 2, 3, 4]);

    final pack = _pack(definitions: const []);
    expect(AnchorRegistration.detect(broken, pack), isNull);
  });

  test('asset 契約: assets/anchors/hc_v1 のパックが生成契約どおりに読める', () async {
    // WHY asset 契約テスト: 生成ツール（tool/generate_anchor_templates.dart）
    // が書いたパック JSON/PNG と lib 側の named 定数・canonical 設計値の
    // 整合を固定する。生成ツールの数式ミラーは実行時と同一条件だが、
    // ファイル形式・定数ミラーの齟齬はこのテストで検知する。
    // WHY binding 初期化: flutter test の test() 本文で rootBundle を使う
    // には TestWidgetsFlutterBinding の初期化が必要（未初期化だと
    // 「Binding has not yet been initialized」で機能 OFF 経路に落ちる）。
    TestWidgetsFlutterBinding.ensureInitialized();
    final pack = await AnchorPack.loadFromAssets('hc_v1');
    expect(pack, isNotNull);
    final p = pack!;

    final ids = p.definitions.map((d) => d.id).toSet();
    expect(
      ids,
      containsAll(const [
        'frameRight',
        'gaugeHeader',
        'settingsNormal',
        'difficultyEx',
      ]),
    );
    expect(p.definitions, hasLength(4));

    final byId = {for (final d in p.definitions) d.id: d};
    // NCC アンカーの閾値は _nccScoreThreshold のミラー（0.55・設計 §1.4）。
    for (final id in const ['gaugeHeader', 'settingsNormal', 'difficultyEx']) {
      expect(byId[id]!.kind, AnchorKind.ncc, reason: id);
      expect(byId[id]!.threshold, 0.55, reason: id);
      final asset = byId[id]!.templateAsset;
      expect(asset, isNotNull, reason: id);
      // テンプレートは loadFromAssets 内で /4 縮小済みで保持される。
      expect(p.templates[asset], isNotNull, reason: '$id テンプレート PNG が欠落/壊れ');
    }
    expect(byId['frameRight']!.kind, AnchorKind.columnEdge);
    expect(byId['frameRight']!.templateAsset, isNull);
    // columnEdge 閾値は _columnEdgeMinStrength(25) の正規化ミラー。
    expect(byId['frameRight']!.threshold * 255, closeTo(25, 1e-6));

    // canonical は生成ツールがフィクスチャ 30 枚から導出した実測 median
    //（設計 §1.2 事後確認値と一致・asset 契約で固定）。
    expect(byId['frameRight']!.canonicalPosition.dx, closeTo(0.4467, 1e-6));
    expect(byId['frameRight']!.canonicalPosition.dy, closeTo(0.5, 1e-6));
    expect(byId['gaugeHeader']!.canonicalPosition.dx, closeTo(0.5796, 0.002));
    expect(byId['gaugeHeader']!.canonicalPosition.dy, closeTo(0.3525, 0.002));
    expect(
      byId['settingsNormal']!.canonicalPosition.dx,
      closeTo(0.7088, 0.002),
    );
    expect(
      byId['settingsNormal']!.canonicalPosition.dy,
      closeTo(0.8163, 0.002),
    );
    expect(byId['difficultyEx']!.canonicalPosition.dx, closeTo(0.4738, 0.002));
    expect(byId['difficultyEx']!.canonicalPosition.dy, closeTo(0.1536, 0.002));

    // 縮小済みテンプレートが非空であること（デコード成功の実証）。
    for (final id in const ['gaugeHeader', 'settingsNormal', 'difficultyEx']) {
      final t = p.templates[byId[id]!.templateAsset]!;
      expect(t.width, greaterThan(0), reason: id);
      expect(t.height, greaterThan(0), reason: id);
      expect(t.gray, hasLength(t.width * t.height), reason: id);
    }
  });
}
