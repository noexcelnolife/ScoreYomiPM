// ST-1.5 ロール補正の回復効果測定（幾何補正 Phase 1・01a207fc）。
//
// docs/geometric_rectification_design_2026-11-23.md §3 の Phase 1 受入測定。
// Phase 0（ocr_geometric_degradation_test.dart）で実測した劣化条件のうち
// ロール ±6°/±10°（抽出崩壊域）に対し、既定 RollCorrector を組み込んだ
// フルパイプライン（layoutHint=acV1 = カメラ経路相当）で抽出が回復すること
// をエミュレータ上で実測・検証する。
//
// WHY 受入基準をテストで固定: ±6°/±10° の劣化画像で score/maxCombo が
// 6 枚中 5 枚以上（≥5/6）抽出できなければ Phase 1 は完了としない（01a207fc
// の受入条件）。無傾き（0°）は補正が作動しない現行動作の維持確認を兼ねる。
//
// 実行手順:
//   powershell -ExecutionPolicy Bypass -File scripts\push_ac_test_images.ps1
//   flutter test integration_test/ocr_roll_correction_recovery_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/mlkit_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';
import 'package:scoreyomipm/ocr/roll_corrector.dart';

// ignore_for_file: avoid_print
const String _deviceImageDir = '/data/local/tmp/poc_ac';

/// 回復測定のベース画像（6 枚）。
///
/// WHY この 6 枚: Phase 0 劣化測定（ocr_geometric_degradation_test.dart）と
/// 同一の代表 6 枚（run-4 基線で全 6 フィールド抽出成功・スコア帯と COOL 数
/// が分散する構図多様な組）。基線を共有することで劣化曲線（Phase 0）と回復
/// 曲線（Phase 1）を直接比較できる。
const List<String> _baseImageNames = <String>[
  'G_j8SovaUAAeeHL.jpg',
  'HAtmq0LaMAA3fQw.jpg',
  'HFCNzIBa4AAJQac.jpg',
  'HFNsUYSbIAA9gmx.jpg',
  'HW7cJQabkAETBKb.jpg',
  'HXpqyrfakAAbo3G.jpg',
];

/// 測定するロール角度（0° = 補正不作動の現行維持確認、±6/±10 = 劣化実測域）。
///
/// WHY この角度: Phase 0 実測で ±3° が score 3/6・±6° 以上が崩壊（1-4/6）
/// だったため、回復測定は崩壊域の代表として ±6°/±10° を使う（±15° は
/// 撮り直し対応の運用枠としスコープ外）。
const List<int> _angles = <int>[0, 6, -6, 10, -10];

/// ベース画像にロール劣化を合成する。
///
/// WHY cubic: 実カメラの連続回転に合わせる（最近傍は階段状エッジになり
/// 実写像と乖離する。Phase 0 ハーネスと同じ設定）。
img.Image _tilt(img.Image base, {required int angle}) {
  if (angle == 0) {
    return base;
  }
  return img.copyRotate(
    base,
    angle: angle,
    interpolation: img.Interpolation.cubic,
  );
}

/// 単一ランの抽出結果を記録用 map へ整形する。
Map<String, Object?> _record({
  required String name,
  required int angle,
  required String? estimatedAngle,
  required int elapsedMs,
  required Map<String, String?> fields,
}) {
  return <String, Object?>{
    'file': name,
    'angle': angle,
    // WHY null-aware 値: 推定不能（null）のときのみエントリ自体を省く。
    'estimatedAngleDeg': ?estimatedAngle,
    'elapsedMs': elapsedMs,
    ...fields,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  test(
    'ST-1.5 ロール補正の回復実測（±6°/±10° で score/maxCombo ≥5/6）',
    // WHY 30 分: 30 ラン ×（補正推定 + 正立化 + フルパイプライン ≒ 8s/ラン）
    // ≒ 4-5 分 + 環境差の余裕。既定 30 秒では 1 ランも完走しない。
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      final engine = MlKitOcrEngine();
      // WHY DI しない: 本番相当（既定生成の RollCorrector が使われる経路）を
      // 実測するため。a0d6a03 の教訓（DI-null 経路がテストで見えない）への
      // 対応でもある。
      final pipeline = OcrPipeline(engine: engine);
      final corrector = RollCorrector();
      final tempDir = await Directory.systemTemp.createTemp('rollrecovery');
      final records = <Map<String, Object?>>[];
      try {
        for (final name in _baseImageNames) {
          final baseFile = File('$_deviceImageDir/$name');
          // WHY 事前存在確認: push 忘れ時に 30 ラン全てを失敗で消費しないため。
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
          for (final angle in _angles) {
            final tilted = _tilt(base, angle: angle);
            final tempFile = File('${tempDir.path}/roll_a${angle}_$name');
            await tempFile.writeAsBytes(img.encodeJpg(tilted, quality: 90));

            // WHY 推定値を別計測: パイプライン内部の補正角は観測できないため、
            // 同一画像への RollCorrector 直叩きで推定値を記録する（設計 §3 の
            // 実装記録用。判断には使わない）。
            final estimate = corrector.estimate(tilted);
            final estimatedAngle = estimate?.angleDeg.toStringAsFixed(3);

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
              angle: angle,
              estimatedAngle: estimatedAngle,
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
            print('--- roll recovery run ---');
            print(jsonEncode(record));
          }
        }
      } finally {
        await tempDir.delete(recursive: true);
        await engine.dispose();
      }

      // 角度別サマリ + 受入検証。
      print('--- roll recovery summary ---');
      final summaryByAngle = <int, Map<String, Object?>>{};
      for (final angle in _angles) {
        final runs = records.where((r) => r['angle'] == angle).toList();
        int count(String field) =>
            runs.where((r) => (r[field] as String?) != null).length;
        final summary = <String, Object?>{
          'angle': angle,
          'runs': runs.length,
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
        summaryByAngle[angle] = summary;
        print(jsonEncode(summary));
      }
      print('--- roll recovery end ---');

      // 受入検証（01a207fc）。全 6 数値フィールドではなく score と maxCombo
      // （譜面成績の核となる 2 項目）で判定する。
      //
      // WHY ≥5/6: Phase 0 の基線（0°）が 6/6 であることから、回復後も基線の
      // 8 割以上を必達とする。1 枚は JPEG 再符号化と補正角の丸め誤差の余裕分。
      for (final angle in _angles) {
        final summary = summaryByAngle[angle]!;
        final label = angle == 0 ? '無傾き（補正不作動・現行維持）' : 'tilt=$angle（補正回復）';
        expect(
          summary['score'],
          greaterThanOrEqualTo(5),
          reason: 'score 抽出が $label で基線要件（≥5/6）を満たさない',
        );
        expect(
          summary['maxCombo'],
          greaterThanOrEqualTo(5),
          reason: 'maxCombo 抽出が $label で基線要件（≥5/6）を満たさない',
        );
      }
    },
  );
}
