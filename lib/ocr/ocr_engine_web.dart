// ブラウザ版の [OcrEngine] 実装（PaddleOCR.js + ONNX Runtime Web）。
//
// WHY(この 1 ファイルに JS を閉じ込めるか): `dart:js_interop` は Web 以外の
// ターゲットでコンパイルできない。`ocr_engine_factory.dart` の条件 import で
// **Web ビルドにだけ**このファイルを混ぜ、上位（UI・パイプライン）からは
// JS の存在を消す。ここより外に `JSAny` も `document` も出さない。

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:web/web.dart' as web;

import '../models/ocr_models.dart';
import 'ocr_engine.dart';
import 'paddle_ocr_engine.dart';

/// 同梱物の置き場所。`web/ocr_vendor/` が `build/web/ocr_vendor/` へ
/// そのままコピーされる（`tool/ocr_vendor/build.mjs` が生成元）。
const String _vendorDirectory = 'ocr_vendor/';

/// esbuild の成果物。PaddleOCR.js と ONNX Runtime Web を 1 つに束ねたもの。
const String _bundleFileName = 'paddleocr.bundle.js';

/// 検出モデル（文字の位置を出す）。
const String _detectionModelName = 'PP-OCRv5_mobile_det';

/// 認識モデル（切り出した行を文字にする）。
const String _recognitionModelName = 'PP-OCRv5_mobile_rec';

/// モデルの同梱パス（`_vendorDirectory` からの相対）。
const String _detectionModelFile = 'models/PP-OCRv5_mobile_det.tar';
const String _recognitionModelFile = 'models/PP-OCRv5_mobile_rec.tar';

/// `globalThis` に公開されたモジュール名前空間の名前。
///
/// WHY(名前空間を Dart が読むのか): `<script type="module">` の評価結果は
/// ページの外へ出てこない。バンドル自身が `globalThis.ScoreYomiOcr` に
/// 生やすことで、Dart は「読み込み完了」だけを待って中身を掴める。
const String _moduleGlobalName = 'ScoreYomiOcr';

/// Web 用の [OcrEngine] を作る。
///
/// WHY(ここで何もしないか): エンジンの生成（＝約 68MB の同梱物の取得）を
/// 起動時に行うと、画像を取り込むつもりの無い利用者にも初回表示の待ち時間を
/// 負わせる。最初の [OcrEngine.recognize] まで何も取りに行かない。
OcrEngine createOcrEngine() => PaddleOcrEngine(PaddleJsOcrClient());

/// `globalThis.ScoreYomiOcr.PaddleOCR` を呼ぶ [PaddleOcrClient]。
class PaddleJsOcrClient extends PaddleOcrClient {
  /// 初期化の共有 Future。
  ///
  /// WHY(1 本に畳むか): モデル読み込みは 20 秒近くかかることがあり、
  /// 同時に 2 本走らせると同じ 21MB を二重に取りに行く。
  Future<JSObject>? _engineFuture;

  /// バンドルの読み込み（`<script>` 注入）。
  Future<void>? _moduleLoadFuture;

  /// 一度でも初期化に成功したか。
  bool _initialized = false;

  /// 初回の読み込みがまだ完了していないか。
  ///
  /// WHY(「進行中」ではなく「未完了」か): 読み込みの開始は OCR 実行の内側
  /// （最初の [detect]）で起きるため、UI が「開始した」瞬間を観測できない。
  /// UI は実行開始時に 1 度だけ状態を読むので、観測できるのは「まだ完了して
  /// いない」ことだけである。初期化に失敗した場合も false のままなので、
  /// 次の再試行でも同じ案内が出る（実際に取り直す）。
  @override
  bool get isPreparing => !_initialized;

