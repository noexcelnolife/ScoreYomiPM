// Lively リザルトパネルから、項目ごとの数値セル／行ブロックを切り出して 1 枚 1 ファイルにする試作。
//
// 目的: パネル全体を一度に OCR すると GOOD 行や大きなスコア桁が落ちる（実測 46.8%）。
// 行ごとに切り出して ML Kit に渡せば読めるかを、同じ 20 枚で測るための下ごしらえ。
// 実測の結論（docs/lively_extraction_pipeline_2026-11-25.md）:
//   1 行だけのセルは ML Kit が要素を返さないことが多く、7 セルに細切れにすると 42.1% と悪化した。
//   4 行／2 行のブロックにまとめて 2 パスで読み、パネル全体 1 パスと統合すると 59.5% になった。
//   そのため既定の `--mode block` を測定の主経路とし、セル単位は比較用に残している。
//
// セル位置の根拠（実測）: 2 倍に拡大して矩形補正した 18 枚のパネル OCR 結果から、
// 数値要素の中心 y を GREAT ラベルの中心 y 基準・行間隔 P で割ったヒストグラムを取ると
//   -2.6（スコア 4 件）/ -0.85（COOL 14 件）/ 0.05（GREAT 15 件）/ 0.95（GOOD 3 件）
//   +1.9（BAD 11 件）/ +3.5（COMBO 3 件）/ +4.85（BEST SCORE 9 件）
// に帯が分かれた。値の右端は 12.2〜12.7 P に揃い（右寄せ）、左端は 4.5 P 以上。
//
// 使い方:
//   dart run tool/lively_cell_crops.dart --panels build/lively_crop_rect \
//       --elements <パネル OCR の要素 JSON> --out build/lively_cells

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 出力セルの高さ（画素）。元パネル 2 倍時点の数字の高さは 60〜150 画素で、
/// ML Kit で読みやすいとされる 30〜40 画素を十分に上回るが、GOOD 行は小さいため
/// 高さを 260 に揃えて余裕を持たせる。--height で測定用に上書きできる。
int _cellHeight = 260;

/// セルの横範囲の作り方。--mode で切り替える測定用のノブ。
///   both  … 行ラベル語も入れる（"BAD 0" を 1 行として読ませる）
///   value … 数字の列だけにする
///   trim  … both で作ったあと、インクのある列まで横を詰める
String _mode = 'both';

/// 数字の列の左端（P 単位）。ラベル語の右端は 4.2 P より内側にあることを実測済み。
const double _valueLeft = 4.20;

/// セル幅の JPEG 品質。劣化を抑えつつ adb push の容量を現実的に保つ。
const int _jpegQuality = 92;

/// パネル座標の単位 P（行間隔）が実測 140〜166 画素に収まることから決めた許容範囲。
/// これを外れた値はラベル誤検出（実例: P=289.5）なので、中央値 151.5 で置き換える。
const double _pitchMin = 100;
const double _pitchMax = 220;
const double _pitchFallback = 151.5;

/// 1 セルの定義。y / x は GREAT ラベルの左端・中心 y を原点とした P 単位。
class _Cell {
  const _Cell(this.field, this.cy, this.x0, this.x1, this.halfHeight);

  final String field;
  final double cy;
  final double x0;
  final double x1;
  final double halfHeight;
}

/// 上のヒストグラム実測値そのまま。スコアだけは数字の高さが 1.4〜1.5 P あるため半分を広く取る。
///
/// カウンタ行の x0 を負にしてラベル語もセルに含める: 1 文字だけのセル（"0"）は
/// ML Kit が検出を返さないことを実測で確認した（画像 125924236 の GOOD/BAD が
/// 要素 0 件）。行ラベルと数字を同じセルに入れると 1 行のテキストとして認識される。
const List<_Cell> _cells = <_Cell>[
  _Cell('score', -2.65, 4.60, 13.20, 1.05),
  _Cell('cool', -0.85, -0.60, 12.95, 0.50),
  _Cell('great', 0.05, -0.60, 12.95, 0.50),
  _Cell('good', 0.95, -0.60, 12.95, 0.50),
  _Cell('bad', 1.90, -0.60, 12.95, 0.52),
  // COMBO 行はラベル語が一度も検出されず（18 枚中 0）、母集団の値位置も 2.4〜3.5 P に
  // 散っていた。中心を 3.2 P・半分を 0.60 P に広げて取りこぼしを減らす。
  _Cell('combo', 3.20, -0.60, 12.95, 0.60),
  _Cell('best', 4.85, -0.60, 12.95, 0.50),
];

