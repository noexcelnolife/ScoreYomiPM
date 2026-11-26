// 台形補正（Phase 2）検討用に提供された実機写真 2 枚の現行パイプライン基線測定。
//
// WHY この測定: ユーザー提供の実機写真（vlcsnap・未補正の届いたまま）を
// 現行パイプライン（Phase 1 ロール補正込み・layoutHint=acV1 = アプリの
// リザルト写真経路相当）に通した数値抽出の現在地を記録する。台形補正の
// 要否・効果判断はこの基線と比較して行う（本テストでは受入判定しない）。
//
// 実行手順:
//   adb push <png> /data/local/tmp/poc_ac2/
//   flutter test integration_test/ocr_new_photo_check_test.dart -d emulator-5554

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
const String _deviceImageDir = '/data/local/tmp/poc_ac2';

/// 測定対象の実機写真（ユーザー提供 2026-11-23）。
const List<String> _imageNames = <String>[
  'vlcsnap-2026-11-23-20h43m47s029.png',
  'vlcsnap-2026-11-23-20h44m26s941.png',
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  test(
    '実機写真 2 枚の現行パイプライン基線測定（acV1 ヒント経路）',
    // WHY 10 分: 2 ラン ×（補正推定 + フルパイプライン ≒ 10s/ラン）+ 余裕。
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final engine = MlKitOcrEngine();
      // WHY DI しない: 本番相当（既定生成の RollCorrector が使われる経路）を
      // 実測するため。
      final pipeline = OcrPipeline(engine: engine);
      final corrector = RollCorrector();
      final records = <Map<String, Object?>>[];
      try {
        for (final name in _imageNames) {
          final file = File('$_deviceImageDir/$name');
          expect(
            file.existsSync(),
            isTrue,
            reason: '$_deviceImageDir/$name が無い。adb push を先に実行すること',
          );

          // WHY 推定値を別計測: パイプライン内部の補正角は観測できないため、
          // 同一画像への RollCorrector 直叩きで推定値を記録する（設計 §3 の
          // 実装記録用。判断には使わない）。
          final decoded = img.decodeImage(file.readAsBytesSync());
          final estimate = decoded == null ? null : corrector.estimate(decoded);

          final watch = Stopwatch()..start();
          final context = await pipeline.run(
            file,
            layoutHint: InputLayoutHint.acV1,
          );
          watch.stop();

          final extraction = context.extractionResult;
          String? describe(NumericFieldKind kind) =>
              extraction?.field(kind)?.value.toString();
          final record = <String, Object?>{
            'file': name,
            // WHY null-aware 値: 推定不能（null）のときのみエントリ自体を省く。
            'estimatedAngleDeg': ?estimate?.angleDeg.toStringAsFixed(3),
            'widthPx': decoded?.width,
            'heightPx': decoded?.height,
            'elapsedMs': watch.elapsedMilliseconds,
            'score': describe(NumericFieldKind.score),
            'cool': describe(NumericFieldKind.cool),
            'great': describe(NumericFieldKind.great),
            'good': describe(NumericFieldKind.good),
            'bad': describe(NumericFieldKind.bad),
            'maxCombo': describe(NumericFieldKind.maxCombo),
          };
          records.add(record);
          print('--- new photo run ---');
          print(jsonEncode(record));
        }
      } finally {
        await engine.dispose();
      }

      print('--- new photo summary ---');
      for (final record in records) {
        print(jsonEncode(record));
      }
      print('--- new photo end ---');
      // 受入判定なし: 基線記録が目的（台形補正の要否は Phase 2 設計で判断）。
    },
  );
}
