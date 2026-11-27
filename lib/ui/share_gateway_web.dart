// Web 向けの [ImageShareGateway]（dart:js_interop プラットフォーム専用）。
//
// このファイルは `share_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは dart:io が実行時に UnsupportedError を出すため、
// `navigator.share` を試し、非対応ならブラウザダウンロードにフォールバックする。

import 'dart:html' as html;
import 'dart:typed_data';

import 'share_gateway.dart';

/// Web ブラウザ向けの [ImageShareGateway]。
class PlatformImageShareGateway implements ImageShareGateway {
  const PlatformImageShareGateway();

  @override
  Future<void> shareImage({
    required Uint8List bytes,
    required String fileName,
  }) async {
    // WHY(navigator.share 優先): Web Share API があればネイティブの共有シートが開き、
    // ユーザーに送信先を選ばせられる。対応していなければダウンロードにフォールバック。
    // `dart:html` の `Navigator` には `share` プロパティが定義されていないため、
    // `dynamic` キャストで実行時に解決する。
    final navigator = html.window.navigator as dynamic;
    final share = navigator.share;
    if (share != null) {
      try {
        await share(<String, dynamic>{
          'title': 'スコアヨミPM',
          'text': fileName,
        });
        return;
      } catch (_) {
        // 共有がキャンセルされたか失敗した場合はダウンロードへフォールバック。
      }
    }

    // WHY(フォールバック): navigator.share が無いかエラーなら、ブラウザダウンロードを代替する。
    final blob = html.Blob([bytes], 'application/octet-stream');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }
}
