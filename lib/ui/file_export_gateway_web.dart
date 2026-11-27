// Web 向けの [FileExportGateway]（ダウンロードで保存する）。
//
// このファイルは `file_export_gateway.dart` から条件付きエクスポートされる。
// 実端末では `file_export_gateway_io.dart` が代わりに使われる。

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'file_export_gateway.dart';
import 'web_download.dart';

/// Web 向けの [FileExportGateway]。保存先を選ばせず、ブラウザのダウンロードに流す。
class PlatformFileExportGateway implements FileExportGateway {
  const PlatformFileExportGateway();

  @override
  Future<XFile?> pickZip() {
    // WHY(Web でも openFile を使うか): file_selector には Web 実装があり、
    // 選んだファイルは XFile.readAsBytes() で読める。Web だけ input 要素を
    // 自前で組み立てると、同じ操作で 2 通りのコードを保守することになる。
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
    await downloadBytes(bytes: bytes, fileName: fileName, mimeType: mimeType);
    // WHY(fileName を返すか): ブラウザのダウンロードは成否を返さない。
    // 「保存を要求した」ことだけを報告し、キャンセル（null）と区別する。
    return fileName;
  }
}
