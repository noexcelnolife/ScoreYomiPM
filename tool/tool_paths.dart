// 実画像（testimage/）は公開リポジトリに同梱していない。
// そのため生成・計測ツールの入力ディレクトリは既定値を持たせつつ、
// `--images=<dir>` で手元のディレクトリへ差し替えられるようにする。
import 'dart:io';

/// `--images=<dir>` が指定されていればその値を、無ければ [defaultDir] を返す。
String resolveImageDir(List<String> args, String defaultDir) {
  const prefix = '--images=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      final value = arg.substring(prefix.length).trim();
      if (value.isEmpty) {
        stderr.writeln('--images= にパスが指定されていない');
        exit(2);
      }
      return value;
    }
  }
  return defaultDir;
}

/// 入力ディレクトリの存在を確認し、無ければ理由を出して終了する。
/// 実画像を同梱していないため、clone 直後は既定値が必ず存在しない。
void ensureImageDirExists(String dir) {
  if (Directory(dir).existsSync()) {
    return;
  }
  stderr.writeln('入力ディレクトリが見つからない: $dir');
  stderr.writeln(
    '実画像はリポジトリに同梱していない。'
    '手元のディレクトリを --images=<dir> で指定する。',
  );
  exit(2);
}

/// 生成物に書き込む記録用パスを返す（区切りは / に統一し、末尾の / は落とす）。
/// カレントディレクトリ配下を指している場合は相対パスにする。
/// これは生成物（manifest / fixture）に個人環境の絶対パスを残さないため。
String recordedPath(String path) {
  final root = Directory.current.path.replaceAll(r'\', '/');
  var result = path.replaceAll(r'\', '/');
  if (result.startsWith('$root/')) {
    result = result.substring(root.length + 1);
  }
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
