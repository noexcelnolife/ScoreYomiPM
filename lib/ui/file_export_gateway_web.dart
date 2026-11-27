// Web 向けの [FileExportGateway]（dart:js_interop プラットフォーム専用）。
//
// このファイルは `file_export_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは dart:io が実行時に UnsupportedError を出すため、
// ブラウザのダウンロード機能（AnchorElement.download）を使用する。

import 'dart:html' as html;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'file_export_gateway.dart';

/// Web ブラウザ向けの [FileExportGateway]。
class PlatformFileExportGateway implements FileExportGateway {
  const PlatformFileExportGateway();

  @override
  Future<XFile?> pickZip() async {
    // Web ではファイル選択ダイアログはプラットフォームチャネル経由のため未サポート。
    // 将来 `file_selector` の Web 実装を使う場合はここに移行する。
    return null;
  }

  @override
  Future<String?> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    // WHY(ブラウザダウンロード): Web ではファイルシステムへの直接書き込みができないため、
    // ブラウザのダウンロード機能（AnchorElement.download）を使用する。
    // Uint8List は List<int> なので Blob のコンストラクタに直接渡せる（typedData は不要）。
    final blob = html.Blob([bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
    return fileName;
  }
}
