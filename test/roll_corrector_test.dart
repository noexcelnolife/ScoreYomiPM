// ST-1.5 ロール回転補正器の単体テスト（幾何補正 Phase 1・01a207fc）。
// 設計: docs/geometric_rectification_design_2026-11-23.md §3（Phase 0 実測:
// スケール耐性十分 → ロール補正のみ実装・acV1 hint 経路限定）。
//
// 角度推定方式: 勾配方位ヒストグラム（文書スキュー補正の標準手法・純 Dart・
// 0.5 秒級）。既存 NCC 機構（ui_anchor.dart）を使った角度探索は候補角度ごとに
// canonical 解像度での回転が必要で 30 秒級になるため不採用（実測で検証する）。
//
// 推定角度の契約: 「img.copyRotate(angle:) にそのまま渡して正立化できる角度」。
// copyRotate は線形合成なので、copyRotate(θ) で傾けた画像に対し copyRotate(−θ)
// で復元する。テストはこの丸め込み（round-trip）で符号規約を固定する。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scoreyomipm/ocr/roll_corrector.dart';

import 'support/image_fixture_skip.dart';

/// 横縞ストライプ画像を生成する（水平エッジが支配的な合成画像）。
img.Image _horizontalStripes({
  int width = 400,
  int height = 300,
  int period = 16,
}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final bright = (y ~/ period) % 2 == 0 ? 240 : 20;
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, bright, bright, bright, 255);
    }
  }
  return image;
}

/// 一様ランダムノイズ画像を生成する（支配的方位が無い画像）。
img.Image _noiseImage({int width = 200, int height = 150, int seed = 7}) {
  final random = math.Random(seed);
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = random.nextInt(256);
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return image;
}

img.Image _flatImage({int width = 200, int height = 150, int value = 128}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, value, value, value, 255);
    }
  }
  return image;
}

/// 実画像 6 枚（Phase 0 計測の代表・run-4 基線で全 6 フィールド抽出成功）。
final List<String> _realImagePaths = <String>[
  'testimage/AC-HC-photo/G_j8SovaUAAeeHL.jpg',
  'testimage/AC-HC-photo/HAtmq0LaMAA3fQw.jpg',
  'testimage/AC-HC-photo/HFCNzIBa4AAJQac.jpg',
  'testimage/AC-HC-photo/HFNsUYSbIAA9gmx.jpg',
  'testimage/AC-HC-photo/HW7cJQabkAETBKb.jpg',
  'testimage/AC-HC-photo/HXpqyrfakAAbo3G.jpg',
];

// 実画像 6 枚 × 5 回（無傾き + ±6°/±15°）の角度推定は 1 本で約 171 秒かかり、
// 663 件 197 秒の 87% を占める（2026-11-24 実測・12 並列で他のスイートは
// 30 秒以下）。同一ファイル内のテストは直列実行で並列化できないため、
// 既定ではスキップし、角度推定を変更したときだけ明示的に実行する。
const bool _runSlowTests = bool.fromEnvironment('RUN_SLOW_TESTS');