  @override
  Future<List<OcrElement>> detect(Uint8List encodedImageBytes) async {
    if (encodedImageBytes.isEmpty) {
      throw const OcrEngineException('空の画像データが OCR に渡されました。');
    }
    final engine = await _engine();
    final blob = web.Blob(
      <JSAny>[encodedImageBytes.toJS].toJS,
      web.BlobPropertyBag(type: _mimeTypeOf(encodedImageBytes)),
    );
    final JSAny? results;
    try {
      final promise = engine.callMethod<JSPromise<JSAny?>>('predict'.toJS, blob);
      results = await promise.toDart;
    } catch (error) {
      throw OcrEngineException('ブラウザ版の文字認識に失敗しました。', cause: error);
    }
    return _elementsOf(results);
  }

  @override
  Future<void> dispose() async {
    final pending = _engineFuture;
    _engineFuture = null;
    _moduleLoadFuture = null;
    if (pending == null) return;
    try {
      final engine = await pending;
      final result = engine.callMethod<JSAny?>('dispose'.toJS);
      // WHY(戻り値の型を決め打ちしないか): PaddleOCR.js の dispose は
      // Promise を返す版と何も返さない版がありうる。Promise のときだけ待つ。
      if (result != null && result.isA<JSPromise<JSAny?>>()) {
        await (result as JSPromise<JSAny?>).toDart;
      }
    } on Exception {
      // WHY(握り潰すか): 解放失敗に呼び出し側の回復手段は無い。
    }
  }

  /// 初期化済みエンジンを取り出す（初回だけ生成する）。
  Future<JSObject> _engine() {
    final pending = _engineFuture;
    if (pending != null) return pending;
    final future = _createEngine();
    _engineFuture = future;
    // WHY(失敗したら捨てるか): 同じ Future を握り続けると、一度の通信失敗で
    // そのセッション中ずっと復帰できなくなる。次の呼び出しで作り直す。
    unawaited(
      future.then<void>(
        (_) => _initialized = true,
        onError: (Object _) {
          _engineFuture = null;
        },
      ),
    );
    return future;
  }

  /// バンドルの読み込みと [JSObject]（エンジン）の生成。
  Future<JSObject> _createEngine() async {
    await _ensureModuleLoaded();
    final JSAny? module = globalContext[_moduleGlobalName];
    if (module == null || !module.isA<JSObject>()) {
      throw const OcrEngineException(
        'ブラウザ版の読み取りエンジンを初期化できませんでした。',
      );
    }
    final JSAny? classObject = (module as JSObject)['PaddleOCR'];
    if (classObject == null || !classObject.isA<JSObject>()) {
      throw const OcrEngineException(
        'ブラウザ版の読み取りエンジンを初期化できませんでした。',
      );
    }
    try {
      final promise = (classObject as JSObject).callMethod<JSPromise<JSAny?>>(
        'create'.toJS,
        _initOptions(),
      );
      final JSAny? engine = await promise.toDart;
      if (engine == null || !engine.isA<JSObject>()) {
        throw const OcrEngineException(
          'ブラウザ版の読み取りエンジンを初期化できませんでした。',
        );
      }
      return engine as JSObject;
    } on OcrEngineException {
      rethrow;
    } catch (error) {
      // WHY(ここで包むか): 通信失敗・WASM 初期化失敗・モデル破損はすべて
      // 同じ利用者向けの意味（「読み込めなかった」）に落ちる。
      throw OcrEngineException(
        'ブラウザ版の読み取りエンジンを読み込めませんでした。通信状態を確認してください。',
        cause: error,
      );
    }
  }

  /// `<script type="module">` を 1 回だけ注入し、読み込み完了を待つ。
  Future<void> _ensureModuleLoaded() {
    final pending = _moduleLoadFuture;
    if (pending != null) return pending;
    final future = _loadModule();
    _moduleLoadFuture = future;
    // WHY(失敗したら捨てるか): 読み込み失敗後に `onload` を待ち続ける Future を
    // 残すと、再試行が永久に失敗する。次回にもう一度注入し直す。
    unawaited(
      future.catchError((Object _) {
        _moduleLoadFuture = null;
      }),
    );
    return future;
  }