const List<String> _labelWords = <String>[
  'COOL',
  'COOT',
  'COOC',
  'GREAT',
  'GOOD',
  'BAD',
  'BEST',
  'SCORE',
  'COMBO',
];

/// ラベル bbox と行間隔 P。セル座標の基準。
class _Anchor {
  const _Anchor(this.ox, this.oy, this.pitch);

  final double ox;
  final double oy;
  final double pitch;
}

void main(List<String> args) {
  final Map<String, String> options = _parseArgs(args);
  final String panelsDir = options['panels'] ?? 'build/lively_crop_rect';
  final String elementsPath = options['elements'] ?? '';
  final String outDir = options['out'] ?? 'build/lively_cells';
  if (elementsPath.isEmpty) {
    stderr.writeln('--elements にパネル OCR の要素 JSON を指定してください');
    exitCode = 2;
    return;
  }
  final Map<String, _Anchor> anchors = _loadAnchors(elementsPath);
  _cellHeight = int.tryParse(options['height'] ?? '') ?? _cellHeight;
  _mode = options['mode'] ?? _mode;
  Directory(outDir).createSync(recursive: true);
  int written = 0;
  int skipped = 0;
  for (final FileSystemEntity entity in Directory(panelsDir).listSync()) {
    if (entity is! File || !_isImage(entity.path)) {
      continue;
    }
    final String name = entity.uri.pathSegments.last;
    final _Anchor? anchor = anchors[name];
    if (anchor == null) {
      stdout.writeln('skip $name (アンカー無し)');
      skipped++;
      continue;
    }
    final img.Image? panel = img.decodeImage(entity.readAsBytesSync());
    if (panel == null) {
      stdout.writeln('skip $name (デコード失敗)');
      skipped++;
      continue;
    }
    written += _writeCells(panel, anchor, name, outDir);
  }
  stdout.writeln('cells=$written skippedImages=$skipped out=$outDir');
}

/// `--key value` 形式だけを受ける。値が無いキーは空文字。
Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> options = <String, String>{};
  for (int i = 0; i < args.length - 1; i++) {
    final String arg = args[i];
    if (arg.startsWith('--')) {
      options[arg.substring(2)] = args[i + 1];
      i++;
    }
  }
  return options;
}

bool _isImage(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
}

/// パネル OCR の要素 JSON から画像ごとの基準点を作る。
/// GREAT ラベルが無い画像（オプション選択画面）は対象外にする。
Map<String, _Anchor> _loadAnchors(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  final List<Object?> results =
      (decoded! as Map<String, Object?>)['results']! as List<Object?>;
  final Map<String, _Anchor> anchors = <String, _Anchor>{};
  for (final Object? item in results) {
    final Map<String, Object?> entry = item! as Map<String, Object?>;
    final String file = entry['file']! as String;
    final _Anchor? anchor = _anchorOf(entry['elements']! as List<Object?>);
    if (anchor != null) {
      anchors[file] = anchor;
    }
  }
  return anchors;
}