/// 実画像が無い環境では画像欠落を理由に skip し、あっても既定では時間を理由に skip する。
/// `flutter test --dart-define=RUN_SLOW_TESTS=true` を付けたときだけ実行される。
String? _skipRealImageAngleTest(List<String> paths) {
  final missing = skipIfImagesMissing(paths);
  if (missing != null) {
    return missing;
  }
  if (_runSlowTests) {
    return null;
  }
  return '約171秒かかるため既定で skip（--dart-define=RUN_SLOW_TESTS=true で実行）';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RollCorrector.estimate（角度推定）', () {
    test('合成ストライプ（無傾き）で推定角度がほぼ 0', () {
      final corrector = RollCorrector();
      final estimate = corrector.estimate(_horizontalStripes());
      expect(estimate, isNotNull);
      expect(estimate!.angleDeg, closeTo(0, 0.5));
    });

    test('copyRotate(+6) で傾けた合成ストライプに -6 を返し、適用で復元する', () {
      final corrector = RollCorrector();
      // WHY cubic: 最近傍回転はストライプを階段状エッジに変え（局所勾配が垂直のまま）、
      // 実カメラの連続回転と乖離する。傾き生成は必ず連続補間で行う。
      final tilted = img.copyRotate(
        _horizontalStripes(),
        angle: 6,
        interpolation: img.Interpolation.cubic,
      );
      final estimate = corrector.estimate(tilted);
      expect(estimate, isNotNull);
      // WHY closeTo(-6, 1.0): 推定精度の受け入れ基準（設計 §3・±1° 以内）。
      expect(estimate!.angleDeg, closeTo(-6, 1.0));

      // 丸め込み: 推定角度を適用すると再推定は ≈0 になる。
      final uprighted = img.copyRotate(
        tilted,
        angle: estimate.angleDeg,
        interpolation: img.Interpolation.cubic,
      );
      final reEstimate = corrector.estimate(uprighted);
      expect(reEstimate, isNotNull);
      expect(reEstimate!.angleDeg, closeTo(0, 1.0));
    });

    test('copyRotate(-15) で傾けた合成ストライプに +15 を返す', () {
      final corrector = RollCorrector();
      // WHY cubic: 最近傍回転はストライプを階段状エッジに変え（局所勾配が垂直のまま）、
      // 実カメラの連続回転と乖離する。傾き生成は必ず連続補間で行う。
      final tilted = img.copyRotate(
        _horizontalStripes(),
        angle: -15,
        interpolation: img.Interpolation.cubic,
      );
      final estimate = corrector.estimate(tilted);
      expect(estimate, isNotNull);
      expect(estimate!.angleDeg, closeTo(15, 1.5));
    });

    test('一様ランダムノイズで null（支配的方位なし・fail-safe）', () {
      final corrector = RollCorrector();
      expect(corrector.estimate(_noiseImage()), isNull);
    });

    test('無地画像で null（エッジなし・fail-safe）', () {
      final corrector = RollCorrector();
      expect(corrector.estimate(_flatImage()), isNull);
    });

    test('実画像 6 枚: 無傾きで ≈0・±6°/±15° で角度精度 ±1.5°', () {
      final corrector = RollCorrector();
      for (final path in _realImagePaths) {
        final file = File(path);
        final base = img.decodeImage(file.readAsBytesSync());
        if (base == null) {
          fail('デコード失敗: $path');
        }
        final upright = corrector.estimate(base);
        // WHY 許容 ±1.5°: 無傾き実写真の推定誤差が補正閾値 1.5° 未満なら
        // maybeUpright は null（現行経路とバイト等価）で実害ゼロ。真の受入
        // 基準は回復測定（±6°/±10° での抽出回復）。実測で最大 1.375° の個体
        // 差があるため閾値に整合させる。
        expect(upright, isNotNull, reason: '$path 無傾きで推定不能');
        expect(upright!.angleDeg, closeTo(0, 1.5), reason: '$path 無傾き');

        for (final tilt in const <int>[6, -6, 15, -15]) {
          // WHY cubic: 最近傍回転はストライプを階段状エッジに変え（局所勾配が
          // 垂直のまま）、実カメラの連続回転と乖離する。傾き生成は必ず連続
          // 補間で行う。
          final tilted = img.copyRotate(
            base,
            angle: tilt,
            interpolation: img.Interpolation.cubic,
          );
          final estimate = corrector.estimate(tilted);
          expect(estimate, isNotNull, reason: '$path tilt=$tilt で推定不能');
          // WHY 相対精度: 実画像はコンテンツ固有の傾きバイアス（実測で
          // G_j8SovaUAAeeHL が +1.375° 等）を持つため、絶対値ではなく
          // 「無傾き推定値からの変化量」で適用傾きの検出精度を検証する。
          // maybeUpright は絶対角度でヒストグラム中心化して着地するが、その
          // 着地点は OCR 許容（±3° まで実測劣化なし）内で安全。
          expect(
            estimate!.angleDeg - upright.angleDeg,
            closeTo(-tilt.toDouble(), 1.5),
            reason: '$path tilt=$tilt',
          );
        }
      }
    }, skip: _skipRealImageAngleTest(_realImagePaths));
  });

  group('RollCorrector.maybeUpright（正立化）', () {
    test('無傾きの実画像で null（補正不要・現行経路そのまま）', () async {
      final corrector = RollCorrector();
      final file = File(_realImagePaths.first);
      // WHY await なし: maybeUpright は同期シグネチャ（File? 返し）。失敗を
      // null で返す契約のため Future にしない。
      expect(corrector.maybeUpright(file), isNull);
    }, skip: skipIfImagesMissing(<String>[_realImagePaths.first]));

    test('強傾きの合成画像で正立化ファイルを返し、再推定が ≈0', () async {
      final corrector = RollCorrector();
      // WHY cubic: 最近傍回転はストライプを階段状エッジに変え（局所勾配が垂直のまま）、
      // 実カメラの連続回転と乖離する。傾き生成は必ず連続補間で行う。
      final tilted = img.copyRotate(
        _horizontalStripes(),
        angle: 10,
        interpolation: img.Interpolation.cubic,
      );
      final source = File(
        '${Directory.systemTemp.path}/roll_test_tilted_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await source.writeAsBytes(img.encodePng(tilted));
      addTearDown(() {
        if (source.existsSync()) {
          source.deleteSync();
        }
      });

      // WHY await なし: maybeUpright は同期シグネチャ（File? 返し）。
      final uprightFile = corrector.maybeUpright(source);
      expect(uprightFile, isNotNull);
      addTearDown(() {
        if (uprightFile != null && uprightFile.existsSync()) {
          uprightFile.deleteSync();
        }
      });

      // 正立化結果を再推定して ≈0（丸め込み完成）。
      final bytes = await uprightFile!.readAsBytes();
      final uprightImage = img.decodeImage(bytes);
      expect(uprightImage, isNotNull);
      final reEstimate = corrector.estimate(uprightImage!);
      expect(reEstimate, isNotNull);
      expect(reEstimate!.angleDeg, closeTo(0, 1.0));
    });

    test('壊れたファイルで null（例外を握って fail-safe）', () async {
      final corrector = RollCorrector();
      final broken = File(
        '${Directory.systemTemp.path}/roll_test_broken_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await broken.writeAsBytes(<int>[0x00, 0x01, 0x02]);
      addTearDown(() {
        if (broken.existsSync()) {
          broken.deleteSync();
        }
      });
      // WHY await なし: maybeUpright は同期シグネチャ（File? 返し）。
      expect(corrector.maybeUpright(broken), isNull);
    });
  });
}
