/* ST-1 前処理：縦スクリーンショット対応（spec.md §5.1）。
 *
 * 入力画像を 3 クラスに分類し、portraitWithEmbedded / rotatedPortrait の
 * 場合は埋め込みプレーシェア写真を矩形抽出・回転補正して正立ファイル
 * を出力する。landscapePlayShare の場合は前処理不要（既存経路そのまま）。
 *
 * 画像は image パッケージでデコード・加工し、一時ファイルに再エンコード
 * して OcrPipeline に渡す。UI シグネチャは不変（lib/ocr 内完結）。
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 入力画像の分類クラス。
enum InputImageClass {
  /// 横画面プレーシェア（w > h）。既存30枚の本物横プレーシェア。前処理不要。
  landscapePlayShare,

  /// 縦画面スクショ（h > w）。ギャラリービュワーUIで中央1/3帯に横画面プレーシェア
  /// が埋め込み。scr001-009 全枚（1080x2400・埋め込み写真は全て直立）。
  portraitWithEmbedded,

  /// 横寸法で内容が縦スクショの90°回転物（w > h）。
  /// WHY: 現時点の実データ（scr001-009・既存30枚）には該当なし。将来の
  /// 回転入力への耐性として分類と90°CCW補正経路を保持する。
  rotatedPortrait,

  /// アーケード実機結果画面（ac_v1 対象）。
  /// 主群は 2048x1536 (4:3=1.333) の横画面 23 枚、対象外群に横 16:9 5 枚・縦 3:4 2 枚。
  arcadeResultFrame,
}

/// 埋め込み写真のピクセル矩形（元画像座標系）。
class EmbeddedRect {
  final int left;
  final int top;
  final int right;
  final int bottom;

  EmbeddedRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left;
  int get height => bottom - top;
}

/// 前処理結果。
///
/// [inputClass] は分類結果。[preprocessedFile] は前処理後のファイルパス
/// （landscapePlayShare の場合は元ファイルと同一パス）。
/// [embeddedRect] は検出された埋め込み写真のピクセル矩形（元画像座標系）。
/// [aspectRatioValid] は検出矩形のアスペクト比が実プレーシェア
/// （1200x800 前後≒1.5・実測 1.481-1.506）の ±10% 以内か。
class PreprocessResult {
  final InputImageClass inputClass;
  final File preprocessedFile;
  final EmbeddedRect? embeddedRect;
  final bool aspectRatioValid;

  PreprocessResult({
    required this.inputClass,
    required this.preprocessedFile,
    this.embeddedRect,
    this.aspectRatioValid = true,
  });
}

/// ST-1 前処理エンジン。
///
/// 分類・埋め込み矩形検出・回転補正・クロップ出力を担当。
/// すべて純 Dart（image パッケージ使用）で、Flutter UI には依存しない。
class InputPreprocessor {
  /// 分類用低解像度デコードの最大幅（px）。分類コスト削減のため
  /// フル解像度デコードは前処理実行時のみ行う。
  static const int _classifyMaxWidth = 256;

  /// 行/列分散の閾値。これ以上なら「写真領域」とみなす（輝度二値化ではなく
  /// 分散ベースのため、暗部情報帯も正しく検出できる）。
  static const double _varianceThreshold = 400.0;

  /// WHY: 実プレーシェアのアスペクト比は 1200x800 前後（≒1.5・実測
  /// 1.481-1.506）。当初 2400x1080≒2.222 と想定していたが、実画像計測
  /// （testimage 30枚の寸法確認）で誤りと判明したため 1.5 に修正。
  /// 検出矩形がこの範囲外なら写真以外（UI要素等）を拾った可能性が高い。
  static const double _expectedAspectRatio = 1200 / 800;
  static const double _aspectRatioTolerance = 0.10;

  /// ST-5 フェーズ2-A: 行分散による埋め込み帯検出の閾値（rowVar）。
  /// WHY: 9 枚の実縦スクショ（1080x2400）のホスト側計測で、ギャラリービュワー
  /// 背景行は分散が正確に 0（平均輝度 68.0・y 240-863 と y 1608-2183）、
  /// 埋め込み写真帯行は最小 351（y 864-1583・高さ 720px の全幅レターボックス）。
  /// 100 は写真帯最小値の 3.5 分の 1 に置く安全側マージン。
  static const double _bandRowVarianceThreshold = 100.0;

  /// 隣接コンテンツ行 run の統合ギャップ上限（px）。
  /// WHY: 実 9 枚で写真帯と UI run（ステータスバー y 48-95・上部 UI
  /// y 168-239・下部 UI y 2184-2279）の間隔は 576-625px の分散 0 ギャップ。
  /// 24px 以下の微小ギャップ（帯内の僅かな均一行等）は同一 run に統合し、
  /// 写真帯の分断を防ぐ。
  static const int _bandRunGapMergeMax = 24;

  /// 帯検出時の列サンプリング刻み（px）。行分散計算のコスト削減
  /// （1080 列 → 270 サンプル）。既存 _detectEmbeddedRect は全列走査のまま
  /// （フォールバック経路の挙動を不変に保つため変更しない）。
  static const int _bandColumnSampleStep = 4;

  /// アーケード実機結果画面の見分けに使うアスペクト比閾値。
  ///
  /// WHY: testimage 全実画像（playshare 39 枚＋AC-HC-photo 30 枚）を計測し、
  /// クラス間に明確な隙間があることを確認済み
  /// （docs/arcade_photo_geometry_analysis_2026-11-23.md §2）。
  /// - プレーシェア横画面: ar 1.481-1.506（≒1.5）
  /// - アーケード横画面主群: ar 1.317-1.399（4:3）、16:9 群: ar 1.743-1.801
  /// - プレーシェア縦スクショ: ar 0.450（1080x2400）
  /// - アーケード縦画面: ar 0.750（1536x2048、3:4）
  static const double _kArcadePortraitAspectMin = 0.55;
  static const double _kArcadeLandscapeAspectMax = 1.45;
  static const double _kArcadeLandscape16x9AspectMin = 1.70;

  /// 入力画像を分類する。
  ///
  /// 分類基準:
  /// - h > w → portraitWithEmbedded（縦画面）
  /// - w > h で端部が暗く中央が明るい → rotatedPortrait（回転済み縦スクショ）
  /// - w > h でそれ以外 → landscapePlayShare（本物横プレーシェア）
  ///
  /// 分類コスト削減のため低解像度デコード（幅≤$_classifyMaxWidth px）を使用。
  /// 既存30枚（1200x800 前後・本物横プレーシェア）は end 部が暗くないため
  /// landscapePlayShare に分類され、前処理スキップで回帰ガードされる。
  InputImageClass classify(File imageFile) {
    final bytes = _readBytesSafely(imageFile);
    if (bytes == null) {
      // ファイル読み込み失敗時は landscapePlayShare とみなし、既存経路に任せる。
      return InputImageClass.landscapePlayShare;
    }
    final image = img.decodeImage(bytes);
    if (image == null) {
      // デコード失敗時は landscapePlayShare とみなし、既存経路に任せる。
      return InputImageClass.landscapePlayShare;
    }

    // 低解像度サムネイルで分類（幅≤256px）。フル解像度デコードは前処理実行時のみ。
    final thumb = img.copyResize(image, width: _classifyMaxWidth);

    final width = thumb.width;
    final height = thumb.height;
    final aspect = width / height;

    // 縦画面: アーケード実機結果画面 (3:4, ar=0.75) か
    // プレーシェア埋め込みスクリーンショット (ar=0.45) か。
    if (height > width) {
      if (aspect > _kArcadePortraitAspectMin) {
        return InputImageClass.arcadeResultFrame;
      }
      return InputImageClass.portraitWithEmbedded;
    }

    // w > h: 端部サンプリングで rotatedPortrait か landscapePlayShare か判定。
    final leftAvg = _sampleEdgeAvg(thumb, edge: 'left');
    final rightAvg = _sampleEdgeAvg(thumb, edge: 'right');
    final centerAvg = _sampleCenterAvg(thumb);

    // 両端が暗く中央が明るい → ビュワー背景+中央埋め込み = rotatedPortrait。
    if (leftAvg < 60 && rightAvg < 60 && centerAvg > 120) {
      return InputImageClass.rotatedPortrait;
    }

    // 横画面: アーケード実機結果画面 (4:3 ar=1.333 / 16:9 ar=1.778) か
    // プレーシェア (ar≈1.5) か。playshare は [1.45, 1.70] に集中し、
    // アーケードは 1.45 未満（4:3）または 1.70 超（16:9）に分離する。
    if (aspect < _kArcadeLandscapeAspectMax ||
        aspect > _kArcadeLandscape16x9AspectMin) {
      return InputImageClass.arcadeResultFrame;
    }

    return InputImageClass.landscapePlayShare;
  }

  /// 前処理を実行し、前処理済みファイルを返す。
  ///
  /// landscapePlayShare の場合は前処理なしで元ファイルを返す。
  /// portraitWithEmbedded / rotatedPortrait の場合は埋め込み写真を矩形抽出、
  /// rotatedPortrait は90°CCW回転を適用し、一時ファイルに再エンコードして返す。
  Future<PreprocessResult> preprocess(File imageFile) async {
    // 分類は低解像度で実施。
    final inputClass = classify(imageFile);

    if (inputClass == InputImageClass.landscapePlayShare) {
      return PreprocessResult(
        inputClass: inputClass,
        preprocessedFile: imageFile,
        aspectRatioValid: true,
      );
    }

    // フル解像度デコード（前処理実行時のみ）。
    final bytes = _readBytesSafely(imageFile);
    if (bytes == null) {
      return PreprocessResult(
        inputClass: inputClass,
        preprocessedFile: imageFile,
        aspectRatioValid: false,
      );
    }
    final image = img.decodeImage(bytes);
    if (image == null) {
      return PreprocessResult(
        inputClass: inputClass,
        preprocessedFile: imageFile,
        aspectRatioValid: false,
      );
    }

    // rotatedPortrait は90°CCW回転（image パッケージは正角度=CW なので -90 が CCW）。
    // 回転後に矩形検出を行う（回転後の座標系でクロップするため）。
    var processed = image;
    if (inputClass == InputImageClass.rotatedPortrait) {
      processed = img.copyRotate(image, angle: -90);
    }

    // 埋め込み写真の矩形を検出。ST-5 フェーズ2-A: portraitWithEmbedded は
    // 行分散最長 run による全幅帯検出（ギャラリーレターボックス表示の抽出・
    // レイアウト正規化）を優先し、検出失敗・アスペクト不成立時は従来の
    // _detectEmbeddedRect 結果へフォールバックする（現行 1071x2316 経路維持・
    // 2aaa83f の h>w 分岐が効くため悪化しない）。rotatedPortrait は従来検出
    // のまま（回転後の画像で検出し、クロップ座標を正しく保つ）。
    final EmbeddedRect? embeddedRect;
    if (inputClass == InputImageClass.portraitWithEmbedded) {
      embeddedRect =
          _detectPhotoBandRect(processed) ?? _detectEmbeddedRect(processed);
    } else {
      embeddedRect = _detectEmbeddedRect(processed);
    }

    // アスペクト比検証：実プレーシェア 1200x800 前後（≒1.5）から
    // ±10% 外なら無効（写真以外を拾った可能性が高い）。
    bool aspectValid = true;
    if (embeddedRect != null) {
      final ar = embeddedRect.width / embeddedRect.height;
      aspectValid =
          (ar - _expectedAspectRatio).abs() <=
          _expectedAspectRatio * _aspectRatioTolerance;
    }

    // 埋め込み矩形でクロップ（矩形が検出できない場合は全画像）。
    final cropRect =
        embeddedRect ??
        EmbeddedRect(
          left: 0,
          top: 0,
          right: processed.width,
          bottom: processed.height,
        );
    // 不正な矩形（right<=left や bottom<=top）は全画像クロップにフォールバック。
    final safeCrop =
        (cropRect.right > cropRect.left && cropRect.bottom > cropRect.top)
        ? cropRect
        : EmbeddedRect(
            left: 0,
            top: 0,
            right: processed.width,
            bottom: processed.height,
          );
    final cropped = img.copyCrop(
      processed,
      x: safeCrop.left,
      y: safeCrop.top,
      width: safeCrop.width,
      height: safeCrop.height,
    );

    // 一時ファイルに再エンコード（PNG。JPEG 再圧縮による劣化を回避）。
    final tmpDir = Directory.systemTemp;
    final tmpFile = File(
      '${tmpDir.path}/scoreyomipm_preprocessed_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await tmpFile.writeAsBytes(img.encodePng(cropped));

    return PreprocessResult(
      inputClass: inputClass,
      preprocessedFile: tmpFile,
      embeddedRect: embeddedRect,
      aspectRatioValid: aspectValid,
    );
  }

  /// ファイルを安全に読み込む。失敗時は null を返す。
  Uint8List? _readBytesSafely(File imageFile) {
    try {
      return imageFile.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  /// 端部（左/右）の平均輝度をサンプリングする。
  double _sampleEdgeAvg(img.Image image, {required String edge}) {
    final width = image.width;
    final height = image.height;
    final sampleWidth = (width * 0.05).round().clamp(1, width ~/ 2);
    int total = 0;
    int count = 0;

    for (var y = 0; y < height; y += 4) {
      for (var x = 0; x < sampleWidth; x += 4) {
        final px = edge == 'left'
            ? image.getPixel(x, y)
            : image.getPixel(width - 1 - x, y);
        total += (px.r + px.g + px.b) ~/ 3;
        count++;
      }
    }

    return count > 0 ? total / count : 255;
  }

  /// 画像中央縦帯の平均輝度をサンプリングする。
  double _sampleCenterAvg(img.Image image) {
    final width = image.width;
    final height = image.height;
    final cx = width ~/ 2;
    final bandWidth = (width * 0.2).round().clamp(1, width);
    final startX = (cx - bandWidth ~/ 2).clamp(0, width - bandWidth);
    int total = 0;
    int count = 0;

    for (var y = 0; y < height; y += 4) {
      for (var x = startX; x < startX + bandWidth; x += 4) {
        final px = image.getPixel(x, y);
        total += (px.r + px.g + px.b) ~/ 3;
        count++;
      }
    }

    return count > 0 ? total / count : 0;
  }

  /// 1 次元配列の分散（変動量）を計算する。
  ///
  /// 背景行/列は一様で分散≈0、写真の行/列は文字・グラデーションで分散が立つ。
  /// 輝度二値化とは異なり、暗部情報帯（暗文字 on 暗背景）も正しく検出できる。
  double _variance(List<int> values) {
    if (values.isEmpty) return 0.0;
    final n = values.length;
    double sum = 0;
    double sumSq = 0;
    for (final v in values) {
      sum += v;
      sumSq += v * v;
    }
    final mean = sum / n;
    return sumSq / n - mean * mean;
  }

  /// 埋め込みプレーシェア写真の矩形を検出する。
  ///
  /// 行/列の分散（変動量）ベースで、背景と写真領域の境界を検出。
  /// 輝度二値化ではなく分散を使うため、暗部情報帯（プレイヤー名・日付等）
  /// も正しく写真領域として含められる。
  /// 検出できない場合は null。
  EmbeddedRect? _detectEmbeddedRect(img.Image image) {
    final width = image.width;
    final height = image.height;

    // 各行・各列の分散を計算。
    final rowVariance = <double>[];
    final colVariance = <double>[];

    for (var y = 0; y < height; y++) {
      final row = <int>[];
      for (var x = 0; x < width; x++) {
        final px = image.getPixel(x, y);
        row.add((px.r + px.g + px.b) ~/ 3);
      }
      rowVariance.add(_variance(row));
    }

    for (var x = 0; x < width; x++) {
      final col = <int>[];
      for (var y = 0; y < height; y++) {
        final px = image.getPixel(x, y);
        col.add((px.r + px.g + px.b) ~/ 3);
      }
      colVariance.add(_variance(col));
    }

    // 分散が閾値を超える行・列の範囲を特定。
    int minX = width, minY = height, maxX = 0, maxY = 0;
    bool found = false;

    for (var y = 0; y < height; y++) {
      if (rowVariance[y] > _varianceThreshold) {
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        found = true;
      }
    }

    for (var x = 0; x < width; x++) {
      if (colVariance[x] > _varianceThreshold) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        found = true;
      }
    }

    if (!found) return null;

    // マージンを少し追加（端の暗いピクセルを含めないよう内側に寄せる）。
    // left < right かつ top < bottom を保証（不正な矩形は null を返す）。
    final margin = 4;
    final left = (minX + margin).clamp(0, width - 1);
    final top = (minY + margin).clamp(0, height - 1);
    final right = (maxX - margin).clamp(0, width - 1);
    final bottom = (maxY - margin).clamp(0, height - 1);

    if (right <= left || bottom <= top) return null;

    return EmbeddedRect(left: left, top: top, right: right, bottom: bottom);
  }

  /// portraitWithEmbedded の埋め込み写真帯を「行分散の最長連続区間」で検出する。
  ///
  /// ST-5 フェーズ2-A。実縦スクショではプレーシェア写真がギャラリービュワーで
  /// 全幅レターボックス表示され（1080 幅・9 枚実測で帯 y 864-1583・高さ
  /// 720px = アスペクト 1.5）、ビュワー背景行の分散は正確に 0 になる。そこで
  /// 各行の分散（列サンプリング step 4）が閾値を超える行を run にまとめ
  /// （ギャップ ≤ 24px は統合）、最長 run を写真帯とする。写真帯 720px ≫
  /// UI run 48-96px（ステータスバー・上下 UI）のため最長 run の選択は一意。
  ///
  /// 検出時は全幅矩形 (0, runTop, w, runBottom) を返す（x バウンダリは
  /// レターボックス全幅表示のため意味を持たない・既存アスペクト検証が
  /// 1.5±10% を後段でも確認）。最長 run のアスペクトが ≒1.5 から外れる場合
  /// （帯内部の一様ストレッチで run が分断した断片を拾った場合等）は null を
  /// 返し、呼び出し側が従来の _detectEmbeddedRect 結果にフォールバックする
  /// （現行 1071x2316 経路維持）。不採用案: 固定座標クロップ（端末差に脆弱）・
  /// 輝度ベース検出（暗部情報帯を取りこぼす）。
  EmbeddedRect? _detectPhotoBandRect(img.Image image) {
    final width = image.width;
    final height = image.height;

    // 各行の分散（列サンプリングで計算コスト削減）。
    final contentRows = List<bool>.filled(height, false);
    for (var y = 0; y < height; y++) {
      final row = <int>[];
      for (var x = 0; x < width; x += _bandColumnSampleStep) {
        final px = image.getPixel(x, y);
        row.add((px.r + px.g + px.b) ~/ 3);
      }
      contentRows[y] = _variance(row) > _bandRowVarianceThreshold;
    }

    // コンテンツ行を run（連続区間）に分割。ギャップ ≤ _bandRunGapMergeMax
    // は同一 run に統合。run は [start, end)（end は最終コンテンツ行 + 1）。
    final runs = <List<int>>[];
    var runStart = -1;
    var gapSinceLastContent = 0;
    for (var y = 0; y < height; y++) {
      if (contentRows[y]) {
        if (runStart < 0) {
          runStart = y;
        } else if (gapSinceLastContent > _bandRunGapMergeMax) {
          runs.add([runStart, y - gapSinceLastContent]);
          runStart = y;
        }
        gapSinceLastContent = 0;
      } else if (runStart >= 0) {
        gapSinceLastContent++;
      }
    }
    if (runStart >= 0) {
      runs.add([runStart, height - gapSinceLastContent]);
    }

    if (runs.isEmpty) return null;

    // 最長 run を選択（写真帯 720px ≫ UI run 48-96px で一意）。
    var best = runs[0];
    for (final run in runs) {
      if (run[1] - run[0] > best[1] - best[0]) best = run;
    }

    final rect = EmbeddedRect(
      left: 0,
      top: best[0],
      right: width,
      bottom: best[1],
    );

    // アスペクト検証（実プレーシェア ≒1.5 ±10%）。run 分断の断片（帯内部の
    // 一様ストレッチで割れた半分等）を誤検出として排除し、現行経路へ落ちる。
    final ar = rect.width / rect.height;
    if ((ar - _expectedAspectRatio).abs() >
        _expectedAspectRatio * _aspectRatioTolerance) {
      return null;
    }
    return rect;
  }
}