/// GREAT/GOOD/BAD ラベルの中心 y の間隔から P を出す。
/// 2 本未満しか取れない画像は基準を作れないので null。
_Anchor? _anchorOf(List<Object?> elements) {
  final Map<String, List<double>> labels = <String, List<double>>{};
  for (final Object? item in elements) {
    final Map<String, Object?> element = item! as Map<String, Object?>;
    final String? word = _labelOf(element['text']! as String);
    if (word == null) {
      continue;
    }
    final Map<String, Object?> box =
        element['boundingBox']! as Map<String, Object?>;
    labels[word] = <double>[
      (box['l']! as num).toDouble(),
      ((box['t']! as num).toDouble() + (box['b']! as num).toDouble()) / 2,
    ];
  }
  final List<double>? great = labels['GREAT'];
  if (great == null) {
    return null;
  }
  final List<double> centres = <double>[
    for (final String key in <String>['GREAT', 'GOOD', 'BAD'])
      if (labels[key] != null) labels[key]![1],
  ];
  final double pitch = _pitchOf(centres);
  return _Anchor(great[0], great[1], pitch);
}

/// 中心 y の並びから隣接差の中央値を取る。2 本未満なら実測中央値で置き換える。
double _pitchOf(List<double> centres) {
  if (centres.length < 2) {
    return _pitchFallback;
  }
  centres.sort();
  final List<double> gaps = <double>[
    for (int i = 0; i < centres.length - 1; i++) centres[i + 1] - centres[i],
  ];
  gaps.sort();
  final double median = gaps[gaps.length ~/ 2];
  if (median < _pitchMin || median > _pitchMax) {
    return _pitchFallback;
  }
  return median;
}

/// 文字列がラベル語で始まればその語を返す。OCR は "COOT"/"COOC" のように崩れることがある。
String? _labelOf(String text) {
  final String letters = text.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase();
  for (final String word in _labelWords) {
    if (letters.startsWith(word)) {
      return word == 'COOT' || word == 'COOC' ? 'COOL' : word;
    }
  }
  return null;
}

/// 行をまとめて 1 枚にするブロック。ラベル語も入れて「複数行のテキスト」として読ませる。
/// 1 行だけのセルは ML Kit が要素を返さないことが多い（実測: COMBO 行 0/18）ため、
/// 段落状のまとまりにしたほうが読みやすいという仮説の検証用。
const List<List<String>> _blocks = <List<String>>[
  <String>['cool', 'great', 'good', 'bad'],
  <String>['combo', 'best'],
];

/// ブロック出力の高さ（画素）。4 行で元 2 倍時点 650 画素程度なので 1.4 倍前後になる。
const int _blockHeight = 900;

/// パネル 1 枚から 7 セルを書き出す。範囲外に出たセルは切り詰める。
int _writeCells(img.Image panel, _Anchor anchor, String name, String outDir) {
  final String stem = name.replaceAll(RegExp(r'\.[A-Za-z]+$'), '');
  if (_mode == 'block') {
    return _writeBlocks(panel, anchor, stem, outDir);
  }
  int written = 0;
  for (final _Cell cell in _cells) {
    final img.Image? cropped = _crop(panel, anchor, cell);
    if (cropped == null) {
      continue;
    }
    final String path = '$outDir/${stem}__${cell.field}.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(cropped, quality: _jpegQuality));
    written++;
  }
  return written;
}

/// 複数行をまとめたブロック画像を書き出す。スコアは装飾フォントなので単独で出す。
int _writeBlocks(img.Image panel, _Anchor anchor, String stem, String outDir) {
  int written = 0;
  for (final List<String> block in _blocks) {
    final List<_Cell> members = <_Cell>[
      for (final String field in block)
        if (_cellOf(field) != null) _cellOf(field)!,
    ];
    if (members.isEmpty) {
      continue;
    }
    double topP = members.first.cy - members.first.halfHeight;
    double bottomP = members.first.cy + members.first.halfHeight;
    for (final _Cell member in members) {
      topP = math.min(topP, member.cy - member.halfHeight);
      bottomP = math.max(bottomP, member.cy + member.halfHeight);
    }
    final _Cell shape = _Cell(
      block.join('_'),
      (topP + bottomP) / 2,
      -0.60,
      13.10,
      (bottomP - topP) / 2,
    );
    final img.Image? blockImage = _crop(panel, anchor, shape);
    if (blockImage == null) {
      continue;
    }
    final img.Image resized = blockImage.height == _blockHeight
        ? blockImage
        : img.copyResize(
            blockImage,
            height: _blockHeight,
            interpolation: img.Interpolation.cubic,
          );
    File(
      '$outDir/${stem}__${block.join('_')}.jpg',
    ).writeAsBytesSync(img.encodeJpg(_enhance(resized), quality: _jpegQuality));
    written++;
  }
  final _Cell? score = _cellOf('score');
  if (score != null) {
    final img.Image? cropped = _crop(panel, anchor, score);
    if (cropped != null) {
      File('$outDir/${stem}__score.jpg')
          .writeAsBytesSync(img.encodeJpg(cropped, quality: _jpegQuality));
      written++;
    }
  }
  return written;
}

