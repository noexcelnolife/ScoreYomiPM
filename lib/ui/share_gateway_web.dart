// Web 向けの [ImageShareGateway]（dart:js_interop プラットフォーム専用）。
//
// このファイルは `share_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは dart:io が実行時に UnsupportedError を出すため、
// `navigator.share` を使わず、ブラウザダウンロードに一本化する。
//
// dart:html を使う理由（package:web ではなく）: Tier A は --wasm ビルドを対象外にしているため、
// dart:html の利用は許容される（計画 D11）。--wasm に移行する際は package:web への移行が必要。

import 'dart:html' as html;
import 'dart:typed_data';

import 'share_gateway.dart';

/// Web ブラウザ向けの [ImageShareGateway]。
class PlatformImageShareGateway implements ImageShareGateway {
  const PlatformImageShareGateway();

  // DEVIATION(Web Share API を使わない): navigator.share に files: を渡すには
  // DOM の File オブジェクトを dart:js_interop で橋渡しする必要があり、型の整合を
  // ブラウザで検証するコストが高い。ボタンの目的（画像をアプリの外へ出す）は
  // ダウンロードで満たせるため、navigator.share を使わずダウンロード固定にする。
  //
  // 代替: AnchorElement.download によるブラウザダウンロード。
  // 再検討条件: `--wasm` ビルド対応時に package:web を導入し、型安全な File ブリッジを
  // 実装できた場合、navigator.share の復活を検討する。

  @override
  Future<void> shareImage({
    required Uint8List bytes,
    required String fileName,
  }) async {
    // ダウンロード固定。navigator.share は使わない（上記 DEVIATION 参照）。
    final blob = html.Blob([bytes], 'application/octet-stream');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();

    // WHY(revokeObjectUrl のタイミング): click() の直後に revoke すると、
    // ブラウザ（Firefox / Safari 等）によってはダウンロードが始まる前に URL が無効化され失敗する。
    // 次のイベントループに譲ってから revoke する。
    await Future<void>.delayed(const Duration(seconds: 1));
    html.Url.revokeObjectUrl(url);
  }
}
