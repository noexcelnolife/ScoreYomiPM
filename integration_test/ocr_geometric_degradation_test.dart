// 幾何劣化耐性測定ハーネス（幾何補正 Wave-1 計測・リード実装 2026-11-23）。
//
// docs/geometric_rectification_design_2026-11-23.md の Phase 0。
// testimage/AC-HC-photo/ の実機写真のうち基線（run-4）で全 6 数値フィールドの
// 抽出に成功した代表 6 枚をベースに、手持ち撮影で起きる (1) 傾き（ロール回転）
// と (2) 解像度差（リサイズ）を package:image で合成した劣化画像をエミュレータ
// 上で生成し、フルパイプライン（layoutHint=acV1 = カメラ経路相当）で処理して
// 角度・スケールごとの抽出成功率を実測する。
//
// WHY 計測先行: 幾何補正（回転・スケール耐性）の実装判断は「既存パイプラインが
// どの角度・スケールまで耐えるか」の実測曲線に基づいてスコープを決める
// （データ優先方針・ユーザー裁定「幾何補正を進めてください」2026-11-23）。
// 特徴点マッチング等の実装はこの計測結果の後（Phase 1・設計メモ §3）。
//
// 実行手順:
//   powershell -ExecutionPolicy Bypass -File scripts\push_ac_test_images.ps1
//   flutter test integration_test/ocr_geometric_degradation_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';

// ignore_for_file: avoid_print
const String _deviceImageDir = '/data/local/tmp/poc_ac';

/// 幾何耐性測定のベース画像（6 枚）。
///
/// WHY この 6 枚: run-4 基線（tool/_run4_flutter.log・2026-11-23）で
/// score/cool/great/good/bad/maxCombo の全 6 フィールド抽出に成功した画像の
/// うち、スコア帯（9767〜99172）と COOL 数（104〜1651）が分散する構図多様な
/// 6 枚。基線で抽出不能な画像（HV8q 等）は床効果により幾何劣化の差分計測に
/// 使えないため除外。
const List<String> _baseImageNames = <String>[
  'G_j8SovaUAAeeHL.jpg',
  'HAtmq0LaMAA3fQw.jpg',
  'HFCNzIBa4AAJQac.jpg',
  'HFNsUYSbIAA9gmx.jpg',
  'HW7cJQabkAETBKb.jpg',
  'HXpqyrfakAAbo3G.jpg',
];

/// 測定する幾何条件（角度スイープ × スケールスイープ）。
///
/// WHY この範囲: 角度は手持ち撮影で現実的な ±15° まで。スケールは
/// 2048x1536 基準の相対倍率（2.0 = 12MP 級・1.5 = 8MP 級・0.5 = 低解像度
/// 保存相当）。角度とスケールの同時合成は Phase 1 のスコープ確定後。
const List<({int angle, double scale})> _combos = <({int angle, double scale})>[
  (angle: 0, scale: 1.0),
  (angle: 3, scale: 1.0),
  (angle: -3, scale: 1.0),
  (angle: 6, scale: 1.0),
  (angle: -6, scale: 1.0),
  (angle: 10, scale: 1.0),
  (angle: -10, scale: 1.0),
  (angle: 15, scale: 1.0),
  (angle: -15, scale: 1.0),
  (angle: 0, scale: 1.5),
  (angle: 0, scale: 2.0),
  (angle: 0, scale: 0.5),
];

/// ベース画像に幾何劣化（拡縮 → 回転）を合成する。
///
/// WHY 先に拡縮: 実写像では解像度（撮像素子出力）と傾き（手ブレ）が独立に
/// 乗る。順序依存を避けるため一律「拡縮 → 回転」で合成する。補間は実写真の
/// 滑らかさに合わせ cubic（既定 nearest のギザ成分が OCR に影響するのを防ぐ）。
img.Image _degrade(
  img.Image base, {
  required int angle,
  required double scale,
}) {
  img.Image degraded = base;
  if (scale != 1.0) {
    degraded = img.copyResize(
      degraded,
      width: math.max(1, (degraded.width * scale).round()),
      interpolation: img.Interpolation.cubic,
    );
  }
  if (angle != 0) {
    degraded = img.copyRotate(
      degraded,
      angle: angle,
      interpolation: img.Interpolation.cubic,
    );
  }
  return degraded;
}

