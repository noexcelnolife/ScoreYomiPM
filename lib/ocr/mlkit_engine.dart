/// ML Kit Text Recognition v2 を使った [OcrEngine] 実装（spec.md §5.2, §7.1）。
///
/// フィールド別OCR戦略（spec.md §5.2）に対応できるよう、
/// 日本語（[MlKitScript.japanese]）と Latin（[MlKitScript.latin]）の
/// 2 スクリプトの recognizer を内部で扱える設計とする。
library;

import 'dart:io';
import 'dart:ui'
    as ui
    show
        Canvas,
        Image,
        ImageByteFormat,
        ImageDescriptor,
        ImmutableBuffer,
        Paint,
        PictureRecorder,
        PixelFormat,
        Rect,
        instantiateImageCodec;

// WHY: kDebugMode/debugPrint（フェーズ2-G の 3 区間コスト測定）と
// Uint8List（二値化前後のピクセルバッファ）のため。Uint8List は
// foundation 経由で再輸出される。
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/ocr_models.dart';
import 'contrast_preprocess.dart';
import 'ocr_engine.dart';

/// ML Kit で使用する認識スクリプトの指定。
///
/// - [japanese]: 日本語モデル → 曲名・ジャンル等の日本語フィールド（spec.md §5.2）
/// - [latin]: Latin モデル → スコア / 判定 / MAX COMBO / レベル等の数字フィールド（spec.md §5.2）
enum MlKitScript { japanese, latin }

/// [OcrEngine] の ML Kit 実装。
///
/// recognizer はスクリプトごとに遅延生成して再利用し、[dispose] で
/// 一括解放する（recognize のたびに生成/解放するとオーバーヘッドが大きい）。
class MlKitOcrEngine implements OcrEngine {
  /// [recognize] でスクリプトが指定されない場合に使うスクリプト。
  final MlKitScript defaultScript;

  final Map<MlKitScript, TextRecognizer> _recognizers = {};
  bool _disposed = false;

  /// 一時ファイル名の衝突を避けるための連番。
  int _tempSeq = 0;

  MlKitOcrEngine({this.defaultScript = MlKitScript.japanese});

  /// [script] を明示して認識を実行する。
  ///
  /// フィールド別OCR戦略（spec.md §5.2）では、数字フィールドに Latin、
  /// 曲名に日本語を使い分けるため、パイプライン側（ST-4）から
  /// スクリプトを指定して呼び出されることを想定している。
  Future<OcrPageResult> recognizeWithScript(
    File imageFile,
    MlKitScript script,
  ) async {
    if (_disposed) {
      throw StateError('MlKitOcrEngine has already been disposed.');
    }
    if (!imageFile.existsSync()) {
      throw OcrEngineException('Image file not found: ${imageFile.path}');
    }

    final recognizer = _recognizerFor(script);
    try {
      final dims = await _decodeImageSize(imageFile);
      final inputImage = InputImage.fromFilePath(imageFile.path);
      final recognized = await recognizer.processImage(inputImage);
      return _toPageResult(
        recognized,
        imageWidth: dims.$1,
        imageHeight: dims.$2,
      );
    } on Exception catch (e) {
      throw OcrEngineException(
        'ML Kit text recognition failed ($script): $e',
        cause: e,
      );
    }
  }

