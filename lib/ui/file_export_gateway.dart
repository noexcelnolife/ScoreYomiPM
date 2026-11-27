// 端末とのファイル入出力を包むゲートウェイ。
//
// WHY(分離): file_selector / flutter_file_dialog / path_provider は
// プラットフォームチャネルを使うため widget テストから直接呼べない。画面から
// この依存を切り離し、テストでは差し替え用の fake を注入する（DIP）。
// 画面ファイルが 400 行を超えたため、入出力の実装だけをここへ移した。
// もとはバックアップ画面専用（BackupFileGateway）だったが、記録詳細画面の
// 「アプリ外に保存」（01a2106d）でも saveBytes を使うため、用途を限定しない
// 名前に改名した。
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// プラットフォーム固有の [FileExportGateway] 実装をエクスポートする。
///
/// WHY(条件付きエクスポート): `dart:io` は Web でもコンパイルは通るが実行時に
/// `UnsupportedError` を出す。io プラットフォームでは `file_export_gateway_io.dart` を、
/// Web プラットフォームでは `file_export_gateway_web.dart` を使い分ける。
/// UI 側は `PlatformFileExportGateway()` を書くだけで、`kIsWeb` 分岐を書かなくて済む。
export 'file_export_gateway_io.dart' if (dart.library.js_interop) 'file_export_gateway_web.dart';

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
