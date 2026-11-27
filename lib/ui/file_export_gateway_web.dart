// Web 向けの [FileExportGateway]（dart:js_interop プラットフォーム専用）。
//
// このファイルは `file_export_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは dart:io が実行時に UnsupportedError を出すため、
// ブラウザのダウンロード機能（AnchorElement.download）を使用する。
//
// dart:html を使う理由（package:web ではなく）: Tier A は --wasm ビルドを対象外にしているため、
// dart:html の利用は許容される（計画 D11）。--wasm に移行する際は package:web への移行が必要。

import 'dart:html' as html;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'file_export_gateway.dart';

/// Web ブラウザ向けの [FileExportGateway]。
class PlatformFileExportGateway implements FileExportGateway {
  const PlatformFileExportGateway();

  @override
  Future<XFile?> pickZip() {
    // WHY(file_selector): `pickZip()` は `file_selector` の `openFile()` だけで実装でき、
    // `dart:io` は一切使わない。io 版と同じコードで Web でも動作する（確認済み）。
    return openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'ZIP', extensions: <String>['zip']),
      ],
    );
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

    // WHY(revokeObjectUrl のタイミング): click() の直後に revoke すると、
    // ブラウザ（Firefox / Safari 等）によってはダウンロードが始まる前に URL が無効化され失敗する。
    // 次のイベントループに譲ってから revoke する。
    await Future<void>.delayed(const Duration(seconds: 1));
    html.Url.revokeObjectUrl(url);

    return fileName;
  }
}
