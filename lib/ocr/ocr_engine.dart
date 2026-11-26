/// OCR エンジンの抽象インターフェース（spec.md §7.3 OCR抽象レイヤー）。
///
/// v1（Android）では [MlKitOcrEngine]（google_mlkit_text_recognition）を使用。
/// 将来展開時は以下の系統を同じインターフェースで差し替える（spec.md §7.5）:
/// - Flutter Web: ブラウザOCR系統（ONNX Runtime Web + PaddleOCR / Tesseract.js）
/// - iOS: Apple Vision Framework（ML Kit 日本語未対応のため）
library;

import 'dart:io';
import 'dart:ui' show Rect;

import '../models/ocr_models.dart';

/// OCR で認識する文字スクリプトの指定。
///
/// WHY: スクリプトの使い分け（数値列は Latin・曲名帯は日本語。spec.md §5.2）
/// は呼び出し側の意図であり、engine 実装の詳細ではない。使用スクリプトを
/// engine 非依存の enum として契約側に置くことで、実装固有の型
/// （MlKitOcrEngine の MlKitScript 等）を抽象に漏らさない（DIP）。
/// 実装側でネイティブのスクリプト指定へ変換する。
enum OcrScript { latin, japanese }

/// OCR エンジン共通インターフェース。
///
/// 実装クラスは系統固有の結果構造を [OcrElement]/[OcrPageResult] に
/// 変換する責務を持つ。パイプライン（lib/ocr/pipeline.dart）は
/// このインターフェースのみを経由して OCR を呼び出すこと。
abstract class OcrEngine {
  /// [imageFile] を解析し、共通データモデルで結果を返す。
  ///
  /// 失敗時は [OcrEngineException] を投げる。
  Future<OcrPageResult> recognize(File imageFile);

  /// [imageFile] 内の [region]（画像座標・px）をクロップして再認識する。
  ///
  /// Wave 2（spec.md §5.2 の領域クロップ再 OCR）で使う: 全体 OCR で
  /// 検出できなかったフィールド（判定数・レベル等）を、ラベル位置を実測
  /// ジオメトリで囲んだ小領域に絞って再認識する。
  ///
  /// [script] で認識スクリプトを指定する。
  ///
  /// [pixelScale] はクロップ描画時の拡大率（1.0 で等倍）。
  /// WHY: Wave 2 初回計測（2026-11-22・30 枚）で、小さい白文字（判定数値）
  /// のクロップから 1 要素も検出されないケースが多発した。ML Kit のテキスト
  /// 検出は文字の絶対高さが小さいと検出漏れするため、等倍のままでは
  /// クロップの効果が制限される。拡大率を呼び出し側（RegionSpec）が
  /// 指定できるようにし、領域設計とともに計測で検証する。
  ///
  /// 返す [OcrPageResult] の要素 bbox は **クロップ領域内の座標** で、
  /// imageWidth/imageHeight はクロップ画像（拡大後）の寸法になる。
  /// WHY: 「pageResult の寸法はその要素座標の基準である」という不変式を
  /// 全体 OCR と共有する。正規化座標変換はクロップ空間で閉じるため、
  /// 呼び出し側は元画像座標に戻す必要があるときだけ region 原点を加算する。
  ///
  /// [contrastRetry] が true の場合、1 次認識の要素が 0 のときに限り
  /// クロップ画像へコントラスト前処理（大津二値化・
  /// ContrastPreprocess.binarize）を施して 2 次認識する。
  /// WHY（docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22.md・
  /// docs コミット 18b2111・リード承認済み）: r6 で狭帯 scale 3.0 でも
  /// グラデーション/縁取り文字（5p1lg4/yb5h8w/enco0h/s9cv7b）が 0 要素
  /// （r6 §4.5）。発火を 0 要素時に限定することで、r6 検出済みキーの
  /// 入力経路を一切変更せず（構造的非回帰）、コストも不検出キーのみが
  /// 支払う（+30-80ms/狭帯 spec の見積もり）。既定は false。
  ///
  /// 失敗時は [OcrEngineException] を投げる。
  Future<OcrPageResult> recognizeRegion(
    File imageFile,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  });

  /// エンジンが保持するネイティブリソースを解放する。
  ///
  /// 呼び出し後は再度 [recognize] を呼んではならない。
  Future<void> dispose();
}

/// OCR エンジンの処理に失敗したことを表す例外。
class OcrEngineException implements Exception {
  /// 人間可読なエラー説明。
  final String message;

  /// 根本原因（あれば）。
  final Object? cause;

  const OcrEngineException(this.message, {this.cause});

  @override
  String toString() => cause == null
      ? 'OcrEngineException: $message'
      : 'OcrEngineException: $message (cause: $cause)';
}
