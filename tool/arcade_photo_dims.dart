import 'dart:io';

import 'package:image/image.dart' as img;

import 'tool_paths.dart';

// ignore_for_file: avoid_print

/// AC-HC-photo 30 枚の画像寸法・アスペクト比を一括測定するプローブ。
/// 実画像は公開リポジトリに同梱していないため、`--images=<dir>` で差し替えられる。
void main(List<String> args) {
  final imageDir = resolveImageDir(args, 'testimage/AC-HC-photo');
  final dir = Directory(imageDir);
  if (!dir.existsSync()) {
    print('NOT FOUND: $imageDir（--images=<dir> で指定する）');
    return;
  }
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  print('file count: ${files.length}');
  print('filename,width,height,aspect,class');
  int portraitCount = 0;
  int landscapeCount = 0;
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) {
      print('${file.path},DECODE_FAIL');
      continue;
    }
    final aspect = image.width / image.height;
    final cls = image.height > image.width ? 'portrait' : 'landscape';
    if (cls == 'portrait') portraitCount++;
    if (cls == 'landscape') landscapeCount++;
    print(
      '${file.path},${image.width},${image.height},${aspect.toStringAsFixed(3)},$cls',
    );
  }
  print('portrait: $portraitCount / landscape: $landscapeCount');
}
