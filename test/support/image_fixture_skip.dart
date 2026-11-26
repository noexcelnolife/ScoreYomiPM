// testimage/ は公開リポジトリに同梱しない方針のため、画像が無い環境では
// 実画像に依存するテストを skip して失敗扱いにしない。
// 手元に画像を置いている環境では null が返り、回帰ガードとしてそのまま実行される。
import 'dart:io';

/// 指定パスがすべて存在すれば null（= 通常実行）を返す。
/// 1 つでも欠けていれば skip 理由の文字列を返す。
/// ファイル・ディレクトリのどちらでも判定できるよう、種別を問わず存在だけを見る。
String? skipIfImagesMissing(Iterable<String> paths) {
  for (final path in paths) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      return 'testimage/ が無いため skip（実画像に依存）: $path';
    }
  }
  return null;
}
