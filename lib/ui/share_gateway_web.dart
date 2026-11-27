// Web 向けの [ImageShareGateway]。
//
// このファイルは `share_gateway.dart` から条件付きエクスポートされる。
// 実端末では `share_gateway_io.dart` が代わりに使われる。

import 'dart:typed_data';

import 'share_gateway.dart';
import 'web_download.dart';

/// Web 向けの [ImageShareGateway]。
///
/// DEVIATION(Web Share API を使わない): ブラウザの共有シートへ画像を渡すには
/// `navigator.share({files})` に DOM の File を渡す必要があり、`dart:js_interop`
/// の型の橋渡しが崩れやすく、対応状況もブラウザごとに違う（デスクトップの
/// Chrome / Firefox は file 共有に非対応）。**代替**としてダウンロードに固定する。
/// 利用者の目的（画像をアプリの外へ出す）は満たせる。**再検討条件**: Web 版で
/// 共有が主要動線になったとき、または対応ブラウザが十分に広がったとき。
class PlatformImageShareGateway implements ImageShareGateway {
  const PlatformImageShareGateway();

  @override
  Future<void> shareImage({
    required Uint8List bytes,
    required String fileName,
  }) {
    // WHY(MIME を拡張子から決めるか): 共有シート相当の処理でも、保存された
    // ファイルを OS が正しく扱えるようにするため。
    return downloadBytes(
      bytes: bytes,
      fileName: fileName,
      mimeType: _mimeTypeOf(fileName),
    );
  }

  String _mimeTypeOf(String fileName) {
    final String lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    // WHY(jpeg を既定にするか): 撮影・共有で来る画像の大半が JPEG。
    return 'image/jpeg';
  }
}
