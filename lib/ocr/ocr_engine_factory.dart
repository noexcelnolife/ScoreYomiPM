/// 実行環境に応じた [OcrEngine] の生成口（条件付き export）。
///
/// WHY(条件付き export か): `main.dart` はコンポジションルートとして
/// エンジンの生成を 1 箇所に集めるが、Web では ML Kit が存在しない。
/// 呼び出し側に分岐を書かせず、プラットフォーム判定をこの 1 ファイルに閉じる。
///
/// WHY(`dart.library.js_interop` か): Web 判定の鍵はプロジェクト内で
/// `dart.library.js_interop` に統一している（`dart.library.html` は
/// `package:web` への移行後は Web 以外でも真になり得る）。
library;

export 'ocr_engine_io.dart'
    if (dart.library.js_interop) 'ocr_engine_web.dart'
    show createOcrEngine;
