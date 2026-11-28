/// PaddleOCR（ブラウザの ONNX Runtime Web）で動く [OcrEngine] 実装。
///
/// WHY(JS を知らない層として分けるか): 認識の「意味論」——クロップの作り方、
/// 返す座標系、再試行の発火条件、失敗をどの型で表すか——は JS と無関係に
/// 決まる。JS 呼び出しだけを [PaddleOcrClient] として外へ出せば、この層は
/// ブラウザ無しで動き、`flutter test`（VM）で実挙動を検証できる。
/// 分けずに `dart:js_interop` と同居させると、この層の検証手段が
/// 実機ブラウザ 1 本だけになる。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/ocr_models.dart';
import 'contrast_preprocess.dart';
import 'ocr_engine.dart';

/// 実際の推論を担う境界（実装は Web 側の JS 呼び出し）。
///
/// WHY(インターフェースで切るか): [PaddleOcrEngine] の検証にブラウザも
/// モデルも要らなくするため。テストは「こういう要素が返ってきたら
/// どう振る舞うか」だけを確かめればよい。
abstract class PaddleOcrClient {
  /// 初回のみ時間がかかる準備（エンジンとモデルの読み込み）の最中かどうか。
  ///
  /// 既定は false。準備のあるクライアントだけが override する。
  /// 意味は [OcrEngine.isPreparing] と同じ「初回読み込み中」に固定する。
  bool get isPreparing => false;

  /// [encodedImageBytes]（PNG/JPEG などのエンコード済み画像）を認識し、
  /// **入力画像のピクセル座標系**で [OcrElement] を返す。
  ///
  /// 失敗は [OcrEngineException] で包んで投げること（素の例外を漏らさない）。
  Future<List<OcrElement>> detect(Uint8List encodedImageBytes);

  /// 推論リソース（worker・セッション等）を解放する。以降 [detect] を
  /// 呼んではならない。
  Future<void> dispose();
}

/// [OcrEngine] の PaddleOCR 実装。
///
/// 契約の意味論は [MlKitOcrEngine] と揃えてある（同じパイプラインが
/// エンジンだけ差し替えて動くため）。
class PaddleOcrEngine extends OcrEngine {
  /// [client] が推論を担う。
  PaddleOcrEngine(this._client);

  final PaddleOcrClient _client;

  static const String _disposedMessage =
      'PaddleOcrEngine has already been disposed.';

  /// 破棄済みか。破棄後は [recognize] 系が [StateError] になる。
  bool _disposed = false;

