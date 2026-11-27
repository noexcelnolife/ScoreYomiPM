/// 実行環境に応じた組み立て口（条件付き export）。
///
/// WHY(条件付き export か): `main.dart` を「組み立て専用」に保ちつつ、
/// 端末固有の依存（path_provider・ファイルパス・ML Kit 周辺）を Web の
/// 依存グラフへ持ち込まないため。`dart:io` を含む実装はこの分岐の
/// 片側にしか現れない。
///
/// WHY(`dart.library.js_interop` か): Web 判定の鍵はプロジェクト内で
/// これに統一している。
library;

export 'app_environment_io.dart'
    if (dart.library.js_interop) 'app_environment_web.dart'
    show createAppEnvironment;
