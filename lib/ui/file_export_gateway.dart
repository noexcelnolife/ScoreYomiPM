// 端末とのファイル入出力を包むゲートウェイ。
//
// WHY(分離): file_selector / flutter_file_dialog / path_provider は
// プラットフォームチャネルを使うため widget テストから直接呼べない。画面から
// この依存を切り離し、テストでは差し替え用の fake を注入する（DIP）。
// 画面ファイルが 400 行を超えたため、入出力の実装だけをここへ移した。
// もとはバックアップ画面専用（BackupFileGateway）だったが、記録詳細画面の
// 「アプリ外に保存」（01a2106d）でも saveBytes を使うため、用途を限定しない
// 名前に改名した。
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

/// 端末とのファイル入出力だけを担う薄い抽象。
abstract class FileExportGateway {
  /// 復元する ZIP を選ばせる。キャンセル時は null。
  ///
  /// WHY(同居): 保存系ではないが、同じ file_selector 依存を共有し、テスト側の
  /// fake を 1 つにまとめられるため同じ抽象に置く。
  Future<XFile?> pickZip();

  /// [bytes] をファイルとして保存させる。キャンセル時は null。
  Future<String?> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  });
}

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
