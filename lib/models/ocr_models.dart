/// 共通 OCR データモデル（spec.md §7.3 OCR抽象レイヤー）。
///
/// ML Kit / 将来のブラウザOCR系統（Flutter Web）/ Apple Vision（iOS）など、
/// OCRエンジンの系統に依存しない共通のデータ構造を定義する。
/// このファイルは flutter 以外の OCR パッケージに依存してはならない。
library;

import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// クロップ再 OCR（Wave 2）の対象。
///
/// WHY: 抽出コア（FieldExtractor のマージ処理）と領域算出
/// （region_spec.dart）・実行（region_ocr.dart）の双方が参照する共有語彙
/// なので、依存グラフの下層（models）に置く。
enum RegionTarget {
  score,
  cool,
  great,
  good,
  bad,
  maxCombo,

  /// レベル（1〜50 の整数・2026-11-21 ユーザー確認）。
  level,

  /// 曲名帯（ジャンル/カテゴリ行 + 曲名行。ST-5 の照合対象は曲名のみ）。
  songTitle,
}

/// 画像から認識された 1 要素（≒ 単語 / 短い文字列）。
///
/// spec.md §7.3: 「OCR結果の共通データモデル（テキスト・バウンディングボックス・
/// 信頼度）を抽象レイヤーで統一」するための最小単位。
@immutable
class OcrElement {
  /// 認識された文字列。
  final String text;

  /// 元画像座標系における要素の外接矩形。
  final Rect boundingBox;

  /// 認識信頼度（0.0〜1.0）。
  ///
  /// エンジンが信頼度を提供しない場合は [confidenceUnknown] を設定する
  /// （例: ML Kit は Android のみ confidence を返し、iOS では null になる）。
  final double confidence;

  /// 信頼度が不明であることを示すセンチネル値。
  static const double confidenceUnknown = -1.0;

  const OcrElement({
    required this.text,
    required this.boundingBox,
    required this.confidence,
  });

  /// 信頼度が不明かどうか。
  bool get hasUnknownConfidence => confidence == confidenceUnknown;

  OcrElement copyWith({String? text, Rect? boundingBox, double? confidence}) {
    return OcrElement(
      text: text ?? this.text,
      boundingBox: boundingBox ?? this.boundingBox,
      confidence: confidence ?? this.confidence,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OcrElement &&
        other.text == text &&
        other.boundingBox == boundingBox &&
        other.confidence == confidence;
  }

  @override
  int get hashCode => Object.hash(text, boundingBox, confidence);

  @override
  String toString() =>
      'OcrElement(text: $text, boundingBox: $boundingBox, confidence: $confidence)';
}

/// 1 枚の画像に対する OCR 結果全体。
///
/// [elements] は行・ブロック構造をフラット化した要素列、
/// [fullText] はエンジンが返した画像全体のテキスト（改行等を含む生文字列）。
@immutable
class OcrPageResult {
  /// 認識された要素のリスト（読み取り順の保証はない）。
  final List<OcrElement> elements;

  /// 画像全体の認識テキスト（要素を連結したものではなく、エンジンの生出力）。
  final String fullText;

  /// OCR 対象画像の幅（px）。
  ///
  /// WHY: 要素 bbox は画像座標（px）だが、FieldExtractor はレイアウト判定を
  /// 正規化座標（0..1）で行う。変換には画像寸法が必須のため、寸法の単一情報源
  /// を [OcrPageResult] 自身に置き、engine が decode 時に設定する
  /// （呼び出し側が別途画像を decode して寸法を渡す二重管理を避ける）。
  /// null 許容は既存の呼び出し側（テスト用 fake engine 等）との互換性維持で、
  /// 実エンジン（[MlKitOcrEngine]）は常に設定する。
  final int? imageWidth;

  /// OCR 対象画像の高さ（px）。[imageWidth] を参照。
  final int? imageHeight;

  const OcrPageResult({
    required this.elements,
    required this.fullText,
    this.imageWidth,
    this.imageHeight,
  });

  /// 空の結果（認識なし）。
  const OcrPageResult.empty()
    : elements = const [],
      fullText = '',
      imageWidth = null,
      imageHeight = null;

  /// 要素が 1 つも無いかどうか。
  bool get isEmpty => elements.isEmpty && fullText.isEmpty;

  /// 同値性は要素列の「中身」まで深く比較する（[listEquals]）。
  ///
  /// WHY: かつては `elements.length` の一致のみを比較していた。これでは
  /// 「同要素数・異内容」の 2 結果（例: 認識テキストだけ異なる結果）が
  /// 誤って等しいと判定され、(1) 要素内容から計算される hashCode との
  /// 契約（== で等しいオブジェクトは同じ hashCode を返さなければならない）
  /// が破れて Set / Map で「等しいのに別エントリ」となり得るうえ、
  /// (2) 意味論的にも浅すぎる（要素数と fullText が一致するだけの別結果が
  /// 「等しい」扱いになる）ため、要素ごとの == で完全比較に修正した。
  /// 画像寸法も結果の同一性に含まれる（同一要素列でも寸法が異なれば
  /// 正規化座標が変わるため）ので == / hashCode に含める。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OcrPageResult &&
        other.fullText == fullText &&
        other.imageWidth == imageWidth &&
        other.imageHeight == imageHeight &&
        listEquals(other.elements, elements);
  }

  /// WHY: == が要素内容まで見る深い比較のため、hashCode も要素ごとの
  /// ハッシュを順序込みで組み合わせる（[Object.hashAll]）。== で等しい
  /// 2 インスタンスは同一の要素列を持つので必ず同じ hashCode になり、
  /// 契約を満たす（内容が異なる場合の衝突は契約上許容される）。
  @override
  int get hashCode =>
      Object.hash(Object.hashAll(elements), fullText, imageWidth, imageHeight);

  @override
  String toString() =>
      'OcrPageResult(elements: ${elements.length}, fullText: "$fullText", '
      'imageWidth: $imageWidth, imageHeight: $imageHeight)';
}

/// 手動種別選択フロー（v3）でパイプラインへ渡すレイアウトヒント。
///
/// WHY: ユーザーが「画像を取り込む」前に対象種別（HC プレーシェア / HC リザルト
/// 写真）を選択した結果を OCR 層へ伝えるための入力
/// （docs/v3_input_source_flow_design_2026-11-23.md §2・2026-11-23 ユーザー
/// 裁定済み）。ST-1 自動分類（[InputImageClass]）と直交する入力で、共有
/// インテント経由（FR-1）では null のまま（自動分類優先・現行挙動不変・裁定 A）。
enum InputLayoutHint {
  /// HC プレーシェア画面（hcV1 レイアウト）。
  hcV1,

  /// HC リザルト写真（acV1 レイアウト）。
  acV1,

  /// PC 版 Lively のスコア画面写真（livelyV1 レイアウト）。
  ///
  /// WHY 自動分類しないか: Lively は PC 画面の写真で、アスペクト比も構図も
  /// HC プレイシェア画像と重なる。誤って HC 経路に流すとパネル切り出しが
  /// 二重にかかって全滅するため、AC 版と同じくユーザー選択を必須にする。
  livelyV1,
}
