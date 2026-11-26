// Song DB 関連ファイルの配置契約。
//
// WHY: 配置パスは lib/songdb（DL・取り込みの書き込み先）と main.dart
// （lib/ocr のリポジトリへの注入パス）の双方で共有する契約のため、単一の
// 定義にまとめる。値は lib/ocr 側 stub リポジトリのコメント契約と一致させる。
class SongDbPaths {
  const SongDbPaths._();

  /// documents ディレクトリ直下の Song DB 用サブディレクトリ名。
  static const String songsDirName = 'songs';

  /// メイン DB（配信 DL の保存先）のファイル名。
  static const String mainDbFileName = 'main_v1.json';

  /// ローカル追加 DB（取り込みの保存先）のファイル名。
  static const String additionalDbFileName = 'additional_v1.json';

  /// メイン DB（配信 DL の保存先）の相対パス。
  static const String mainDbRelativePath = '$songsDirName/$mainDbFileName';

  /// ローカル追加 DB（取り込みの保存先）の相対パス。
  static const String additionalDbRelativePath =
      '$songsDirName/$additionalDbFileName';
}
