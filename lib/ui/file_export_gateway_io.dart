// 実端末向けの [FileExportGateway]（dart:io 使用プラットフォーム専用）。
//
// このファイルは `file_export_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは `file_export_gateway_web.dart` が代わりに使われる。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

import 'file_export_gateway.dart';

/// 実端末向けの [FileExportGateway]。
class PlatformFileExportGateway implements FileExportGateway {
  const PlatformFileExportGateway();

  @override
  Future<XFile?> pickZip() {
    // WHY(extensions): Android のファイル選択は拡張子から MIME を決めるため、
    // zip だけを候補に出す。
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
    final Directory directory = await getTemporaryDirectory();
    final File temporary = File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      // WHY(sourceFilePath): 保存ダイアログにはパスを渡してプラットフォーム側で
      // コピーさせる。大きな ZIP のバイト列をチャネルで丸ごと送らない。
      return await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: temporary.path,
          fileName: fileName,
          mimeTypesFilter: <String>[mimeType],
        ),
      );
    } finally {
      // WHY: 保存がキャンセルされた場合も一時ファイルを残さない。
      if (temporary.existsSync()) {
        await temporary.delete();
      }
    }
  }
}