  @override
  bool get isPreparing => _client.isPreparing;

  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) async {
    _ensureUsable(encodedImageBytes);
    final elements = await _detect(encodedImageBytes);
    // WHY(寸法をここで取るか): [OcrPageResult.imageWidth] は
    // 「elements の座標がどの画像のものか」の単一情報源である。
    // 認識に渡した画像そのものの寸法を、認識に渡した画像から読む。
    final size = await _tryDecodeSize(encodedImageBytes);
    return OcrPageResult(
      elements: elements,
      fullText: _joinText(elements),
      imageWidth: size?.$1,
      imageHeight: size?.$2,
    );
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    ui.Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    _ensureUsable(encodedImageBytes);
    // DEVIATION(OcrScript): ブラウザ版は日本語と英数字を単一モデル
    // （PP-OCRv5 mobile det + rec）で認識するため、スクリプトによる認識器の
    // 切り替えが存在しない。
    // 代替案: スクリプト別にモデルを 2 つ同梱する案は、配布サイズが約 16MB
    // 増え、初回読み込み時間に直結するため採らない（NOTICE.md の同梱物を参照）。
    // 再検討条件: 数値列（スコア・判定数）の認識率が実測で不足した場合。
    final cropped = await _crop(encodedImageBytes, region, pixelScale);
    try {
      // WHY(クロップしてから認識するか): 拡大したクロップを渡すことで、
      // 小さい文字の絶対高さを稼ぐ（契約の pixelScale の説明を参照）。
      final first = await _recognizeImage(cropped);
      // WHY 発火条件: 二値化再試行は「0 要素」のときに限る。常時前置きは
      // 成功経路のコストを増やすだけで、既に検出できている入力を変える。
      if (!contrastRetry || first.elements.isNotEmpty) {
        return first;
      }
      // WHY(縮退時に 1 次を返すか): 単色画像などで二値化できない場合は
      // 再試行を諦める。再試行は 1 次より悪くしない（結果は置換のみ、マージしない）。
      final retried = await _retryWithContrast(cropped);
      return retried ?? first;
    } finally {
      cropped.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _client.dispose();
    } on Exception {
      // WHY(握り潰すか): 解放に失敗しても呼び出し側に回復手段は無く、
      // ここで投げると「記録の保存」まで巻き添えになる。未解放は
      // アプリ終了時に回収される。
    }
  }

  /// 破棄済み・空入力といった「呼ぶ前に分かる」失敗を弾く。
  void _ensureUsable(Uint8List encodedImageBytes) {
    if (_disposed) {
      throw StateError(_disposedMessage);
    }
    if (encodedImageBytes.isEmpty) {
      throw const OcrEngineException('空の画像データが OCR に渡されました。');
    }
  }

  /// JS 側の推論を呼び、失敗を [OcrEngineException] に揃える。
  ///
  /// WHY(すべて包むか): [OcrEngine] の契約は「失敗は OcrEngineException」。
  /// 呼び出し側はそれだけを捕まえて未確定レコードの保存に倒すため、
  /// 素の例外を漏らすと復旧経路に入らず記録が失われる。
  Future<List<OcrElement>> _detect(Uint8List encodedImageBytes) async {
    try {
      return await _client.detect(encodedImageBytes);
    } on OcrEngineException {
      rethrow;
    } catch (error) {
      throw OcrEngineException(
        'ブラウザ版の文字認識に失敗しました。',
        cause: error,
      );
    }
  }

  /// [image] を PNG にして認識し、[image] の寸法を持つ結果を返す。
  ///
  /// WHY(寸法を image から取るか): クロップ再認識の契約は「bbox はクロップ内
  /// 座標、imageWidth/Height はクロップ画像の寸法」である。同じ画像から
  /// 両方を出すことで、この不変式が構造的に崩れない。
  Future<OcrPageResult> _recognizeImage(ui.Image image) async {
    final elements = await _detect(await _encodePng(image));
    return OcrPageResult(
      elements: elements,
      fullText: _joinText(elements),
      imageWidth: image.width,
      imageHeight: image.height,
    );
  }

  /// 0 要素時の二値化前処理付き再認識。
  ///
  /// [cropped] の生 RGBA を大津二値化した画像を作り直して 2 回目の認識を
  /// 実行する。単色などで [ContrastPreprocess.binarize] が null を返した
  /// （＝縮退して再試行に意味が無い）場合は null を返し、呼び出し側が
  /// 1 次結果を返す。
  Future<OcrPageResult?> _retryWithContrast(ui.Image cropped) async {
    // WHY rawRgba: 二値化の入力は生 RGBA（1 ピクセル 4 バイト）。エンコード
    // 済み形式はデコードし直しが要るため使わない。
    final rawBytes = await cropped.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rawBytes == null) {
      return null;
    }
    final binarized = ContrastPreprocess.binarize(
      rawBytes.buffer.asUint8List(rawBytes.offsetInBytes, rawBytes.lengthInBytes),
      cropped.width,
      cropped.height,
    );
    if (binarized == null) {
      return null;
    }
    final retryImage = await _imageFromRgba(
      binarized,
      cropped.width,
      cropped.height,
    );
    try {
      return await _recognizeImage(retryImage);
    } finally {
      retryImage.dispose();
    }
  }

  /// エンコード済みバイト列から [region] を [pixelScale] 倍で切り出す。
  ///
  /// WHY 拡大するか: 小さい白文字（判定数値など）は認識器の検出下限を
  /// 下回り、等倍クロップでは 1 要素も返らないことがある。拡大して文字の
  /// 絶対高さを稼ぐ。
  Future<ui.Image> _crop(
    Uint8List encodedImageBytes,
    ui.Rect region,
    double pixelScale,
  ) async {
    if (pixelScale <= 0) {
      throw ArgumentError.value(pixelScale, 'pixelScale', 'must be positive');
    }
    if (region.isEmpty || region.width <= 0 || region.height <= 0) {
      throw ArgumentError.value(
        region,
        'region',
        'must be a non-empty rectangle with positive size',
      );
    }
    final source = await _decodeImage(encodedImageBytes);
    try {
      // WHY(clamp するか): ラベル bbox から算出した領域はマージン加算などで
      // 画像境界を数 px はみ出すことがある。はみ出し分は切り捨てる方が安全
      // （負寸法を toImage に渡すと例外になる）。
      final bounds = ui.Rect.fromLTWH(
        0,
        0,
        source.width.toDouble(),
        source.height.toDouble(),
      );
      final srcRect = region.intersect(bounds);
      if (srcRect.isEmpty) {
        throw ArgumentError.value(region, 'region', 'is outside the image');
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        srcRect,
        ui.Rect.fromLTWH(
          0,
          0,
          srcRect.width * pixelScale,
          srcRect.height * pixelScale,
        ),
        ui.Paint(),
      );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(
          (srcRect.width * pixelScale).round(),
          (srcRect.height * pixelScale).round(),
        );
      } finally {
        picture.dispose();
      }
    } finally {
      source.dispose();
    }
  }

  /// エンコード済みバイト列をフルデコードして [ui.Image] を返す。
  Future<ui.Image> _decodeImage(Uint8List encodedImageBytes) async {
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(encodedImageBytes);
    } catch (error) {
      throw OcrEngineException('画像を読み込めませんでした。', cause: error);
    }
    try {
      final frame = await codec.getNextFrame();
      // WHY: FrameInfo.image の所有権は呼び出し側へ移る（Codec を dispose
      // しても Image の寿命には影響しない）。解放は _crop の finally が担う。
      return frame.image;
    } catch (error) {
      throw OcrEngineException('画像を読み込めませんでした。', cause: error);
    } finally {
      codec.dispose();
    }
  }

  /// 画像の寸法だけを読む（失敗は「寸法不明」として扱う）。
  ///
  /// WHY(失敗を握り潰すか): 寸法は正規化座標の補助情報であり、
  /// 認識自体が成功しているなら結果を捨てる理由にならない。
  /// [OcrPageResult.imageWidth] は null を許す。
  Future<(int, int)?> _tryDecodeSize(Uint8List encodedImageBytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(encodedImageBytes);
      image = (await codec.getNextFrame()).image;
      return (image.width, image.height);
    } on Exception {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 生 RGBA バイト列から [ui.Image] を構築する。
  ///
  /// WHY([ui.ImageDescriptor.raw] か): 二値化済みピクセルはエンコード形式
  /// ではないため、生ラスタとして構築する。全ピクセル alpha=255
  /// （[ContrastPreprocess] の契約）なので premultiply の多義性は無関係。
  static Future<ui.Image> _imageFromRgba(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  /// [image] を PNG バイト列にする（JS 側がそのまま食える形）。
  static Future<Uint8List> _encodePng(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw const OcrEngineException('画像を PNG に変換できませんでした。');
    }
    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  }

  /// 要素のテキストを行区切りで連結する。
  ///
  /// WHY(改行か): PaddleOCR の 1 要素は 1 行（検出した行をそのまま認識した
  /// もの）なので、行区切りが結果の構造を最もよく表す。ML Kit の
  /// `recognized.text` も行区切りである。
  static String _joinText(List<OcrElement> elements) =>
      elements.map((element) => element.text).join('\n');
}
