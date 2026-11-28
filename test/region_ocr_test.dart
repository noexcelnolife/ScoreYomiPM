import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/region_ocr.dart';

import 'test_image_helper.dart';

OcrElement el(String text, double cx, double cy, {double hNorm = 0.02}) =>
    OcrElement(
      text: text,
      boundingBox: Rect.fromCenter(
        center: Offset(cx * 1200, cy * 800),
        width: 60,
        height: hNorm * 800,
      ),
      confidence: 0.9,
    );

/// recognizeRegion の呼び出しを記録し、対象ごとの応答を返す fake エンジン。
///
/// WHY: クロップ再 OCR の TDD は「どの領域に・どのスクリプトで・何回
/// 呼ぶか」を呼び出し記録で検証する（リーダー指定）。認識内容そのものは
/// エミュレータ上の統合計測で検証する。
class _RecordingRegionEngine extends OcrEngine {
  _RecordingRegionEngine({
    OcrPageResult? regionResult,
    this.regionResults,
    this.exceptionTarget,
  }) : regionResult =
           regionResult ??
           OcrPageResult(
             elements: const [],
             fullText: '',
             imageWidth: 100,
             imageHeight: 40,
           );

  final OcrPageResult regionResult;

  /// 呼び出し順に応答を変える場合のリスト（null の場合は常に [regionResult]）。
  ///
  /// WHY: songTitle プライマリ空要素→フォールバック採用の検証には、
  /// 「1 回目は空、2 回目は曲名あり」という呼び出し順依存の応答が必要。
  final List<OcrPageResult>? regionResults;

  /// この対象の呼び出しでだけ [OcrEngineException] を投げる。
  final RegionTarget? exceptionTarget;

  final List<
    ({
      RegionTarget? nextTarget,
      Rect region,
      OcrScript script,
      double pixelScale,
      bool contrastRetry,
    })
  >
  calls = [];

  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async =>
      OcrPageResult.empty();

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    // 対象は呼ばれた順序で specs と一致する（先頭から）。
    final next = exceptionTarget != null && calls.length == _exceptionIndex
        ? exceptionTarget
        : null;
    calls.add((
      nextTarget: next,
      region: region,
      script: script,
      pixelScale: pixelScale,
      contrastRetry: contrastRetry,
    ));
    if (next != null) {
      throw OcrEngineException('region failure for $next');
    }
    // 呼び出し順に応答を変える（プライマリ空→フォールバック採用の検証用）。
    final responses = regionResults;
    if (responses != null) {
      final index = calls.length - 1;
      return index < responses.length ? responses[index] : responses.last;
    }
    return regionResult;
  }

  int _exceptionIndex = 0;
  set exceptionIndex(int value) => _exceptionIndex = value;

  @override
  Future<void> dispose() async {}
}

