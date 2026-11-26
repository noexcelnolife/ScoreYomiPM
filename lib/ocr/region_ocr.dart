/// クロップ再 OCR（Wave 2）の実行。
///
/// [RegionSpecBuilder] が算出した領域を engine の [OcrEngine.recognizeRegion]
/// に渡し、対象ごとの認識結果を収集する。マージ（フィールドへの反映）は
/// FieldExtractor.extractWithRegions が担当する。
library;

import 'dart:io';

import '../models/ocr_models.dart';
import 'field_extractor.dart';
import 'ocr_engine.dart';
import 'region_spec.dart';
import 'ui_anchor.dart';

/// クロップ再 OCR の実行結果。
///
/// [results] は成功した対象のみ（値はクロップ座標系）。
/// [failures] は失敗した対象とその理由（計測レポートの根拠。マージでは
/// 未抽出扱いになる）。
class RegionOcrResult {
  RegionOcrResult({
    required Map<RegionTarget, OcrPageResult> results,
    required Map<String, String> failures,
    required this.specs,
  }) : results = Map.unmodifiable(results),
       failures = Map.unmodifiable(failures);

  /// 実行対象の領域算出根拠（reason を含む）。
  final List<RegionSpec> specs;

  final Map<RegionTarget, OcrPageResult> results;
  final Map<String, String> failures;
}

/// クロップ再 OCR を実行する。
class RegionOcrRunner {
  const RegionOcrRunner({required this.engine});

  final OcrEngine engine;

  /// [pageResult]（全体 OCR 結果・寸法必須）を基にクロップ再 OCR を実行する。
  ///
  /// [anchors] は ST-3.5 の UI アンカー検出結果（省略/null = 現行動作）。
  /// 領域算出（RegionSpecBuilder）だけに影響し、認識実行の契約は変わらない。
  ///
  /// WHY: 1 領域の失敗で残りを止めない。失敗は [RegionOcrResult.failures]
  /// に記録して計測レポートの根拠にする（マージでは未抽出扱いになるだけ）。
  Future<RegionOcrResult> run(
    OcrPageResult pageResult,
    File imageFile, {
    Set<RegionTarget>? targets,
    AnchorRegistration? anchors,
    LayoutKind layoutKind = LayoutKind.hcV1,
  }) async {
    final specs = const RegionSpecBuilder().buildSpecs(
      pageResult,
      targets: targets,
      anchors: anchors,
      layoutKind: layoutKind,
    );
    // 同一ターゲットに複数 spec（GOOD/BAD のプライマリ＋フォールバック
    // 等）がある場合、プライマリ spec（isFallback=false）を先に実行し、
    // 有効な数値候補（テキストに 1 文字以上の半角数字を含む要素）がゼロの
    // 時だけフォールバック spec（isFallback=true）を実行する（WHY:
    // GOOD/BAD の bottom 拡張 spec は隣行の値帯を含むため、常時実行すると
    // element 数優先で隣行値を桁数優先誤採用する）。
    final results = <RegionTarget, OcrPageResult>{};
    final failures = <String, String>{};

    // ターゲットごとに spec をグループ化し、プライマリ / フォールバックに分離。
    final specsByTarget = <RegionTarget, List<RegionSpec>>{};
    for (final spec in specs) {
      specsByTarget.putIfAbsent(spec.target, () => <RegionSpec>[]).add(spec);
    }

    for (final entry in specsByTarget.entries) {
      final target = entry.key;
      final targetSpecs = entry.value;
      final primarySpecs = targetSpecs.where((s) => !s.isFallback).toList();
      final fallbackSpecs = targetSpecs.where((s) => s.isFallback).toList();

      OcrPageResult? chosenResult;

      // プライマリ spec を順に実行。
      for (final spec in primarySpecs) {
        final pixelRect = spec.toPixelRect(
          pageResult.imageWidth!,
          pageResult.imageHeight!,
        );
        try {
          final page = await engine.recognizeRegion(
            imageFile,
            pixelRect,
            script: spec.script,
            pixelScale: spec.pixelScale,
            // WHY: 0 要素時の二値化再 OCR 判定は engine 側が spec 意図を
            // 知る唯一の経路。spec → engine への素通しのみで runner は
            // 前処理の有無に関与しない（18b2111 §2）。
            contrastRetry: spec.contrastRetry,
          );
          if (_hasValidNumericCandidates(page, target)) {
            chosenResult = page;
            break; // プライマリで有効候補あり → 採用し、フォールバックは実行しない
          }
          // プライマリが 0 候補 → 続けてフォールバックを試す（下のブロック）。
        } on OcrEngineException catch (e) {
          failures['${target.name}_${spec.pixelScale}'] = e.message;
        }
      }

      // プライマリで有効候補がゼロならフォールバック spec を実行。
      if (chosenResult == null && fallbackSpecs.isNotEmpty) {
        for (final spec in fallbackSpecs) {
          final pixelRect = spec.toPixelRect(
            pageResult.imageWidth!,
            pageResult.imageHeight!,
          );
          try {
            final page = await engine.recognizeRegion(
              imageFile,
              pixelRect,
              script: spec.script,
              pixelScale: spec.pixelScale,
              // WHY: プライマリ呼び出し箇所と同一の素通し（18b2111 §2）。
              contrastRetry: spec.contrastRetry,
            );
            if (_hasValidNumericCandidates(page, target)) {
              chosenResult = page;
              break;
            }
          } on OcrEngineException catch (e) {
            failures['${target.name}_${spec.pixelScale}'] = e.message;
          }
        }
      }

      if (chosenResult != null) {
        results[target] = chosenResult;
      } else if (targetSpecs.isNotEmpty) {
        // spec が 1 本以上実行され、全て有効候補ゼロだったことを記録する。
        // WHY: 「spec 未実行」との区別が観測性の要。縦スクショ 9/9 の
        // songTitle 未検出は results から単に欠落して診断不能だった
        //（QA-Docs レポート ad23363 §6-C・リード承認）。アンカー未検出で
        // spec 0 本の target は正常系の未検出なので記録しない（境界）。
        // キー形式は既存の '${target.name}_...' 語彙に合わせる。
        failures['${target.name}_no_candidates'] =
            'all ${targetSpecs.length} spec(s) ran but returned no valid candidates';
      }
    }
    return RegionOcrResult(specs: specs, results: results, failures: failures);
  }

  /// ページ結果に有効な数値候補（テキストに 1 文字以上の半角数字を含む
  /// 要素が 1 つ以上）があるかを返す。
  /// [target] が [RegionTarget.songTitle] の場合は数値チェックをスキップし、
  /// 任意のテキスト結果を有効とする（ST-5 曲名バンドは日本語テキスト）。
  bool _hasValidNumericCandidates(OcrPageResult page, RegionTarget target) {
    if (target == RegionTarget.songTitle) {
      return page.elements.isNotEmpty;
    }
    return page.elements.any((e) => e.text.contains(RegExp(r'[0-9]')));
  }
}