_Cell? _cellOf(String field) {
  for (final _Cell cell in _cells) {
    if (cell.field == field) {
      return cell;
    }
  }
  return null;
}

img.Image? _crop(img.Image panel, _Anchor anchor, _Cell cell) {
  final double p = anchor.pitch;
  final double x0 = _mode == 'value' ? math.max(cell.x0, _valueLeft) : cell.x0;
  final int left = (anchor.ox + x0 * p).round();
  final int right = (anchor.ox + cell.x1 * p).round();
  final int top = (anchor.oy + (cell.cy - cell.halfHeight) * p).round();
  final int bottom = (anchor.oy + (cell.cy + cell.halfHeight) * p).round();
  if (right <= left || bottom <= top) {
    return null;
  }
  final int x = math.max(0, left);
  final int y = math.max(0, top);
  final int w = math.min(panel.width, right) - x;
  final int h = math.min(panel.height, bottom) - y;
  if (w <= 0 || h <= 0) {
    return null;
  }
  final img.Image cropped = img.copyCrop(
    panel,
    x: x,
    y: y,
    width: w,
    height: h,
  );
  final img.Image sized = cropped.height == _cellHeight
      ? cropped
      : img.copyResize(
          cropped,
          height: _cellHeight,
          interpolation: img.Interpolation.cubic,
        );
  final img.Image enhanced = _enhance(sized);
  return _mode == 'trim' ? _trimInk(enhanced) : enhanced;
}

/// インクのある列まで横を詰める。数字が画角に占める割合を上げるため。
/// 上下は詰めない（隣の行の数字が上端・下端に写り込むことがあるため）。
img.Image _trimInk(img.Image cell) {
  final int top = (cell.height * 0.2).round();
  final int bottom = (cell.height * 0.8).round();
  int left = cell.width;
  int right = -1;
  for (int x = 0; x < cell.width; x++) {
    for (int y = top; y < bottom; y++) {
      if (cell.getPixel(x, y).r > 96) {
        left = math.min(left, x);
        right = math.max(right, x);
        break;
      }
    }
  }
  if (right <= left) {
    return cell;
  }
  final int pad = math.max(4, ((right - left) * 0.04).round());
  final int x = math.max(0, left - pad);
  final int w = math.min(cell.width, right + pad) - x;
  return img.copyCrop(cell, x: x, y: 0, width: w, height: cell.height);
}

/// セルを ML Kit が読みやすい濃淡に整える。
///
/// 実測: GOOD 行は赤文字で、切り出しても ML Kit はラベル語しか返さない（18 枚中 16 枚が未検出）。
/// 赤は輝度が低く、パネルは黒地なのでコントラストが小さい。そこで RGB の最大値を濃淡に使い、
/// 点描状の網点をなまらせてからコントラストを広げる。
img.Image _enhance(img.Image cell) {
  final img.Image gray = img.Image(
    width: cell.width,
    height: cell.height,
    numChannels: 3,
  );
  for (int y = 0; y < cell.height; y++) {
    for (int x = 0; x < cell.width; x++) {
      final img.Pixel pixel = cell.getPixel(x, y);
      final num value = math.max(pixel.r, math.max(pixel.g, pixel.b));
      gray.setPixelRgb(x, y, value, value, value);
    }
  }
  // 網点（ドット描画）の隙間を埋める。
  final img.Image blurred = img.gaussianBlur(gray, radius: 1);
  return img.normalize(blurred, min: 0, max: 255);
}
