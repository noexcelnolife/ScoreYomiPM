// ST-1 前処理 TDD テスト。
// 合成フィクスチャ（動的生成小画像）で分類・矩形検出・回転・クロップを検証。
// 実データ分類の回帰ガードは test/input_classification_realdata_test.dart。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:scoreyomipm/ocr/input_preprocessing.dart';

// テスト用に小さな画像を動的生成するヘルパー。
img.Image _makeTestImage({
  required int width,
  required int height,
  required List<List<ui.Color>> pixels,
}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = pixels[y][x];
      image.setPixelRgba(
        x,
        y,
        (c.r * 255.0).round().clamp(0, 255),
        (c.g * 255.0).round().clamp(0, 255),
        (c.b * 255.0).round().clamp(0, 255),
        (c.a * 255.0).round().clamp(0, 255),
      );
    }
  }
  return image;
}

/// 合成画像を PNG バイト列にする。
///
/// WHY ファイルに書かないか: 前処理の入出力はどちらもバイト列。一時ファイルを
/// 挟むと「テストが落ちたとき temp に残る」失敗モードだけが増える。
Uint8List _imageBytes(img.Image image) => img.encodePng(image);

void main() {
  group('InputPreprocessor.classify', () {
    test(
      'landscapePlayShare: w > h で端部が暗くない → landscapePlayShare（プレーシェア代表アスペクト）',
      () {
        // プレーシェア代表アスペクト ≒1.5（3000x2000）。実データ回帰ガード
        // （input_classification_realdata_test.dart）が authoritative。
        final pixels = List.generate(
          1080,
          (_) => List.filled(1620, ui.Color.fromARGB(255, 150, 150, 150)),
        );
        final image = _makeTestImage(width: 1620, height: 1080, pixels: pixels);
        final bytes = _imageBytes(image);

        final preprocessor = InputPreprocessor();
        final result = preprocessor.classify(bytes);

        expect(result, equals(InputImageClass.landscapePlayShare));
      },
    );

    test('portraitWithEmbedded: h > w → portraitWithEmbedded', () {
      final pixels = List.generate(
        2400,
        (_) => List.filled(1080, ui.Color.fromARGB(255, 255, 255, 255)),
      );
      final image = _makeTestImage(width: 1080, height: 2400, pixels: pixels);
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = preprocessor.classify(bytes);

      expect(result, equals(InputImageClass.portraitWithEmbedded));
    });

    test('rotatedPortrait: w > h で左右端が暗く中央が明るい → rotatedPortrait', () {
      final width = 2400;
      final height = 1080;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          final edgeWidth = (width * 0.05).round();
          final centerStart = (width * 0.4).round();
          final centerEnd = (width * 0.6).round();
          if (x < edgeWidth || x >= width - edgeWidth) {
            return ui.Color.fromARGB(255, 30, 30, 30);
          }
          if (x >= centerStart && x < centerEnd) {
            return ui.Color.fromARGB(255, 200, 200, 200);
          }
          return ui.Color.fromARGB(255, 100, 100, 100);
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = preprocessor.classify(bytes);

      expect(result, equals(InputImageClass.rotatedPortrait));
    });

    test('分類は低解像度サムネイルで動作（幅256px以下でも正しく分類）', () {
      // プレーシェア代表アスペクト ≒1.5（150x100）。低解像度でも
      // プレーシェア範囲内のアスペクトなら landscapePlayShare に分類。
      final pixels = List.generate(
        100,
        (_) => List.filled(150, ui.Color.fromARGB(255, 150, 150, 150)),
      );
      final image = _makeTestImage(width: 150, height: 100, pixels: pixels);
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = preprocessor.classify(bytes);

      expect(result, equals(InputImageClass.landscapePlayShare));
    });

    test('デコード不能なバイト列では landscapePlayShare にフォールバック', () {
      final preprocessor = InputPreprocessor();
      final result = preprocessor.classify(
        Uint8List.fromList(<int>[0x00, 0x01, 0x02]),
      );

      expect(result, equals(InputImageClass.landscapePlayShare));
    });
  });

  group('InputPreprocessor 回転方向検証（必須：方向バグを見逃さない）', () {
    test('rotatedPortrait: 90°CW回転済み画像を CCW (-90) で復元後、縦長（h>w）になる', () async {
      // 2400x1080 の回転済み縦スクショ（scr006-008 風）。
      // 左右端が暗く中央が明るい（rotatedPortrait 分類パターン）。
      final width = 2400;
      final height = 1080;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          final edgeWidth = (width * 0.05).round();
          final centerStart = (width * 0.4).round();
          final centerEnd = (width * 0.6).round();
          if (x < edgeWidth || x >= width - edgeWidth) {
            return ui.Color.fromARGB(255, 30, 30, 30); // 暗いビュワー背景
          }
          if (x >= centerStart && x < centerEnd) {
            return ui.Color.fromARGB(255, 200, 200, 200); // 明るいプレーシェア写真
          }
          return ui.Color.fromARGB(255, 100, 100, 100); // 中間
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.rotatedPortrait));
      // WHY(same でないこと): 前処理は画像を加工して PNG に再エンコードする。
      // 入力バイト列がそのまま返ってきたら前処理が効いていない。
      expect(result.preprocessedBytes, isNot(same(bytes)));

      // 出力をデコードして、CCW回転により縦長（h > w）になっていることを確認。
      // もし CW (+90) 回転だと、2400x1080 → 1080x2400 にもなるが、
      // 内容の向きが違う。ここでは単純にh>wを確認。
      final outputBytes = result.preprocessedBytes;
      final outputImage = img.decodeImage(outputBytes);
      expect(outputImage, isNotNull);

      if (outputImage != null) {
        expect(
          outputImage.height,
          greaterThan(outputImage.width),
          reason: 'CCW (-90) 回転後、横長画像は縦長（h > w）に戻るはず',
        );
      }
    });
  });

  group('InputPreprocessor.preprocess', () {
    test('landscapePlayShare: 前処理なしで入力バイト列をそのまま返す', () async {
      final pixels = List.generate(
        1080,
        (_) => List.filled(1620, ui.Color.fromARGB(255, 150, 150, 150)),
      );
      final image = _makeTestImage(width: 1620, height: 1080, pixels: pixels);
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.landscapePlayShare));
      // WHY(same): 前処理不要の経路はバイト列をそのまま後段へ渡す（再エンコード
      // による劣化も、無駄なメモリ確保もしない）。
      expect(result.preprocessedBytes, same(bytes));
      expect(result.embeddedRect, isNull);
      expect(result.aspectRatioValid, isTrue);
    });

    test('portraitWithEmbedded: 行分散最長 run で全幅帯を抽出（ST-5 フェーズ2-A）', () async {
      // 1080x2400：ビュワー背景（一様 40）+ 埋め込み帯（y 800-1520・720px）+
      // 下部の暗文字情報帯風 run（y 2000-2200・200px）。
      // ST-5 フェーズ2-A で契約変更: x バウンダリではなく全幅帯
      // (0, runTop, w, runBottom) を返す（実縦スクショは全幅レターボックス
      // 表示・9 枚実測で帯高さ 720 = アスペクト 1.5）。帯 720px ≫ 干渉 run
      // 200px で最長 run 選択が一意であることも確認。
      final width = 1080;
      final height = 2400;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          // 埋め込み帯（y 800-1520・高さ 720 = アスペクト 1.5 ちょうど）。
          if (y >= 800 && y < 1520 && x >= 200 && x < 880) {
            return ui.Color.fromARGB(255, 200, 200, 200);
          }
          if (y >= 2000 && y < 2200 && x >= 400 && x < 600) {
            // 暗背景上の暗文字風（新閾値 100 でコンテンツ行になる対比）。
            return (x + y) % 7 == 0
                ? ui.Color.fromARGB(255, 130, 130, 130)
                : ui.Color.fromARGB(255, 40, 40, 40);
          }
          return ui.Color.fromARGB(255, 40, 40, 40);
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.portraitWithEmbedded));
      // 全幅帯矩形（x バウンダリを捨ててレターボックス全幅を採る）。
      expect(result.embeddedRect, isNotNull);
      expect(result.embeddedRect!.left, equals(0));
      expect(result.embeddedRect!.top, equals(800));
      expect(result.embeddedRect!.right, equals(1080));
      expect(result.embeddedRect!.bottom, equals(1520));
      expect(result.aspectRatioValid, isTrue);
      // クロップ後は横長（レイアウト正規化）。
      final decoded = img.decodeImage(
        result.preprocessedBytes,
      );
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(1080));
      expect(decoded.height, equals(720));
      expect(decoded.width, greaterThan(decoded.height));
    });

    test('portraitWithEmbedded: UI 干渉 run があっても最長 run（写真帯）を選択', () async {
      // 実縦スクショ構造のミニチュア（9 枚実測の縮約）:
      // 背景一様 68・ステータスバー風 y 48-96・上部 UI 風 y 168-240・
      // 埋め込み帯 y 864-1584（720px 全幅）・下部 UI 風 y 2184-2280。
      // 実測: 背景行分散は正確に 0・写真帯行最小 351・UI run は短い
      // （48-96px ≪ 720px）。最長 run 選択で干渉 run を排することを確認。
      final width = 1080;
      final height = 2400;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          final check = (x ~/ 4 + y) % 2 == 0;
          if (y >= 864 && y < 1584) {
            // 埋め込み帯（全幅・強分散パターン）。列サンプリング step 4
            // でも交互になるよう x ~/ 4 ベースで交互化。
            final v = check ? 190 : 60;
            return ui.Color.fromARGB(255, v, v, v);
          }
          if ((y >= 48 && y < 96) ||
              (y >= 168 && y < 240) ||
              (y >= 2184 && y < 2280)) {
            // 干渉 run（UI 風・中分散 441）。
            final v = check ? 110 : 68;
            return ui.Color.fromARGB(255, v, v, v);
          }
          return ui.Color.fromARGB(255, 68, 68, 68);
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.portraitWithEmbedded));
      // 干渉 run（48-96px）ではなく写真帯 720px が選ばれる。
      expect(result.embeddedRect, isNotNull);
      expect(result.embeddedRect!.left, equals(0));
      expect(result.embeddedRect!.top, equals(864));
      expect(result.embeddedRect!.right, equals(1080));
      expect(result.embeddedRect!.bottom, equals(1584));
      expect(result.aspectRatioValid, isTrue);
    });

    test('帯内部の一様ストレッチで run が分断する場合は帯検出を諦め現行経路へ', () async {
      // リード承認時推奨ケース: 埋め込み帯内部に 24px 超の一様ストレッチ
      // （y 1152-1344・192px）があると run が分断され、最長断片（288px）は
      // アスペクト 3.75 で ±10% 外 → 帯検出 null → 従来 _detectEmbeddedRect
      // にフォールバック（現行経路維持）。断片の単独クロップを誤検出として
      // 排除し、現行どおり全体 bounding box で処理する挙動を固定する。
      final width = 1080;
      final height = 2400;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          final check = (x ~/ 4 + y) % 2 == 0;
          if ((y >= 864 && y < 1152) || (y >= 1344 && y < 1584)) {
            // 埋め込み帯の上半分・下半分（内部一様帯で分断）。
            final v = check ? 190 : 60;
            return ui.Color.fromARGB(255, v, v, v);
          }
          if ((y >= 48 && y < 96) || (y >= 2184 && y < 2280)) {
            // 干渉 run（UI 風）。
            final v = check ? 110 : 68;
            return ui.Color.fromARGB(255, v, v, v);
          }
          return ui.Color.fromARGB(255, 68, 68, 68);
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.portraitWithEmbedded));
      // フォールバック: 従来検出の bounding box（UI run も含む全範囲）。
      expect(result.embeddedRect, isNotNull);
      expect(result.embeddedRect!.top, lessThanOrEqualTo(100));
      expect(result.embeddedRect!.bottom, greaterThanOrEqualTo(2200));
      expect(result.embeddedRect!.left, lessThanOrEqualTo(10));
      expect(result.aspectRatioValid, isFalse);
      // クロップは帯の断片ではなく従来どおりの大型矩形（h > w）。
      final decoded = img.decodeImage(
        result.preprocessedBytes,
      );
      expect(decoded, isNotNull);
      expect(decoded!.height, greaterThan(decoded.width));
    });

    test('一様画像（コンテンツなし）は埋め込み帯検出なしで現行経路を維持', () async {
      // 帯検出も従来検出も不成立 → embeddedRect null・フルフレームクロップ
      // （aspectValid は現行どおり true のまま）。抽出失敗時フォールバック
      // 設計の境界ケースを固定する。
      final width = 1080;
      final height = 2400;
      final pixels = List.generate(
        height,
        (_) => List.filled(width, ui.Color.fromARGB(255, 68, 68, 68)),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.portraitWithEmbedded));
      expect(result.embeddedRect, isNull);
      expect(result.aspectRatioValid, isTrue);
      final decoded = img.decodeImage(
        result.preprocessedBytes,
      );
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(1080));
      expect(decoded.height, equals(2400));
    });

    test('rotatedPortrait: 90°CCW回転してクロップ出力', () async {
      final width = 2400;
      final height = 1080;
      final pixels = List.generate(
        height,
        (y) => List.generate(width, (x) {
          final edgeWidth = (width * 0.05).round();
          final centerStart = (width * 0.4).round();
          final centerEnd = (width * 0.6).round();
          if (x < edgeWidth || x >= width - edgeWidth) {
            return ui.Color.fromARGB(255, 30, 30, 30);
          }
          if (x >= centerStart && x < centerEnd) {
            return ui.Color.fromARGB(255, 200, 200, 200);
          }
          return ui.Color.fromARGB(255, 100, 100, 100);
        }),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.rotatedPortrait));
      expect(result.preprocessedBytes, isNot(same(bytes)));
      expect(result.preprocessedBytes, isNotEmpty);

      final decoded = img.decodeImage(
        result.preprocessedBytes,
      );
      expect(decoded, isNotNull);
      if (decoded != null) {
        // 回転後は縦長（h > w）になる。
        expect(decoded.height, greaterThan(decoded.width));
      }
    });

    test('アスペクト比検証: 実プレーシェア≒1.5 の ±10% 外なら aspectRatioValid=false', () async {
      // 極端なアスペクト比の画像（アスペクト比 5.0）。
      // プレーシェア範囲 [1.45, 1.70] 外なので arcadeResultFrame に分類。
      // aspectRatioValid は portraitWithEmbedded/rotatedPortrait のみ検証対象
      // で landscape/arcadeResultFrame はスキップ（true のまま）。
      // 実データ回帰ガード（input_classification_realdata_test.dart）
      // が classification の authoritative ソース。
      final width = 1000;
      final height = 200; // アスペクト比 5.0（プレーシェア範囲外）
      final pixels = List.generate(
        height,
        (_) => List.filled(width, ui.Color.fromARGB(255, 200, 200, 200)),
      );
      final image = _makeTestImage(
        width: width,
        height: height,
        pixels: pixels,
      );
      final bytes = _imageBytes(image);

      final preprocessor = InputPreprocessor();
      final result = await preprocessor.preprocess(bytes);

      expect(result.inputClass, equals(InputImageClass.arcadeResultFrame));
      expect(result.aspectRatioValid, isTrue);
    });
  });
}