/// 単一ランの抽出結果を記録用 map へ整形する。
Map<String, Object?> _record({
  required String name,
  required ({int angle, double scale}) combo,
  required int elapsedMs,
  required Map<String, String?> fields,
}) {
  return <String, Object?>{
    'file': name,
    'angle': combo.angle,
    'scale': combo.scale,
    'elapsedMs': elapsedMs,
    ...fields,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  test(
    '幾何劣化耐性の実測（角度スイープ・スケールスイープ）',
    // WHY 30 分: 72 ラン × (劣化生成 + フルパイプライン ≒ 6.3s/ラン) ≒ 15 分強
    // が必要時間のため（既定 30 秒では 1 画像分も走らない）。
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      final engine = MlKitOcrEngine();
      final pipeline = OcrPipeline(engine: engine);
      final tempDir = await Directory.systemTemp.createTemp('geomdegrade');
      final records = <Map<String, Object?>>[];
      try {
        for (final name in _baseImageNames) {
          final baseFile = File('$_deviceImageDir/$name');
          // WHY 事前存在確認: push 忘れ時に 72 ラン全てを失敗で消費しないため。
          expect(
            baseFile.existsSync(),
            isTrue,
            reason:
                '$_deviceImageDir/$name が無い。push_ac_test_images.ps1 を先に実行すること',
          );
          final base = img.decodeImage(baseFile.readAsBytesSync());
          if (base == null) {
            fail('$name のデコードに失敗');
          }
          for (final combo in _combos) {
            final degraded = _degrade(
              base,
              angle: combo.angle,
              scale: combo.scale,
            );
            final tempFile = File(
              '${tempDir.path}/deg_a${combo.angle}_s${combo.scale}_$name',
            );
            await tempFile.writeAsBytes(img.encodeJpg(degraded, quality: 90));

            final watch = Stopwatch()..start();
            final context = await pipeline.run(
              tempFile,
              layoutHint: InputLayoutHint.acV1,
            );
            watch.stop();
            await tempFile.delete();

            final extraction = context.extractionResult;
            String? describe(NumericFieldKind kind) =>
                extraction?.field(kind)?.value.toString();
            final record = _record(
              name: name,
              combo: combo,
              elapsedMs: watch.elapsedMilliseconds,
              fields: <String, String?>{
                'score': describe(NumericFieldKind.score),
                'cool': describe(NumericFieldKind.cool),
                'great': describe(NumericFieldKind.great),
                'good': describe(NumericFieldKind.good),
                'bad': describe(NumericFieldKind.bad),
                'maxCombo': describe(NumericFieldKind.maxCombo),
              },
            );
            records.add(record);
            print('--- geometric run ---');
            print(jsonEncode(record));
          }
        }
      } finally {
        await tempDir.delete(recursive: true);
        await engine.dispose();
      }

      // 組み合わせ別サマリ: 各フィールドの抽出成功数（6 枚中）。
      print('--- geometric summary ---');
      for (final combo in _combos) {
        final runs = records
            .where(
              (r) => r['angle'] == combo.angle && r['scale'] == combo.scale,
            )
            .toList();
        int count(String field) =>
            runs.where((r) => (r[field] as String?) != null).length;
        final summary = <String, Object?>{
          'angle': combo.angle,
          'scale': combo.scale,
          'score': count('score'),
          'cool': count('cool'),
          'great': count('great'),
          'good': count('good'),
          'bad': count('bad'),
          'maxCombo': count('maxCombo'),
          'avgElapsedMs':
              (runs.map((r) => r['elapsedMs'] as int).reduce((a, b) => a + b) /
                      runs.length)
                  .round(),
        };
        print(jsonEncode(summary));
      }
      print('--- geometric end ---');
    },
  );
}