void main() {
  // GOOD と SCORE のアンカーつき全体結果（寸法は 1200x800）。
  // GOOD アンカーに値 "2"（数字あり）を含め、プライマリ spec で有効候補が
  // 検出される（フォールバック spec は呼ばれない）。
  final pageResult = OcrPageResult(
    elements: [
      el('GOOD', 0.5188, 0.6922),
      el('2', 0.62, 0.68),
      el('SCORE', 0.5783, 0.4763),
      el('98108', 0.72, 0.48),
    ],
    fullText: 'GOOD 2 SCORE 98108',
    imageWidth: 1200,
    imageHeight: 800,
  );

  group('RegionOcrRunner（fake engine で呼び出し記録を検証する TDD）', () {
    test('算出された領域ごとに recognizeRegion を 1 回ずつ呼ぶ（px・script 指定）', () async {
      final engine = _RecordingRegionEngine(regionResult: pageResult);
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.good, RegionTarget.songTitle},
      );

      // pageResult に GOOD の値 "2"（数字あり）が含まれるため、プライマリ spec
      // で有効候補が検出され、フォールバック spec は呼ばれない。
      // GOOD（通常、scale 3.0）＋ songTitle（scale 1.0）= 合計 2 回。
      expect(engine.calls, hasLength(2));
      final goodCall = engine.calls[0];
      // GOOD 領域（通常）: 正規化 [0.5388, 0.7488] x [0.6622, 0.7222] → px
      // (left floor 646, right ceil 899, top floor 529, bottom ceil 578)
      expect(goodCall.region.left, 646);
      expect(goodCall.region.right, 899);
      expect(goodCall.region.top, 529);
      expect(goodCall.region.bottom, 578);
      expect(goodCall.script, OcrScript.latin);
      expect(goodCall.pixelScale, 3.0);
      final titleCall = engine.calls.last;
      expect(titleCall.region, const Rect.fromLTRB(0, 128, 1200, 240));
      expect(titleCall.script, OcrScript.japanese);
      expect(titleCall.pixelScale, 1.0);
      expect(result.results.keys, {RegionTarget.good, RegionTarget.songTitle});
      expect(result.failures, isEmpty);
    });

    test('プライマリ spec が 0 候補の時だけフォールバック spec を実行する', () async {
      // regionResult の GOOD 値 "2" は数字ありだが、fake engine を空要素
      // に差し替えてプライマリ spec が 0 候補となるケースをシミュレート。
      final emptyResult = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _RecordingRegionEngine(regionResult: emptyResult);
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.good},
      );

      // GOOD はプライマリ spec（scale 3.0）→ 0 候補 → フォールバック spec（scale 2.0）の
      // 合計 2 回呼ばれる。どちらも空要素なので chosenResult は null（results に GOOD は入らない）。
      expect(engine.calls, hasLength(2));
      expect(engine.calls[0].pixelScale, 3.0);
      expect(engine.calls[1].pixelScale, 2.0);
      expect(engine.calls[1].region.bottom, 602); // 底辺拡張 spec
      expect(result.results.keys, isEmpty);
      // 例外は無い。ST-5 補完（観測性 C）により「spec 実行済み・候補ゼロ」が
      // failures に記録されるようになった（WHY: spec 未実行と区別する観測性）。
      // GOOD の 2 spec 実行を反映し、キーは no_candidates 1 件のみ。
      expect(result.failures.keys, hasLength(1));
      expect(result.failures['good_no_candidates'], isNotNull);
    });

    test('songTitle はプライマリ空要素時にフォールバック spec で再 OCR する', () async {
      // WHY: 実測で scale 1.0 固定バンド [0.16, 0.30] は ML Kit の揺らぎで
      // 曲名要素が取れない run があり（probe 実証・0 候補）、拡大 2.0 ×
      // 広帯域 [0.14, 0.34] の再 OCR で検出が回復する（g7p9b2/ay7zmq）。
      // プライマリ空→フォールバック採用の呼び出し順を検証する。
      final emptyResult = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final titleResult = OcrPageResult(
        elements: [el('Homesick Pt.2&3', 0.5, 0.22, hNorm: 0.03)],
        fullText: 'Homesick Pt.2&3',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _RecordingRegionEngine(
        regionResults: [emptyResult, titleResult],
      );
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      // 1 回目 = プライマリ固定バンド [0.16, 0.30] → px (0, 128, 1200, 240)・scale 1.0。
      // 2 回目 = フォールバック広帯域 [0.14, 0.34] → px (0, 112, 1200, 272)・scale 2.0。
      expect(engine.calls, hasLength(2));
      expect(engine.calls[0].region, const Rect.fromLTRB(0, 128, 1200, 240));
      expect(engine.calls[0].pixelScale, 1.0);
      expect(engine.calls[1].region, const Rect.fromLTRB(0, 112, 1200, 272));
      expect(engine.calls[1].script, OcrScript.japanese);
      expect(engine.calls[1].pixelScale, 2.0);
      // フォールバック結果が採用される（songTitle は数値有効性チェック外）。
      expect(result.results.keys, {RegionTarget.songTitle});
      expect(
        result.results[RegionTarget.songTitle]!.elements.single.text,
        'Homesick Pt.2&3',
      );
    });

    test('縦スクショでは portrait バンドで OCR し横バンドを呼ばない', () async {
      // WHY: 縦スクショ実測（scr001-009 前処理後 1071x2316・h > w 9/9・
      // probe で確認）では曲名行は cy 0.441-0.442 にあり、横画像バンド
      // [0.16, 0.30] は帯内 0 要素の捨て打ちになる。portrait バンド
      // [0.40, 0.47] × 2316 = px y [926, 1089]
      //（top 0.40 * 2316 = 926.4 → floor / bottom 0.47 * 2316 = 1088.52 → ceil）。
      final portraitPage = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1071,
        imageHeight: 2316,
      );
      final engine = _RecordingRegionEngine(
        regionResult: OcrPageResult(
          elements: [el('Sorrows', 0.5, 0.44, hNorm: 0.015)],
          fullText: 'Sorrows',
          imageWidth: 1071,
          imageHeight: 120,
        ),
      );
      final runner = RegionOcrRunner(engine: engine);
      final result = await runner.run(
        portraitPage,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      expect(engine.calls, hasLength(1));
      expect(
        engine.calls.single.region,
        const Rect.fromLTRB(0, 926, 1071, 1089),
      );
      expect(engine.calls.single.script, OcrScript.japanese);
      expect(engine.calls.single.pixelScale, 1.0);
      expect(
        result.results[RegionTarget.songTitle]!.elements.single.text,
        'Sorrows',
      );
    });

    test('全 spec 不成立の target は failures に記録される（spec 未実行と区別）', () async {
      // WHY: 縦スクショ 9/9 で songTitle が results から単に欠落し、
      // 「spec は走ったが候補ゼロ」が観測できなかった（QA-Docs レポート
      // §6-C）。spec が 1 本以上実行され、全て有効候補なしで終わった
      // target を failures に記録する。アンカー未検出で spec 0 本の
      // 数値系 target は正常系の未検出なので無記録のまま（境界）。
      final engine = _RecordingRegionEngine();
      final runner = RegionOcrRunner(engine: engine);
      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      // pageResult（1200x800・GOOD/SCORE アンカー）では songTitle の
      // プライマリ + フォールバックが実行されるが fake 応答は 0 要素。
      expect(result.results.containsKey(RegionTarget.songTitle), isFalse);
      expect(
        result.failures['songTitle_no_candidates'],
        isNotNull,
        reason: 'songTitle の「spec 実行済み・候補ゼロ」が failures に記録されること',
      );
    });

    test('specs に算出根拠（reason）が入る', () async {
      final engine = _RecordingRegionEngine();
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.good},
      );

      // GOOD は通常 spec（column window）＋ フォールバック spec（fallback）の 2 つ。
      expect(result.specs, hasLength(2));
      expect(
        result.specs.any((s) => s.reason.contains('column window')),
        isTrue,
      );
      expect(result.specs.any((s) => s.reason.contains('fallback')), isTrue);
      // フォールバック spec は isFallback=true。
      var hasFallback = false;
      for (final s in result.specs) {
        if (s.isFallback) {
          hasFallback = true;
        }
      }
      expect(
        hasFallback,
        isTrue,
        reason: 'フォールバック spec (isFallback=true) が含まれていること',
      );
      expect(result.specs.where((s) => s.isFallback).single.pixelScale, 2.0);
    });

    test('1 領域の失敗で残りを止めず、failures に記録する', () async {
      // buildSpecs は RegionTarget.values の順に算出するため、呼び出し順は
      // score → good（通常、scale 3.0）+ good（底辺拡張、scale 2.0）。
      // 2 回目の呼び出し（good 通常 spec）だけ失敗させる。
      final engine = _RecordingRegionEngine(
        exceptionTarget: RegionTarget.good,
        regionResult: pageResult,
      )..exceptionIndex = 1;
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.good, RegionTarget.score},
      );

      // 呼び出し順: score(scale 3.0) → good(通常、scale 3.0) → good(底辺拡張、scale 2.0)
      expect(engine.calls, hasLength(3));
      // score は成功、good 通常は失敗、good 底辺拡張は成功（採用される）
      expect(result.results.keys, {RegionTarget.good, RegionTarget.score});
      expect(result.failures.keys, {'good_3.0'});
      expect(result.failures['good_3.0'], contains('region failure'));
    });

    test('songTitle は fallback 3 本構成（広帯 + 狭帯 A/B scale 3.0）を固定', () async {
      // WHY 狭帯 scale 3.0 再 OCR（docs/st5_f2_f_narrowband_scale3_design_
      // confirmation_2026-11-22.md・docs コミット a2037df・リード承認済み）:
      // r5 実測で 5p1lg4/23bjim〔GT=Harmonia〕・yb5h8w〔GT=アイスクリーム
      // マジック〕は曲名バナー付き新 UI でグラデ stylized 文字（低コントラ
      // スト）のために primary/fallback1 で要素ゼロ（検出段階失敗・曲名は
      // 帯内に存在）。文字高実測 Harmonia ≈19px は ML Kit 検出下限相当 →
      // 狭帯 × scale 3 で ≈57px に拡大して検出回復を狙う。横 path の
      // fallback 3 本（順序固定）と幾何をここで固定する。
      final engine = _RecordingRegionEngine();
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      final songTitleSpecs = result.specs
          .where((s) => s.target == RegionTarget.songTitle)
          .toList();
      expect(songTitleSpecs, hasLength(4));
      // WHY 正規化座標で期待する（result.specs の region は正規化のまま・
      // px への変換は runner が engine 呼び出し時に toPixelRect で行う）:
      // red コミット 610ea87 で一旦 px 期待を書いたが green 検証時に
      // 正規化座標が正しい契約と判明し修正した。px 契約はテスト②③の
      // engine.calls assertions（(0,192,1200,232)/(0,152,1200,232)・
      // floor/ceil 込み）が担当する。
      // primary（等倍固定帯）。
      expect(songTitleSpecs[0].region, const Rect.fromLTRB(0, 0.16, 1, 0.30));
      expect(songTitleSpecs[0].pixelScale, 1.0);
      expect(songTitleSpecs[0].isFallback, isFalse);
      expect(songTitleSpecs[0].script, OcrScript.japanese);
      // fallback1（広帯 2 倍）。
      expect(songTitleSpecs[1].region, const Rect.fromLTRB(0, 0.14, 1, 0.34));
      expect(songTitleSpecs[1].pixelScale, 2.0);
      expect(songTitleSpecs[1].isFallback, isTrue);
      // 狭帯 A（下段狙い）: 23bjim/5p1lg4 下段曲名（実測 cy 0.2468-0.2861）
      // を完全に含み・上段ジャンル（0.2271 以下）と判定欄バー（0.3042+）
      // を排除する [0.24, 0.29]。
      expect(songTitleSpecs[2].region, const Rect.fromLTRB(0, 0.24, 1, 0.29));
      expect(songTitleSpecs[2].pixelScale, 3.0);
      expect(songTitleSpecs[2].isFallback, isTrue);
      expect(songTitleSpecs[2].script, OcrScript.japanese);
      // 狭帯 B（曲名行広め）: yb5h8w 曲名（実測 cy 0.2193-0.2755）を含み・
      // 装飾バー 2 本（0.1697-0.1828 / 0.3042-0.3133）を排除する [0.19, 0.29]。
      expect(songTitleSpecs[3].region, const Rect.fromLTRB(0, 0.19, 1, 0.29));
      expect(songTitleSpecs[3].pixelScale, 3.0);
      expect(songTitleSpecs[3].isFallback, isTrue);
      expect(songTitleSpecs[3].script, OcrScript.japanese);
    });

    test('songTitle は primary と fallback1 が 0 候補のとき狭帯 A で再 OCR する', () async {
      // WHY: 検出不能キー（23bjim/5p1lg4・下段曲名実測 cy 0.2468-0.2861）
      // は primary + fallback1 の両方で要素ゼロ → 狭帯 A [0.24, 0.29]
      // scale 3.0 で下段曲名のみを再 OCR。A で有効候補が取れたら B は呼ばない。
      final emptyResult = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final titleResult = OcrPageResult(
        elements: [el('Harmonia', 0.5, 0.27, hNorm: 0.03)],
        fullText: 'Harmonia',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _RecordingRegionEngine(
        regionResults: [emptyResult, emptyResult, titleResult],
      );
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      expect(engine.calls, hasLength(3));
      expect(engine.calls[0].region, const Rect.fromLTRB(0, 128, 1200, 240));
      expect(engine.calls[0].pixelScale, 1.0);
      expect(engine.calls[1].region, const Rect.fromLTRB(0, 112, 1200, 272));
      expect(engine.calls[1].pixelScale, 2.0);
      // 3 回目 = 狭帯 A [0.24, 0.29] → px (0, 192, 1200, 232)・scale 3.0。
      expect(engine.calls[2].region, const Rect.fromLTRB(0, 192, 1200, 232));
      expect(engine.calls[2].script, OcrScript.japanese);
      expect(engine.calls[2].pixelScale, 3.0);
      // 狭帯 A の結果が採用される（songTitle は数値有効性チェック外）。
      expect(result.results.keys, {RegionTarget.songTitle});
      expect(
        result.results[RegionTarget.songTitle]!.elements.single.text,
        'Harmonia',
      );
    });

    test('狭帯 spec は engine 呼び出しに contrastRetry フラグを渡す', () async {
      // WHY（docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22
      // .md §3・docs コミット 18b2111・リード承認済み）: 前処理（大津二値化）
      // は engine 内部で 0 要素時に発火するため、runner は spec.contrastRetry
      // を engine へ確実に伝播する必要がある。red 段階では runner がまだ渡さ
      // ないため狭帯呼び出しの contrastRetry は false で red になる。
      // primary/fallback1（広帯）は常に false（r6 検出済み 28 キーの入力
      // 経路を 1 バイトも変更しない＝構造的非回帰のガード）。
      final emptyResult = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final titleResult = OcrPageResult(
        elements: [el('Harmonia', 0.5, 0.27, hNorm: 0.03)],
        fullText: 'Harmonia',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _RecordingRegionEngine(
        regionResults: [emptyResult, emptyResult, titleResult],
      );
      final runner = RegionOcrRunner(engine: engine);

      await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      expect(engine.calls, hasLength(3));
      expect(engine.calls[0].contrastRetry, isFalse);
      expect(engine.calls[1].contrastRetry, isFalse);
      // 狭帯 A の呼び出しのみフラグが立つ（red: runner 未実装で false）。
      expect(engine.calls[2].contrastRetry, isTrue);
    });

    test('songTitle は狭帯 A も 0 候補のとき狭帯 B で再 OCR する', () async {
      // WHY: yb5h8w は曲名（実測 cy 0.2193-0.2755）の上半分が A [0.24, 0.29]
      // で切れて 0 候補になる想定 → 狭帯 B [0.19, 0.29] scale 3.0 で全文字
      // を再 OCR。
      final emptyResult = OcrPageResult(
        elements: const [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final titleResult = OcrPageResult(
        elements: [el('アイスクリームマジック', 0.5, 0.25, hNorm: 0.04)],
        fullText: 'アイスクリームマジック',
        imageWidth: 1200,
        imageHeight: 800,
      );
      final engine = _RecordingRegionEngine(
        regionResults: [emptyResult, emptyResult, emptyResult, titleResult],
      );
      final runner = RegionOcrRunner(engine: engine);

      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      expect(engine.calls, hasLength(4));
      // 4 回目 = 狭帯 B [0.19, 0.29] → px (0, 152, 1200, 232)・scale 3.0。
      expect(engine.calls[3].region, const Rect.fromLTRB(0, 152, 1200, 232));
      expect(engine.calls[3].script, OcrScript.japanese);
      expect(engine.calls[3].pixelScale, 3.0);
      expect(
        result.results[RegionTarget.songTitle]!.elements.single.text,
        'アイスクリームマジック',
      );
    });

    test('songTitle 全 4 spec 不成立は failures に 4 spec 実行として記録する', () async {
      // WHY: no_candidates の観測性（ST-5 補完 C）を維持しつつ spec 数の
      // 増加（2→4）を反映する。文言「all N spec(s)...」の N が 4 になる
      // （既存テストは文言をピンしていないため本テストが文言固定を担う）。
      final engine = _RecordingRegionEngine();
      final runner = RegionOcrRunner(engine: engine);
      final result = await runner.run(
        pageResult,
        createTestImageBytes(),
        targets: {RegionTarget.songTitle},
      );

      expect(result.results.containsKey(RegionTarget.songTitle), isFalse);
      expect(
        result.failures['songTitle_no_candidates'],
        contains('all 4 spec(s) ran but returned no valid candidates'),
      );
    });
  });
}
