// ブラウザのダウンロードを起こす共通処理（Web ビルド専用）。
//
// WHY(切り出すか): Web では「アプリ外に保存」も「共有」も同じ結果になる
// （ファイルのダウンロード）。Blob と anchor の組み立てを 2 か所に書くと、
// URL の解放タイミングなどを片方だけ直して挙動がずれる。

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// [bytes] を [fileName] としてブラウザのダウンロードに流す。
///
/// WHY(戻り値を持たないか): ブラウザはダウンロードの成否も開始も通知しない。
/// 「要求した」以上のことは言えないため、成功を名乗らない。
Future<void> downloadBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final web.Blob blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final String objectUrl = web.URL.createObjectURL(blob);
  try {
    // WHY(download 属性か): サーバーを経由せず、オブジェクト URL の内容を
    // その名前で保存させる唯一の方法。クリックは利用者操作の一部として扱われる。
    final web.HTMLAnchorElement anchor = web.HTMLAnchorElement()
      ..href = objectUrl
      ..download = fileName;
    anchor.click();
    // WHY(待ってから解放するか): click() の直後に URL を無効化すると、
    // ダウンロードが始まる前に実体が消えて失敗する場合がある。
    await Future<void>.delayed(const Duration(seconds: 1));
  } finally {
    // WHY(finally か): 途中で失敗してもオブジェクト URL を残すと、
    // 画像バイト列がページの寿命までメモリに残り続ける。
    web.URL.revokeObjectURL(objectUrl);
  }
}
