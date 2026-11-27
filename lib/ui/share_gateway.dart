import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 原画像を端末の共有シートへ渡す境界。
///
/// WHY 画面から切り離すか: 共有シートはプラットフォームチャネルを使うため
/// widget テストから直接呼べない。[FileExportGateway] と同じ方針で、
/// 「何を共有するか」は画面が決め、「どう共有するか」は差し替え可能にする。
abstract class ImageShareGateway {
  /// [bytes] を [fileName] という名前で共有する。
  ///
  /// WHY 共有の成否を返さないか: Android の共有結果は「シートで何かを選んだか」
  /// しか分からず、実際に相手へ渡ったかは保証されない。成功を名乗らないため
  /// 戻り値を持たない（利用者のキャンセルも同じ扱い）。
  Future<void> shareImage({required Uint8List bytes, required String fileName});
}

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
