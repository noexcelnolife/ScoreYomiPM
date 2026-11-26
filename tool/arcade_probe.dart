import 'dart:io';

import 'package:image/image.dart' as img;

import 'tool_paths.dart';

// ignore_for_file: avoid_print

/// OCR枠.png の緑領域を検出してバウンディングボックスを出力するプローブ。
///
/// 緑判定: G > R + 40 && G > B + 40 && G > 120（注釈用の蛍光緑を拾う）。
/// 全体 bbox + 個別連結成分 bbox（8 連結）を出力。
/// 実画像は公開リポジトリに同梱していないため、`--images=<dir>` で差し替えられる。
void main(List<String> args) {
  final imageDir = resolveImageDir(args, 'testimage/実機リザルト枠');
  ensureImageDirExists(imageDir);
  final dir = Directory(imageDir);
  final files = <String>['snapshot.jpg', 'OCR枠.png', 'OCR枠.psd'];
  for (final f in files) {
    final path = '${dir.path}/$f';
    final file = File(path);
    if (!file.existsSync()) {
      print('$f: NOT FOUND');
      continue;
    }
    print('$f: ${file.lengthSync()} bytes');
  }

  // 画像 2 枚のデコード（PSD は image パッケージ未対応のためスキップ）。
  final snap = img.decodeImage(
    File('${dir.path}/snapshot.jpg').readAsBytesSync(),
  )!;
  final annot = img.decodeImage(
    File('${dir.path}/OCR枠.png').readAsBytesSync(),
  )!;
  print('snapshot.jpg: ${snap.width}x${snap.height}');
  print('OCR枠.png: ${annot.width}x${annot.height}');

  // 緑領域検出。
  final greenMask = _greenMask(annot);
  final bbox = _bboxOfMask(greenMask, annot.width, annot.height);
  print('green pixels: ${greenMask.where((v) => v).length}');
  print(
    'green bbox (px): left=${bbox.$1} top=${bbox.$2} right=${bbox.$3} bottom=${bbox.$4}',
  );
  print(
    'green bbox (norm): x=[${(bbox.$1 / annot.width).toStringAsFixed(4)}, ${(bbox.$3 / annot.width).toStringAsFixed(4)}] y=[${(bbox.$2 / annot.height).toStringAsFixed(4)}, ${(bbox.$4 / annot.height).toStringAsFixed(4)}]',
  );

  // 連結成分（8連結）で個別領域を分離（最大 12 個まで出力）。
  final comps = _connectedComponents(greenMask, annot.width, annot.height);
  comps.sort((a, b) => b.$5.compareTo(a.$5)); // 面積降順
  print('green components: ${comps.length}');
  for (var i = 0; i < comps.length && i < 12; i++) {
    final c = comps[i];
    print(
      '  comp$i: area=${c.$5} norm x=[${(c.$1 / annot.width).toStringAsFixed(4)}, ${(c.$3 / annot.width).toStringAsFixed(4)}] y=[${(c.$2 / annot.height).toStringAsFixed(4)}, ${(c.$4 / annot.height).toStringAsFixed(4)}]',
    );
  }
}

/// 緑マスク（真 = 緑領域）。
List<bool> _greenMask(img.Image image) {
  final n = image.width * image.height;
  final mask = List<bool>.filled(n, false);
  var i = 0;
  for (final p in image) {
    final r = p.r;
    final g = p.g;
    final b = p.b;
    mask[i] = (g > r + 40) && (g > b + 40) && (g > 120);
    i++;
  }
  return mask;
}

/// 緑ピクセルの全体バウンディングボックス。
(int, int, int, int) _bboxOfMask(List<bool> mask, int width, int height) {
  int left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final idx = y * width + x;
      if (mask[idx]) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  if (right < 0) {
    return (-1, -1, -1, -1);
  }
  return (left, top, right, bottom);
}

/// 8連結の連結成分ラベリング（簡易・2パス Union-Find 相当）。
List<(int, int, int, int, int)> _connectedComponents(
  List<bool> mask,
  int width,
  int height,
) {
  final parent = List<int>.generate(mask.length, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  void union(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) {
      parent[rb] = ra;
    }
  }

  // 4方向（上・左・左上・右上）を結合すれば 8連結。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final idx = y * width + x;
      if (!mask[idx]) continue;
      final neighbors = <int>[];
      if (y > 0) neighbors.add(idx - width); // 上
      if (x > 0) neighbors.add(idx - 1); // 左
      if (y > 0 && x > 0) neighbors.add(idx - width - 1); // 左上
      if (y > 0 && x < width - 1) neighbors.add(idx - width + 1); // 右上
      for (final nb in neighbors) {
        if (mask[nb]) {
          union(idx, nb);
        }
      }
    }
  }
  final comps = <int, (int, int, int, int, int)>{};
  for (var idx = 0; idx < mask.length; idx++) {
    if (!mask[idx]) continue;
    final root = find(idx);
    final x = idx % width;
    final y = idx ~/ width;
    final existing = comps[root];
    if (existing == null) {
      comps[root] = (x, y, x, y, 1);
    } else {
      comps[root] = (
        x < existing.$1 ? x : existing.$1,
        y < existing.$2 ? y : existing.$2,
        x > existing.$3 ? x : existing.$3,
        y > existing.$4 ? y : existing.$4,
        existing.$5 + 1,
      );
    }
  }
  return comps.values.toList();
}
