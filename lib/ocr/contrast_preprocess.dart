import 'dart:typed_data';

/// 狭帯 crop に対するコントラスト前処理（ST-5 フェーズ2-G）。
///
/// WHY（docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22.md・
/// docs コミット 18b2111・リード承認済み）: r6（fef214b）で狭帯 scale 3.0 でも
/// 4 キー（5p1lg4/yb5h8w/enco0h/s9cv7b）が ML Kit 0 要素のまま不回復。視認
/// 可能なタイトルが crop 上に存在する（r6 §4.5）ため、原因は拡大率ではなく
/// 文字の描画形式（グラデーション/縁取り＝低コントラスト）。scale 1→2→3 の
/// 拡大で解消不能は実証済みのため、入力画像そのもののコントラストを操作する。
class ContrastPreprocess {
  const ContrastPreprocess._();

  /// RGBA ピクセル列を大津二値化して 2 値画像（RGBA・1 チャンネル複写）へ
  /// 変換する。前処理不能（単色・極小・閾値縮退）の場合は null を返し、
  /// 呼び出し側は元入力のまま再試行を諦める。
  ///
  /// WHY 戻り null の契約: 単色画像（文字構造の情報なし）や 1×1 等の極小
  /// 画像では二値化が意味を持たず、無意味な再認識コストを避ける。閾値で
  /// 片側クラスタが空になる縮退も同様。
  ///
  /// WHY 入力を書き換えない（新規リストを返す）: 呼び出し側が元クロップの
  /// バイト列を再利用できるようにする（可変共有の事故防止・テストの
  /// 決定性検証も単純になる）。コストは最大 3600×243 px ≈ 3.5MB の
  /// 追記域で、再試行経路のみの 1 回限りのため許容。
  ///
  /// [rgba] は 4 チャンネル RGBA8888（straight・alpha は不透明前提）。
  /// 出力は「少数派クラスタ（面積比が小さい方＝文字）を黒 0・多数派（背景）
  /// を白 255」に極性正規化した 2 値画像（各 px は (v, v, v, 255)）。
  ///
  /// WHY 極性固定: ML Kit v2 は暗字明背景を主学習分布とする（経験則）ため
  /// 文字を黒側に固定する。r7 計測で逆極性が上振れする場合は本契約の
  /// 極性を反転定数 1 つの変更で対応する。
  static Uint8List? binarize(Uint8List rgba, int width, int height) {
    if (width <= 0 || height <= 0) {
      return null;
    }
    final total = width * height;
    if (rgba.length < total * 4) {
      return null;
    }
    final histogram = _lumaHistogram(rgba, total);
    final threshold = _otsuThreshold(histogram, total);
    if (threshold == null) {
      return null;
    }
    return _applyBinary(rgba, total, threshold);
  }

  /// Rec.601 luma（0.299R + 0.587G + 0.114B）の 1000 倍整数演算。
  ///
  /// WHY 整数演算: 浮動小数点丸めを排除して決定性を担保しつつ、
  /// 1 px あたりの乗算 3 回に収める（最大 87.5 万 px ≈ 数 ms）。
  static int _luma(Uint8List rgba, int pixelIndex) {
    final o = pixelIndex * 4;
    return (299 * rgba[o] + 587 * rgba[o + 1] + 114 * rgba[o + 2]) ~/ 1000;
  }

  /// luma の 256 bin ヒストグラム。
  static Int32List _lumaHistogram(Uint8List rgba, int total) {
    final histogram = Int32List(256);
    for (var i = 0; i < total; i++) {
      histogram[_luma(rgba, i)]++;
    }
    return histogram;
  }

  /// 大津法: クラス間分散が最大になる閾値（低側クラスタは luma ≤ 閾値）。
  ///
  /// WHY 単色は null: 占有 bin が 1 つしかない（全ピクセル同値）画像は
  /// クラス分離が定義できず、閾値を決められない（binarize の縮退契約）。
  /// 占有 bin ≥ 2 なら両クラスタが非空の閾値が必ず存在する。
  static int? _otsuThreshold(Int32List histogram, int total) {
    var sumAll = 0;
    var occupiedBins = 0;
    for (var i = 0; i < 256; i++) {
      if (histogram[i] > 0) {
        occupiedBins++;
        sumAll += i * histogram[i];
      }
    }
    if (occupiedBins < 2) {
      return null;
    }
    var weightLow = 0;
    var sumLow = 0;
    var bestBetween = -1.0;
    var threshold = -1;
    for (var t = 0; t < 256; t++) {
      weightLow += histogram[t];
      if (weightLow == 0) {
        continue;
      }
      sumLow += t * histogram[t];
      final weightHigh = total - weightLow;
      if (weightHigh == 0) {
        break;
      }
      final meanLow = sumLow / weightLow;
      final meanHigh = (sumAll - sumLow) / weightHigh;
      final diff = meanLow - meanHigh;
      final between = weightLow * weightHigh * diff * diff;
      if (between > bestBetween) {
        bestBetween = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// 閾値で 2 値化し、少数派クラスタ（＝文字）を黒 0・多数派（＝背景）を
  /// 白 255 に極性正規化した新規 RGBA を返す。
  ///
  /// WHY タイ（両クラスタ同数）は暗側クラスタを文字とみなす: 面積基準が
  /// 決められない場合の決定的タイブレーク。暗字明背景へ正規化する方針と
  /// 整合する（暗い方を黒=文字にすれば常に暗字明背景になる）。
  static Uint8List _applyBinary(Uint8List rgba, int total, int threshold) {
    var lowCount = 0;
    for (var i = 0; i < total; i++) {
      if (_luma(rgba, i) <= threshold) {
        lowCount++;
      }
    }
    final lowIsText = lowCount * 2 <= total;
    final out = Uint8List(total * 4);
    for (var i = 0; i < total; i++) {
      final isLow = _luma(rgba, i) <= threshold;
      final isText = isLow ? lowIsText : !lowIsText;
      final v = isText ? 0 : 255;
      final o = i * 4;
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
      out[o + 3] = 255;
    }
    return out;
  }
}