  Future<void> _loadModule() async {
    // 同一ページ内で 2 度目（dispose 後の再生成など）は script を足さない。
    if (globalContext.has(_moduleGlobalName)) {
      return;
    }
    final completer = Completer<void>();
    final script =
        web.document.createElement('script') as web.HTMLScriptElement
          ..type = 'module'
          ..src = _vendorUrl(_bundleFileName);
    // WHY(onerror も見るか): 404 や MIME 不正は `onload` が来ないまま
    // 何も起きない。放置すると UI が「読み込み中」で固まる。
    script.onload = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    script.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          const OcrEngineException(
            'ブラウザ版の読み取りエンジンを読み込めませんでした。通信状態を確認してください。',
          ),
        );
      }
    }).toJS;
    final parent = web.document.head ?? web.document.body;
    if (parent == null) {
      throw const OcrEngineException('読み取りエンジンを差し込む場所がありません。');
    }
    parent.append(script);
    await completer.future;
  }

  /// `PaddleOCR.create` に渡す設定。
  ///
  /// 引数の意味と値は実測で確定させたもの（OCR-B / OCR-E）。
  JSObject _initOptions() {
    final ortOptions = JSObject()
      ..setProperty('backend'.toJS, 'wasm'.toJS)
      // WHY(ディレクトリ URL を渡すか): ONNX Runtime はこの接頭辞に
      // `ort-wasm-simd-threaded.jsep.{mjs,wasm}` を足して取りに行く。
      ..setProperty('wasmPaths'.toJS, _vendorUrl('').toJS)
      // WHY(numThreads: 1 か): 2 以上にすると SharedArrayBuffer が要り、
      // COOP/COEP ヘッダを付けられない静的ホスティング（GitHub Pages）で
      // 初期化に失敗する。速度より「どこでも動く」を優先する。
      ..setProperty('numThreads'.toJS, 1.toJS);

    return JSObject()
      ..setProperty('worker'.toJS, true.toJS)
      ..setProperty('initialize'.toJS, true.toJS)
      ..setProperty('ortOptions'.toJS, ortOptions)
      ..setProperty('textDetectionModelName'.toJS, _detectionModelName.toJS)
      ..setProperty('textDetectionModelAsset'.toJS, _modelAsset(_detectionModelFile))
      ..setProperty('textRecognitionModelName'.toJS, _recognitionModelName.toJS)
      ..setProperty('textRecognitionModelAsset'.toJS, _modelAsset(_recognitionModelFile));
  }

  /// `{url: <絶対 URL>}`。
  JSObject _modelAsset(String relativePath) =>
      JSObject()..setProperty('url'.toJS, _vendorUrl(relativePath).toJS);

  /// `predict` の戻り値（`OcrResult[]`）を [OcrElement] の列にする。
  List<OcrElement> _elementsOf(JSAny? rawResults) {
    if (rawResults == null || !rawResults.isA<JSArray<JSAny?>>()) {
      return const <OcrElement>[];
    }
    final elements = <OcrElement>[];
    for (final rawResult in (rawResults as JSArray<JSAny?>).toDart) {
      if (!rawResult.isA<JSObject>()) continue;
      final JSAny? items = (rawResult as JSObject)['items'];
      if (items == null || !items.isA<JSArray<JSAny?>>()) continue;
      for (final rawItem in (items as JSArray<JSAny?>).toDart) {
        final element = _toElement(rawItem);
        if (element != null) elements.add(element);
      }
    }
    return elements;
  }

  /// 1 要素（`{poly, text, score}`）を [OcrElement] にする。
  ///
  /// WHY(poly から矩形を作るか): PaddleOCR.js は 4 点の多角形だけを返し、
  /// 軸平行の矩形は返さない。頂点の並び順（左上→右上→右下→左下）に依存すると
  /// 斜体や回転で壊れるため、x/y の最小最大から包絡矩形を作る。
  OcrElement? _toElement(JSAny? rawItem) {
    if (rawItem == null || !rawItem.isA<JSObject>()) return null;
    final item = rawItem as JSObject;
    final text = _stringOf(item['text']);
    // WHY(空文字を捨てるか): 検出だけされて認識が空になった行は、
    // 要素数の水増しにしかならず、`fullText` に空行を混ぜる。
    if (text.isEmpty) return null;
    final box = _boundingBoxOf(item['poly']);
    if (box == null) return null;
    return OcrElement(
      text: text,
      boundingBox: box,
      // WHY(不明を -1 にするか): スコアが無いことは「0 点」ではなく
      // 「不明」である。0 と区別できる負値を契約（confidenceUnknown）に従って使う。
      confidence: _numberOf(item['score']) ?? OcrElement.confidenceUnknown,
    );
  }

  /// 多角形（4 点以上）を包む軸平行矩形にする。
  ///
  /// 頂点の表現は 2 通りある。実測（PaddleOCR.js 0.4.2）では
  /// `[[x, y], [x, y], [x, y], [x, y]]` の**配列**だったが、型定義は
  /// `Point2D`（`{x, y}`）を想定している。どちらでも壊れないように両方を受ける。
  Rect? _boundingBoxOf(JSAny? rawPoly) {
    if (rawPoly == null || !rawPoly.isA<JSArray<JSAny?>>()) return null;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var count = 0;
    for (final rawPoint in (rawPoly as JSArray<JSAny?>).toDart) {
      final (double, double)? point = _pointOf(rawPoint);
      if (point == null) continue;
      final (double x, double y) = point;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      count++;
    }
    if (count == 0) return null;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 1 頂点を (x, y) にする。`[x, y]` と `{x, y}` の両方を受ける。
  static (double, double)? _pointOf(JSAny? rawPoint) {
    if (rawPoint == null) return null;
    if (rawPoint.isA<JSArray<JSAny?>>()) {
      final List<JSAny?> values = (rawPoint as JSArray<JSAny?>).toDart;
      if (values.length < 2) return null;
      final double? x = _numberOf(values[0]);
      final double? y = _numberOf(values[1]);
      if (x == null || y == null) return null;
      return (x, y);
    }
    if (rawPoint.isA<JSObject>()) {
      final JSObject point = rawPoint as JSObject;
      final double? x = _numberOf(point['x']);
      final double? y = _numberOf(point['y']);
      if (x == null || y == null) return null;
      return (x, y);
    }
    return null;
  }

  static String _stringOf(JSAny? value) {
    if (value == null || !value.isA<JSString>()) return '';
    return (value as JSString).toDart;
  }

  static double? _numberOf(JSAny? value) {
    if (value == null || !value.isA<JSNumber>()) return null;
    return (value as JSNumber).toDartDouble;
  }
}

/// 同梱物の絶対 URL を作る。
///
/// WHY(絶対 URL か): 素の相対パスは、読み込んだ ES モジュールや
/// worker の**基底 URL** を基準に解決される。worker は
/// `/ocr_vendor/assets/` から起動するため、`ocr_vendor/models/...` のような
/// 相対指定は `/ocr_vendor/assets/ocr_vendor/models/...` になって 404 になる。
/// Dart 側で `Uri.base` から解決しておけば、どこから fetch しても同じ場所を指す。
String _vendorUrl(String relativePath) =>
    Uri.base.resolve('$_vendorDirectory$relativePath').toString();

/// エンコード済み画像の MIME タイプを先頭バイトから判定する。
///
/// WHY(拡張子ではなく中身か): 利用者が選ぶファイルの拡張子は信用できない
/// （`image.jpg` の中身が PNG など）。Blob の type は、ブラウザが画像として
/// 解釈する際の手がかりにしかならないが、間違っていると解釈自体に失敗する。
String _mimeTypeOf(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'image/bmp';
  }
  // WHY(既定を octet-stream にしないか): 未知の形式でもブラウザに
  // 中身から判定させる余地を残すより、画像として扱わせた方が失敗が早い。
  return 'image/*';
}
