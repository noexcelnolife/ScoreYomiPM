// バックアップ形式の不正を表す例外（タスク 01a20bfe・データ層）。
//
// WHY: 復元は「読めなかったら 1 件も書かない」を保証する。想定外の形式は
// 汎用の FormatException ではなく専用型で送出し、呼び出し側（UI）が
// 「壊れたファイル」と「その他の失敗」を区別して案内できるようにする。

/// バックアップ ZIP の形式が仕様と一致しないことを表す。
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  /// 利用者向けにそのまま提示できる日本語メッセージ。
  final String message;

  @override
  String toString() => 'BackupFormatException: $message';
}