  /// WHY(バイト列を受けて一時ファイルへ書くか): [OcrEngine] の契約は
  /// プラットフォーム非依存のバイト列入力になった（保存先が端末のディスクでも
  /// ブラウザの IndexedDB でも同じ経路を通すため）。一方、ML Kit への画素の
  /// 渡し方は `InputImage.fromFilePath` のまま据え置く。この経路は回転・
  /// バイト整列の実績があり、`fromBytes` を避ける決定が既にされている
  ///（本ファイル下部の一時 PNG 経由の WHY、および
  /// docs/st5_f2_g_contrast_preprocess_design_confirmation_2026-11-22.md）。
  /// 変えるのは「入力の受け渡し」だけで、認識の品質に関わる部分は変えない。
  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) {
    return _withTempSource(
      encodedImageBytes,
      (File source) => recognizeWithScript(source, defaultScript),
    );
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    ui.Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) {
    return _withTempSource(
      encodedImageBytes,
      (File source) async {
        try {
          return await _recognizeRegionFromFile(
            source,
            region,
            script: script,
            pixelScale: pixelScale,
            contrastRetry: contrastRetry,
          );
        } on OcrEngineException {
          rethrow;
        } on Exception catch (error) {
          // WHY(包むか): [OcrEngine] の契約は「失敗は OcrEngineException」。
          // 呼び出し側はそれだけを捕まえて未確定レコード保存に倒すため、
          // 素の例外を漏らすと復旧経路に入らず記録が失われる。
          throw OcrEngineException('ML Kit region recognition failed: $error');
        }
      },
    );
  }

  /// クロップ再認識の本体（旧 `recognizeRegion` の実装）。
  ///
  /// WHY(File のまま残すか): クロップは元画像をデコードして描画する必要があり、
  /// ML Kit へ渡すのもファイル経路である。バイト列化するのは公開境界だけで
  /// 十分（KISS）。呼び出し元は [recognizeRegion] のみ。
  Future<OcrPageResult> _recognizeRegionFromFile(
    File imageFile,
    ui.Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    bool contrastRetry = false,
  }) async {
    if (_disposed) {
      throw StateError('MlKitOcrEngine has already been disposed.');
    }
    if (!imageFile.existsSync()) {
      throw OcrEngineException('Image file not found: ${imageFile.path}');
    }
    final cropped = await _crop(imageFile, region, pixelScale);
    final tempDir = await Directory.systemTemp.createTemp('scoreyomipm_ocr');
    try {
      final tempFile = await _writeTempPng(cropped, tempDir);
      final firstStopwatch = Stopwatch()..start();
      final first = await recognizeWithScript(tempFile, _toMlKitScript(script));
      firstStopwatch.stop();
      // WHY 発火条件: 二値化再試行は「0 要素」のときに限る（設計確認書
      // 18b2111 §2・リード承認）。常時前置きは成功経路のコストを増やす
      // だけでなく、r6 で前処理なし復帰済みの 23bjim/124356 等の成功入力を
      // 変える（構造的非回帰に反する）ため棄却した。
      if (!contrastRetry || first.elements.isNotEmpty) {
        return first;
      }
      // WHY: 縮退（単色等）で再試行不能な場合は 1 次結果をそのまま返す
      // （再試行は 1 次より悪くしない。結果のマージはしない＝置換のみ）。
      final retried = await _retryWithContrast(
        cropped,
        tempDir,
        script,
        first,
        firstStopwatch.elapsed,
      );
      return retried ?? first;
    } finally {
      // WHY: クロップ用一時ディレクトリは認識完了の成否にかかわらず即座に
      // 削除する（一時領域への蓄積を防ぐ。認識エラー時も原因調査には
      // 例外メッセージで十分）。Windows ではウイルススキャナ等で一時的に
      // ロックされ削除に失敗し得るため、失敗は握り潰す（結果に影響しない）。
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 削除失敗は認識結果に影響しないため無視する。
      }
      cropped.dispose();
    }
  }

  /// 0 要素時の二値化前処理付き再 OCR（フェーズ2-G・18b2111 §3）。
  ///
  /// [cropped] の生 RGBA を大津二値化した新しい画像を作り直し、同じ一時
  /// ディレクトリに PNG を書き出して 2 回目の認識を実行する。
  /// 縮退（単色等）で [ContrastPreprocess.binarize] が null を返した場合は
  /// 再試行せず null を返し、呼び出し側が 1 次結果を返す。
  ///
  /// WHY: かつてこの直後にあった 3/4 次チェーン（4:3 パッド → 同パッド
  /// Japanese → 同パッド Latin・59670d7 設計 / ceefd5d 実装）は r8 計測
  /// （1891a04）で有効決定 0/4・コスト見積 2.74 倍・パッド後座標汚染と
  /// スプリアス照合の副作用が確認され、ST-5 改善ライン v1 打ち止め裁定
  /// （01a2036e）により剥離した。binarize 第 2 段は r7 検収裁定（着地維持・
  /// 結果ゼロ効果）どおり維持する。再開時は 59670d7 + 1891a04 + ceefd5d
  /// の履歴で復元可能。
  Future<OcrPageResult?> _retryWithContrast(
    ui.Image cropped,
    Directory tempDir,
    OcrScript script,
    OcrPageResult firstResult,
    Duration firstDuration,
  ) async {
    // WHY rawRgba: 二値化の入力は生 RGBA（1 ピクセル 4 バイト）。エンコード
    // 済み形式（PNG 等）はデコードし直しが要るため使わない。cropped 自体は
    // 呼び出し側 finally が dispose するので、ここでは読み取りのみ。
    final rawBytes = await cropped.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (rawBytes == null) {
      return null;
    }
    final preprocessStopwatch = Stopwatch()..start();
    final binarized = ContrastPreprocess.binarize(
      rawBytes.buffer.asUint8List(),
      cropped.width,
      cropped.height,
    );
    preprocessStopwatch.stop();
    if (binarized == null) {
      return null;
    }
    final retryImage = await _imageFromRgba(
      binarized,
      cropped.width,
      cropped.height,
    );
    try {
      final tempFile = await _writeTempPng(retryImage, tempDir);
      final retryStopwatch = Stopwatch()..start();
      final second = await recognizeWithScript(
        tempFile,
        _toMlKitScript(script),
      );
      retryStopwatch.stop();
      // WHY: 3 区間（1次検出/前処理/2次検出）を 1 行で出す（18b2111 §6 の
      // コスト測定。kDebugMode ガードで release ではコストゼロ）。
      if (kDebugMode) {
        debugPrint(
          '[ocr] contrastRetry(first=${firstResult.elements.length} el): '
          'detect=${firstDuration.inMilliseconds}ms '
          'preprocess=${preprocessStopwatch.elapsed.inMilliseconds}ms '
          'retry=${retryStopwatch.elapsed.inMilliseconds}ms',
        );
      }
      return second;
    } finally {
      retryImage.dispose();
    }
  }

  /// 生 RGBA バイト列から [ui.Image] を構築する。
  ///
  /// WHY: 二値化済みピクセルは生バイト（エンコード形式でない）のため、
  /// [ImageDescriptor.raw]（rgba8888）でラスタとして構築する。再エンコード
  /// せずに認識へ渡す（18b2111 §1 の fromBytes 不採用理由に基づく
  /// PNG ファイル経路は [_writeTempPng] が担うため、ここでは生ラスタのみ）。
  /// 全ピクセル alpha=255（[ContrastPreprocess] の契約）のため premultiply
  /// の多義性は実質無関係。
  Future<ui.Image> _imageFromRgba(Uint8List rgba, int width, int height) async {
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
      // WHY: FrameInfo.image の所有権は呼び出し側へ移る（_decodeImage と
      // 同一の契約）。解放は _retryWithContrast の finally で行う。
      return frame.image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  /// [imageFile] をデコードし、[region] を [pixelScale] 倍に拡大して
  /// クロップした [ui.Image] を返す。
  ///
  /// WHY 拡大: 小さい白文字（判定数値）は ML Kit のテキスト検出の下限を
  /// 下回り、等倍クロップでは 1 要素も検出されないことがある（Wave 2
  /// 初回計測の知見）。拡大して文字の絶対高さを稼ぐ。
  ///
  /// WHY: ML Kit への入力は PNG ファイル経由とする。toByteData が返すのは
  /// エンコード済み PNG で、InputImage.fromBytes が要求するのは生 RGBA/NV21
  /// であり形式が合わない（変換コードの新規実装は回転・バイト整列の
  /// 落とし穴がある）。一時 PNG ファイル経由なら recognizeWithScript の
  /// 既存経路（存在確認・例外ラップ・confidence 変換）をそのまま再利用
  /// できる（KISS・新依存なし）。
  Future<ui.Image> _crop(
    File imageFile,
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
    final source = await _decodeImage(imageFile);
    try {
      // WHY: ラベル bbox から算出した領域はマージン加算等で画像境界を
      // 数 px はみ出すことがある。余白を殺すよりはみ出し分を切り捨てる
      // 方が安全（toImage に負寸法を渡すと例外になるため clamp が必須）。
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
      final cropped = await picture.toImage(
        (srcRect.width * pixelScale).round(),
        (srcRect.height * pixelScale).round(),
      );
      picture.dispose();
      return cropped;
    } finally {
      source.dispose();
    }
  }

  /// 一時ソースファイルを作って [body] に渡し、終わったら必ず消す。
  ///
  /// WHY(毎回作って消すか): 認識は同時に 1 件しか走らず（1 記録 = 1 画像）、
  /// 使い回すと前の画像が残って容量を食う。消し漏れより作り直しの方が安い。
  Future<T> _withTempSource<T>(
    Uint8List encodedImageBytes,
    Future<T> Function(File source) body,
  ) async {
    // WHY(dispose 判定を先に置くか): 一時ファイルの書き出しは副作用（ディスク
    // 占有）なので、破棄済みエンジンには起こさせない。どの失敗より先に弾く。
    if (_disposed) {
      throw StateError('MlKitOcrEngine has already been disposed.');
    }
    if (encodedImageBytes.isEmpty) {
      throw OcrEngineException('Empty image bytes passed to ML Kit engine.');
    }
    final File source = await _writeTempSource(encodedImageBytes);
    try {
      return await body(source);
    } finally {
      await _deleteQuietly(source);
    }
  }

  /// 認識対象のバイト列を一時ファイルへ書く。
  ///
  /// WHY(拡張子を付けないか): ML Kit はファイル内容で形式を判定するため、
  /// 拡張子は認識結果に影響しない。付け間違えた名前を残すと、
  /// ログを読む人が形式を誤解するので、形式を主張しない名前にする。
  Future<File> _writeTempSource(Uint8List encodedImageBytes) async {
    final File file = File(
      '${Directory.systemTemp.path}/scoreyomipm_ocr_src_${_tempSeq++}.img',
    );
    await file.writeAsBytes(encodedImageBytes, flush: true);
    return file;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      // WHY(握りつぶすか): 一時ファイルが残るだけで認識結果は変わらない。
      // ここで例外を投げると、成功した認識を失敗として扱ってしまう。
      debugPrint('[ocr] failed to delete temp file: $error');
    }
  }


  ///
  /// WHY(元画像名を使わないか): 入力はバイト列になり、元のファイル名が
  /// 失われた。名前に意味を持たせず連番にして、追跡はログ側の
  /// リクエスト ID に任せる。
  Future<File> _writeTempPng(ui.Image image, Directory tempDir) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw OcrEngineException('Failed to encode cropped image to PNG.');
    }
    final tempFile = File('${tempDir.path}/retry_${_tempSeq++}.png');
    await tempFile.writeAsBytes(byteData.buffer.asUint8List());
    return tempFile;
  }

  /// [imageFile] をフルデコードして [ui.Image] を返す。
  ///
  /// WHY: クロップの描画にはピクセルデータが必須のため
  /// [ui.ImageDescriptor] のヘッダ読み出しでは足りない（寸法取得と異なる）。
  Future<ui.Image> _decodeImage(File imageFile) async {
    final codec = await ui.instantiateImageCodec(await imageFile.readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      // WHY: FrameInfo.image の所有権は呼び出し側へ移る（Codec を dispose
      // しても Image の寿命には影響しないため、ここでは image を返し、
      // 解放は _crop の finally に任せる）。
      return image;
    } finally {
      codec.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // WHY: close() は platform channel 経由の非同期解放。await せずに
    // ループ内で投げっぱなしにすると、呼び出し元（テストやパイプライン）
    // が dispose の完了を正しく把握できず、解放用 Future が未完了のまま
    // 破棄されてリソース解放の成否を検証できなくなる。そのため 1 件ずつ
    // 待ってからマップをクリアする。
    for (final recognizer in _recognizers.values) {
      try {
        await recognizer.close();
      } on Exception {
        // WHY: 解放失敗を握り潰す。dispose で例外を投げても呼び出し側に
        // 回復手段はなく、flutter test（プラグイン未初期化環境）では
        // close が常に失敗するため、ユニットテストの実行可能性のために
        // も無視する。未解放になってもリークは recognizer 数個どまりで
        // アプリ終了時に回収される。
      }
    }
    _recognizers.clear();
  }

  /// スクリプトに対応する recognizer を遅延生成して返す。
  TextRecognizer _recognizerFor(MlKitScript script) {
    return _recognizers.putIfAbsent(
      script,
      () => TextRecognizer(script: _toNativeScript(script)),
    );
  }

  static TextRecognitionScript _toNativeScript(MlKitScript script) {
    switch (script) {
      case MlKitScript.japanese:
        return TextRecognitionScript.japanese;
      case MlKitScript.latin:
        return TextRecognitionScript.latin;
    }
  }

  /// 抽象契約のスクリプト指定を ML Kit 実装のスクリプトへ変換する。
  ///
  /// WHY: [OcrScript] は engine 非依存の意図（数値列 / 曲名帯）。
  /// 実装型（[MlKitScript]）を抽象へ漏らさないための変換層（DIP）。
  static MlKitScript _toMlKitScript(OcrScript script) {
    switch (script) {
      case OcrScript.latin:
        return MlKitScript.latin;
      case OcrScript.japanese:
        return MlKitScript.japanese;
    }
  }

  /// ML Kit の結果構造（block → line → element）を共通モデルに変換する。
  ///
  /// 要素単位（≒単語）で [OcrElement] を生成する。element が空の line
  /// （日本語テキストで発生し得る）は line 全体を 1 要素として扱う。
  /// confidence は Android のみ提供されるため、取得できない場合は
  /// 親 line の値を、それも無ければ [OcrElement.confidenceUnknown] を使う。
  ///
  /// 画像寸法は engine がここで設定する（正規化座標変換の単一情報源。
  /// [OcrPageResult.imageWidth] の doc 参照）。
  static OcrPageResult _toPageResult(
    RecognizedText result, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final elements = <OcrElement>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final lineConfidence = line.confidence;
        if (line.elements.isEmpty) {
          elements.add(
            OcrElement(
              text: line.text,
              boundingBox: line.boundingBox,
              confidence: lineConfidence ?? OcrElement.confidenceUnknown,
            ),
          );
          continue;
        }
        for (final element in line.elements) {
          elements.add(
            OcrElement(
              text: element.text,
              boundingBox: element.boundingBox,
              confidence:
                  element.confidence ??
                  lineConfidence ??
                  OcrElement.confidenceUnknown,
            ),
          );
        }
      }
    }
    return OcrPageResult(
      elements: elements,
      fullText: result.text,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }

  /// 画像ファイルからピクセルデコードなしで寸法のみを読み出す。
  ///
  /// WHY: [InputImage.fromFilePath] は画像寸法を公開しないため、正規化座標
  /// 変換（FieldExtractor）に必要な寸法を別途取得する。案としていた
  /// [ui.instantiateImageCodec] によるフルデコードではなく、エンコード画像の
  /// ヘッダのみを読む [ui.ImageDescriptor.encoded] を使い、寸法取得のための
  /// ピクセル decode コストを回避する（フレームは使わないため）。
  static Future<(int, int)> _decodeImageSize(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return (descriptor.width, descriptor.height);
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
