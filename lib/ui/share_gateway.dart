import 'dart:typed_data';

/// プラットフォーム固有の [ImageShareGateway] 実装をエクスポートする。
///
/// WHY(条件付きエクスポート): `dart:io` は Web でもコンパイルは通るが実行時に
/// `UnsupportedError` を出す。io プラットフォームでは `share_gateway_io.dart` を、
/// Web プラットフォームでは `share_gateway_web.dart` を使い分ける。
/// UI 側は `PlatformImageShareGateway()` を書くだけで、`kIsWeb` 分岐を書かなくて済む。
export 'share_gateway_io.dart' if (dart.library.js_interop) 'share_gateway_web.dart';

/// 原画像を端末の共有シートへ渡す境界。
///
/// WHY 画面から切り離すか: 共有シートはプラットフォームチャネルを使うため
/// widget テストから直接呼べない。[FileExportGateway] と同じ方針で、
/// 「何を共有するか」は画面が決め、「どう共有するか」は差し替え可能にする。
abstract class ImageShareGateway {
  /// [bytes] を [fileName] という名前で共有する。
  ///
  /// WHY 共有の成否を返さないか: Android の共有結果は「シートで何かを選んだか」
  /// しか分からず、実際に相手へ渡ったかは保証されない。成功を名乗らないため
  /// 戻り値を持たない（利用者のキャンセルも同じ扱い）。
  Future<void> shareImage({required Uint8List bytes, required String fileName});
}
