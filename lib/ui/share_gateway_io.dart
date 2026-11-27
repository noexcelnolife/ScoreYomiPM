// 実端末向けの [ImageShareGateway]（dart:io 使用プラットフォーム専用）。
//
// このファイルは `share_gateway.dart` から条件付きエクスポートされる。
// Web プラットフォームでは `share_gateway_web.dart` が代わりに使われる。

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'share_gateway.dart';

/// `share_plus` で共有シートを開く実端末向け実装（配布対象は Android の APK）。
///
/// WHY iPad の `sharePositionOrigin` を渡さないか: 配布は Android のみで、
/// ポップオーバーの位置指定が要らない。iOS に対応する時は、押したボタンの
/// 矩形を受け取る引数を足すこと（未指定だと iPad では位置が崩れる）。
class PlatformImageShareGateway implements ImageShareGateway {
  const PlatformImageShareGateway();

  /// 共有用のファイルを置く一時ディレクトリ名。
  ///
  /// WHY 専用のサブディレクトリか: 共有のたびに同じ名前で上書きするため、
  /// 他の一時ファイル（保存ダイアログの控え等）と混ざらない場所に隔離する。
  static const String _shareDirectoryName = 'share';

  @override
  Future<void> shareImage({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final Directory directory = await _shareDirectory();
    final File file = File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsBytes(bytes, flush: true);

    // WHY 共有後に削除しないか: 共有先のアプリは受け取った直後ではなく、
    // 後からファイルを読むことがある。消すと共有が壊れるため、OS の
    // キャッシュ整理（一時ディレクトリの掃除）に任せる。
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(file.path)]),
    );
  }

  /// 共有用の一時ディレクトリを用意して返す（無ければ作る）。
  Future<Directory> _shareDirectory() async {
    final Directory base = await getTemporaryDirectory();
    final Directory directory = Directory(
      '${base.path}${Platform.pathSeparator}$_shareDirectoryName',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
