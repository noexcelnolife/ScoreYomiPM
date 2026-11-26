// Lively リザルト写真の「領域切り出し + 台形補正」プロトタイプ（オフライン CLI）。
//
// 目的:
//   docs/lively_ocr_raw_2026-11-25.json（生写真 20 枚の OCR 生データ）に記録された
//   ラベル文字（COOL / GREAT / GOOD / BAD / BEST SCORE）の位置矩形を使い、
//   スコアパネルだけを切り出して角度補正・台形補正した JPEG を作る。
//   切り出した画像を端末でもう一度 OCR し、生写真のままと精度を比べるための前処理。
//
// WHY ラベル位置を起点にするか:
//   パネルは背景の明るさが近く、単純な暗領域検出では画面下半分と結合してしまう
//   （実測: しきい値 70/90 で x 0–99.6%, y 56.1–99.5% が 1 連結成分になった）。
//   一方ラベル文字は毎回安定して検出でき、パネル内側の基準点として使える。
//
// 使い方:
//   dart run tool/lively_crop_rectify.dart --mode crop
//   dart run tool/lively_crop_rectify.dart --mode rectify --scale 2
//   （--help で全オプション）
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ---- 既定値 ------------------------------------------------------------
const String _defaultRawJson = 'docs/lively_ocr_raw_2026-11-25.json';
const String _defaultPhotos = 'testimage/PC-LI-photo';
const String _defaultOutDir = 'build/lively_crop';

/// ラベル列の左端から画像左端側へ確保する余白（ラベル列の高さを 1 とする）。
const double _padLeft = 0.30;

/// ラベル列の右端から右へ確保する余白。数値列がこの範囲に入る。
const double _padRight = 1.25;

/// ラベル列の上端から上へ確保する余白。大きなスコア数字がここに入る。
const double _padTop = 0.80;

/// ラベル列の下端から下へ確保する余白。
const double _padBottom = 0.25;

/// 傾き推定の探索範囲（度）と刻み（度）。
const double _rollSearchDeg = 5.0;
const double _rollStepDeg = 0.25;

/// 傾き推定に使う間引き間隔（画素）。精度に足りる範囲で計算量を落とす。
const int _rollSampleStep = 2;

/// 出力の長辺上限（画素）。3 倍指定では 17/20 枚がここで頭打ちになり
/// （実効 2.51〜3.00 倍）、正解セルは 2 倍を下回った（44.4% < 46.8%）。
/// これ以上拡大しても効果が無いので上限を設ける。
const int _maxOutputSide = 3200;

void main(List<String> argv) {
  final options = _Options.parse(argv);
  if (options == null) {
    print(_usage);
    return;
  }
  switch (options.mode) {
    case _Mode.crop:
    case _Mode.rectify:
      _runPipeline(options);
    case _Mode.distort:
      _runDistort(options);
    case _Mode.compare:
      _runCompare(options);
  }
}

const String _usage =
    '''
Lively リザルト写真の切り出し + 台形補正プロトタイプ

  --mode crop|rectify|distort|compare
                                 crop=切り出しのみ / rectify=切り出し+角度補正
                                 distort=検証用の台形歪み注入 / compare=2 ディレクトリの画素差
  --raw <path>                   生 OCR 結果 JSON（既定: $_defaultRawJson）
  --photos <dir>                 元写真ディレクトリ（既定: $_defaultPhotos）
  --out <dir>                    出力先（既定: $_defaultOutDir）
  --scale <n>                    出力倍率（既定: 2）
  --keystone <k>                 台形歪み係数。distort で歪みを注入し、rectify で取り除く（既定: 0）
  --full-frame                   1 枚全体をパネルとみなし、ロール 0 で台形成分だけ補正する
  --manifest <path>              計測結果 CSV の出力先（既定: <out>/manifest.csv）
  --verify                       出力画像の傾きを再推定して残差を表示する（補正の自己検証）
''';

// ======================================================================
// モード定義
// ======================================================================

enum _Mode { crop, rectify, distort, compare }

class _Options {
  const _Options({
    required this.mode,
    required this.rawJson,
    required this.photos,
    required this.outDir,
    required this.scale,
    required this.keystone,
    required this.manifest,
    required this.verify,
    required this.fullFrame,
  });

  final _Mode mode;
  final String rawJson;
  final String photos;
  final String outDir;
  final double scale;
  final double keystone;
  final String manifest;
  final bool verify;
  final bool fullFrame;

  /// 引数を解析する。解析に失敗したら null を返す。
  static _Options? parse(List<String> argv) {
    var mode = _Mode.rectify;
    var raw = _defaultRawJson;
    var photos = _defaultPhotos;
    var out = _defaultOutDir;
    var scale = 2.0;
    var keystone = 0.0;
    var verify = false;
    var fullFrame = false;
    String? manifest;
    for (var i = 0; i < argv.length; i++) {
      final key = argv[i];
      if (key == '--help' || key == '-h') return null;
      if (key == '--verify') {
        verify = true;
        continue;
      }
      if (key == '--full-frame') {
        fullFrame = true;
        continue;
      }
      final value = i + 1 < argv.length ? argv[i + 1] : null;
      switch (key) {
        case '--mode':
          {
            final parsed = _parseMode(value);
            if (parsed == null) return null;
            mode = parsed;
            i++;
          }
        case '--raw':
          if (value == null) return null;
          raw = value;
          i++;
        case '--photos':
          if (value == null) return null;
          photos = value;
          i++;
        case '--out':
          if (value == null) return null;
          out = value;
          i++;
        case '--scale':
          {
            final parsed = double.tryParse(value ?? '');
            if (parsed == null || parsed <= 0) return null;
            scale = parsed;
            i++;
          }
        case '--keystone':
          {
            final parsed = double.tryParse(value ?? '');
            if (parsed == null) return null;
            keystone = parsed;
            i++;
          }
        case '--manifest':
          if (value == null) return null;
          manifest = value;
          i++;
        default:
          return null;
      }
    }
    return _Options(
      mode: mode,
      rawJson: raw,
      photos: photos,
      outDir: out,
      scale: scale,
      keystone: keystone,
      manifest: manifest ?? '$out/manifest.csv',
      verify: verify,
      fullFrame: fullFrame,
    );
  }

  static _Mode? _parseMode(String? value) {
    for (final mode in _Mode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

// ======================================================================
// 本処理: 20 枚の写真を切り出して書き出す
// ======================================================================

/// 写真 20 枚を処理し、切り出し画像と計測 CSV を書き出す。
void _runPipeline(_Options options) {
  final anchors = _loadAnchors(options.rawJson);
  final photos = _collectPhotos(options.photos);
  if (photos.isEmpty) {
    stderr.writeln('写真が見つかりません: ${options.photos}');
    exitCode = 1;
    return;
  }
  Directory(options.outDir).createSync(recursive: true);

  // 1 パス目: ラベルがある画像のパネル矩形を求める。
  // --full-frame では画像全体をパネルとみなす（歪み注入済み画像の補正用）。
  final planned = <File, _Box?>{};
  for (final photo in photos) {
    final name = photo.uri.pathSegments.last;
    planned[photo] = options.fullFrame
        ? _fullFrameBox
        : _panelBoxFromAnchors(anchors[name]);
  }
  final fallback = _medianBox(planned.values.whereType<_Box>().toList());
  if (fallback == null) {
    stderr.writeln('ラベル基準のパネル矩形が 1 件も求まりませんでした。');
    exitCode = 1;
    return;
  }

  final rows = <String>[
    'file,label_count,roll_deg,left,top,right,bottom,out_w,out_h',
  ];
  for (final photo in photos) {
    final name = photo.uri.pathSegments.last;
    final anchorBox = planned[photo];
    final box = anchorBox ?? fallback;
    final labelCount = anchors[name]?.length ?? 0;
    final row = _processOne(photo, name, box, labelCount, options);
    if (row != null) rows.add(row);
  }
  File(options.manifest).writeAsStringSync('${rows.join('\r\n')}\r\n');
  print('done: ${rows.length - 1} images -> ${options.outDir}');
}

/// 1 枚を処理して計測 CSV の 1 行を返す。失敗したら null。
String? _processOne(
  File photo,
  String name,
  _Box box,
  int labelCount,
  _Options options,
) {
  final decoded = img.decodeJpg(photo.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('decode 失敗: $name');
    return null;
  }
  final clamped = box.clampTo(decoded.width, decoded.height);
  if (clamped.width < 64 || clamped.height < 64) {
    stderr.writeln('切り出し範囲が小さすぎます: $name');
    return null;
  }
  final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);
  // --full-frame は台形成分だけを見る検証用なのでロールは 0 とみなす。
  final roll = (options.mode == _Mode.rectify && !options.fullFrame)
      ? _estimateRoll(rgb, clamped, decoded.width, decoded.height)
      : 0.0;
  final keystone = options.mode == _Mode.rectify ? options.keystone : 0.0;

  // 長辺が上限を超える場合は倍率そのものを下げる。
  // 縦横を別々に丸めると縦横比が崩れ、文字が横に潰れて OCR 精度を落とすため。
  var scale = options.scale;
  final longest = math.max(clamped.width, clamped.height);
  if (longest * scale > _maxOutputSide) {
    scale = _maxOutputSide / longest;
  }
  final outW = math.max((clamped.width * scale).round(), 1);
  final outH = math.max((clamped.height * scale).round(), 1);
  final map = _rectifyMap(
    clamped,
    roll,
    keystone,
    outW.toDouble(),
    outH.toDouble(),
  );
  final rectified = _warpImage(
    rgb,
    decoded.width,
    decoded.height,
    map,
    outW,
    outH,
  );

  final outFile = File('${options.outDir}/$name');
  outFile.writeAsBytesSync(img.encodeJpg(rectified, quality: 95));
  final residual = options.verify
      ? _estimateRoll(
          rectified.getBytes(order: img.ChannelOrder.rgb),
          _Box(0, 0, outW.toDouble(), outH.toDouble()),
          outW,
          outH,
        )
      : 0.0;
  print(
    '$name  roll=${roll.toStringAsFixed(2)}deg  '
    'box=${clamped.left.toStringAsFixed(0)},${clamped.top.toStringAsFixed(0)},'
    '${clamped.right.toStringAsFixed(0)},${clamped.bottom.toStringAsFixed(0)}  '
    '-> ${outW}x$outH'
    '${options.verify ? '  residual=${residual.toStringAsFixed(2)}deg' : ''}',
  );
  return '$name,$labelCount,${roll.toStringAsFixed(2)},'
      '${clamped.left.toStringAsFixed(0)},${clamped.top.toStringAsFixed(0)},'
      '${clamped.right.toStringAsFixed(0)},${clamped.bottom.toStringAsFixed(0)},'
      '$outW,$outH';
}

/// 検証用: 補正済み画像に既知の台形歪みを与えて「歪んだ写真」を作る。
void _runDistort(_Options options) {
  final dir = Directory(options.photos);
  if (!dir.existsSync()) {
    stderr.writeln('入力ディレクトリがありません: ${options.photos}');
    exitCode = 1;
    return;
  }
  Directory(options.outDir).createSync(recursive: true);
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final decoded = img.decodeJpg(file.readAsBytesSync());
    if (decoded == null) continue;
    final w = decoded.width, h = decoded.height;
    final box = _Box(0, 0, w.toDouble(), h.toDouble());
    final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);
    final map = _distortMap(
      box,
      0,
      options.keystone,
      w.toDouble(),
      h.toDouble(),
    );
    final out = _warpImage(rgb, w, h, map, w, h);
    final name = file.uri.pathSegments.last;
    File('${options.outDir}/$name')
        .writeAsBytesSync(img.encodeJpg(out, quality: 95));
    print('distort: $name (keystone=${options.keystone})');
  }
}

/// 検証用: 2 つのディレクトリの同名 JPEG を画素比較する。
void _runCompare(_Options options) {
  final rightDir = Directory(options.outDir);
  if (!rightDir.existsSync()) {
    stderr.writeln('比較先がありません: ${options.outDir}');
    exitCode = 1;
    return;
  }
  final expected = {
    for (final file in _collectPhotos(options.outDir))
      file.uri.pathSegments.last: file,
  };
  final rows = <String>['file,mean_abs_diff,max_abs_diff,pixels'];
  for (final file in _collectPhotos(options.photos)) {
    final name = file.uri.pathSegments.last;
    final other = expected[name];
    if (other == null) {
      print('$name  (比較先に無し)');
      continue;
    }
    final diff = _meanAbsDiff(file, other);
    if (diff == null) {
      print('$name  (サイズ不一致)');
      continue;
    }
    print('$name  mean=${diff.$1.toStringAsFixed(3)} max=${diff.$2}');
    rows.add('$name,${diff.$1.toStringAsFixed(3)},${diff.$2},${diff.$3}');
  }
  File('${options.outDir}/compare.csv')
      .writeAsStringSync('${rows.join('\r\n')}\r\n');
}

/// 2 枚の RGB 差分の平均・最大を返す。寸法が違えば null。
(double, int, int)? _meanAbsDiff(File one, File other) {
  final first = img.decodeJpg(one.readAsBytesSync());
  final second = img.decodeJpg(other.readAsBytesSync());
  if (first == null || second == null) return null;
  if (first.width != second.width || first.height != second.height) return null;
  final a = first.getBytes(order: img.ChannelOrder.rgb);
  final b = second.getBytes(order: img.ChannelOrder.rgb);
  var sum = 0;
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final delta = (a[i] - b[i]).abs();
    sum += delta;
    if (delta > worst) worst = delta;
  }
  return (sum / a.length, worst, a.length ~/ 3);
}

// ======================================================================
// パネル矩形の推定
// ======================================================================

/// 画像全体を指す番兵矩形。clampTo で実寸に丸められる。
const _Box _fullFrameBox = _Box(0, 0, 1e9, 1e9);

const Set<String> _labelWords = <String>{
  'COOL',
  'COOT',
  'COOC',
  'COO',
  'GREAT',
  'GOOD',
  'BAD',
  'BEST',
  'SCORE',
  'COMBO',
};

/// 生 OCR 結果 JSON から、画像ファイル名 -> ラベル矩形の一覧 を作る。
Map<String, List<_Box>> _loadAnchors(String path) {
  final jsonFile = File(path);
  if (!jsonFile.existsSync()) {
    stderr.writeln('生 OCR JSON がありません: $path');
    exitCode = 1;
    return <String, List<_Box>>{};
  }
  final root = jsonDecode(jsonFile.readAsStringSync()) as Map<String, Object?>;
  final results = (root['results'] as List<Object?>?) ?? const <Object?>[];
  final map = <String, List<_Box>>{};
  for (final entry in results) {
    final item = entry as Map<String, Object?>;
    final name = item['file'] as String? ?? '';
    final boxes = <_Box>[];
    for (final raw in (item['elements'] as List<Object?>?) ?? const []) {
      final element = raw as Map<String, Object?>;
      final box = _labelBox(element);
      if (box != null) boxes.add(box);
    }
    map[name] = boxes;
  }
  return map;
}

/// OCR 要素がラベル語なら、その矩形を返す。
/// 長い文（例: 「SCOREを累計で600万点」）を弾くため、元テキスト長でも判定する。
_Box? _labelBox(Map<String, Object?> element) {
  final text = (element['text'] as String? ?? '').trim();
  if (text.isEmpty || text.length > 10) return null;
  final normalized = text.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
  if (!_labelWords.contains(normalized)) return null;
  final box = element['boundingBox'] as Map<String, Object?>?;
  if (box == null) return null;
  return _Box(
    (box['l'] as num).toDouble(),
    (box['t'] as num).toDouble(),
    (box['r'] as num).toDouble(),
    (box['b'] as num).toDouble(),
  );
}

/// ラベル矩形の外接矩形から、スコアパネル全体の矩形を推定する。
/// 余白はラベル列の高さを基準にするので、撮影位置がずれても同じ比率で効く。
_Box? _panelBoxFromAnchors(List<_Box>? anchors) {
  if (anchors == null || anchors.isEmpty) return null;
  final cluster = _Box.union(anchors);
  final h = cluster.height;
  if (h <= 0) return null;
  return _Box(
    cluster.left - _padLeft * h,
    cluster.top - _padTop * h,
    cluster.right + _padRight * h,
    cluster.bottom + _padBottom * h,
  );
}

/// ラベルが取れなかった画像用の代表矩形（中央値）。
_Box? _medianBox(List<_Box> boxes) {
  if (boxes.isEmpty) return null;
  double median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    return sorted[sorted.length ~/ 2];
  }

  return _Box(
    median(boxes.map((b) => b.left).toList()),
    median(boxes.map((b) => b.top).toList()),
    median(boxes.map((b) => b.right).toList()),
    median(boxes.map((b) => b.bottom).toList()),
  );
}

// ======================================================================
// 傾き（ロール）推定
// ======================================================================

/// パネル矩形の中の明るい文字の行方向分散が最大になる角度を返す（度）。
/// 文字行が水平なら行ごとの和に山が立ち、傾いていると平坦になる性質を使う。
double _estimateRoll(Uint8List rgb, _Box box, int imageWidth, int imageHeight) {
  final left = box.left.floor();
  final top = box.top.floor();
  final columns = box.width.floor() ~/ _rollSampleStep;
  final rows = box.height.floor() ~/ _rollSampleStep;
  if (columns < 8 || rows < 8) return 0;

  final luminance = Int32List(columns * rows);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final px = math.min(left + x * _rollSampleStep, imageWidth - 1);
      final py = math.min(top + y * _rollSampleStep, imageHeight - 1);
      final index = (py * imageWidth + px) * 3;
      luminance[y * columns + x] =
          (rgb[index] * 299 + rgb[index + 1] * 587 + rgb[index + 2] * 114) ~/
          1000;
    }
  }
  return _bestRoll(luminance, columns, rows);
}

/// 与えた輝度格子上で、行射影の集中度が最大になる角度を探索する。
double _bestRoll(Int32List luminance, int width, int height) {
  final threshold = _otsuThreshold(luminance);
  final centerX = (width - 1) / 2;
  final centerY = (height - 1) / 2;
  final bins = Float64List(height * 2 + width);
  var bestScore = -1.0;
  var bestAngle = 0.0;
  final steps = (_rollSearchDeg / _rollStepDeg).round();
  for (var step = -steps; step <= steps; step++) {
    final degrees = step * _rollStepDeg;
    final radians = degrees * math.pi / 180;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    bins.fillRange(0, bins.length, 0);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (luminance[y * width + x] < threshold) continue;
        final rotated = (-(x - centerX) * sinA + (y - centerY) * cosA).round();
        final bin = rotated + height;
        if (bin >= 0 && bin < bins.length) bins[bin] += 1;
      }
    }
    var score = 0.0;
    for (final value in bins) {
      score += value * value;
    }
    if (score > bestScore) {
      bestScore = score;
      bestAngle = degrees;
    }
  }
  return bestAngle;
}

/// 大津の手法で二値化しきい値を求める。
int _otsuThreshold(Int32List luminance) {
  final histogram = Int32List(256);
  for (final value in luminance) {
    histogram[value.clamp(0, 255)]++;
  }
  final total = luminance.length;
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * histogram[i];
  }
  var sumBack = 0.0;
  var weightBack = 0;
  var best = -1.0;
  var threshold = 128;
  for (var i = 0; i < 256; i++) {
    weightBack += histogram[i];
    if (weightBack == 0) continue;
    final weightFore = total - weightBack;
    if (weightFore == 0) break;
    sumBack += i * histogram[i];
    final meanBack = sumBack / weightBack;
    final meanFore = (sumAll - sumBack) / weightFore;
    final between =
        weightBack * weightFore * (meanBack - meanFore) * (meanBack - meanFore);
    if (between > best) {
      best = between;
      threshold = i;
    }
  }
  return threshold;
}

// ======================================================================
// 射影変換
// ======================================================================

/// 正規化矩形（出力座標）を写真上の四角形へ写す対応から、出力->写真 の変換を作る。
_Homography _rectifyMap(
  _Box box,
  double rollDeg,
  double keystone,
  double outW,
  double outH,
) {
  final canonical = _canonicalCorners(outW, outH);
  final panel = _panelCorners(box, rollDeg, keystone);
  return _Homography.fromCorrespondences(canonical, panel);
}

/// 写真->正規化矩形 の変換。台形歪みを注入する検証モードで使う。
_Homography _distortMap(
  _Box box,
  double rollDeg,
  double keystone,
  double outW,
  double outH,
) {
  final canonical = _canonicalCorners(outW, outH);
  final panel = _panelCorners(box, rollDeg, keystone);
  return _Homography.fromCorrespondences(panel, canonical);
}

List<_Point> _canonicalCorners(double width, double height) => <_Point>[
  const _Point(0, 0),
  _Point(width, 0),
  _Point(width, height),
  _Point(0, height),
];

/// 写真上でのパネル四隅。ロール回転と、上辺を狭める台形歪みを掛ける。
List<_Point> _panelCorners(_Box box, double rollDeg, double keystone) {
  final width = box.width;
  final height = box.height;
  final centerX = box.left + width / 2;
  final centerY = box.top + height / 2;
  final radians = rollDeg * math.pi / 180;
  final cosA = math.cos(radians);
  final sinA = math.sin(radians);
  const unit = <(double, double)>[(0, 0), (1, 0), (1, 1), (0, 1)];
  final corners = <_Point>[];
  for (final (u, v) in unit) {
    final dx = (u - 0.5) * width;
    final dy = (v - 0.5) * height;
    // 台形: 上辺(v=0)ほど横方向の幅を (1 - keystone) 倍に狭める。
    final shrink = 1 - keystone * (1 - v);
    corners.add(
      _Point(
        centerX + dx * shrink * cosA - dy * sinA,
        centerY + dx * shrink * sinA + dy * cosA,
      ),
    );
  }
  return corners;
}

/// 8 パラメータの射影変換行列（h33 = 1）。
class _Homography {
  const _Homography(this._m);

  final List<double> _m;

  /// 4 点の対応から行列を作る。from -> to の写像。
  factory _Homography.fromCorrespondences(List<_Point> from, List<_Point> to) {
    final matrix = List<List<double>>.generate(
      8,
      (_) => List<double>.filled(8, 0),
    );
    final vector = List<double>.filled(8, 0);
    for (var i = 0; i < 4; i++) {
      final x = from[i].x, y = from[i].y;
      final u = to[i].x, v = to[i].y;
      matrix[i * 2] = <double>[x, y, 1, 0, 0, 0, -x * u, -y * u];
      matrix[i * 2 + 1] = <double>[0, 0, 0, x, y, 1, -x * v, -y * v];
      vector[i * 2] = u;
      vector[i * 2 + 1] = v;
    }
    return _Homography(_solve(matrix, vector));
  }

  /// 点を写す。
  _Point apply(double x, double y) {
    final m = _m;
    final w = m[6] * x + m[7] * y + 1;
    return _Point(
      (m[0] * x + m[1] * y + m[2]) / w,
      (m[3] * x + m[4] * y + m[5]) / w,
    );
  }
}

/// 部分ピボット付きガウス消去法で連立一次方程式を解く。
List<double> _solve(List<List<double>> matrix, List<double> vector) {
  final n = vector.length;
  for (var column = 0; column < n; column++) {
    var pivot = column;
    for (var row = column + 1; row < n; row++) {
      if (matrix[row][column].abs() > matrix[pivot][column].abs()) pivot = row;
    }
    if (matrix[pivot][column].abs() < 1e-12) {
      throw StateError('ホモグラフィが特異になりました');
    }
    if (pivot != column) {
      final swapRow = matrix[column];
      matrix[column] = matrix[pivot];
      matrix[pivot] = swapRow;
      final swapValue = vector[column];
      vector[column] = vector[pivot];
      vector[pivot] = swapValue;
    }
    for (var row = column + 1; row < n; row++) {
      final factor = matrix[row][column] / matrix[column][column];
      if (factor == 0) continue;
      for (var c = column; c < n; c++) {
        matrix[row][c] -= factor * matrix[column][c];
      }
      vector[row] -= factor * vector[column];
    }
  }
  final solution = List<double>.filled(n, 0);
  for (var row = n - 1; row >= 0; row--) {
    var sum = vector[row];
    for (var column = row + 1; column < n; column++) {
      sum -= matrix[row][column] * solution[column];
    }
    solution[row] = sum / matrix[row][row];
  }
  return solution;
}

// ======================================================================
// 画像の書き換え
// ======================================================================

/// 射影変換で画像を作り直す。出力座標から入力座標を引いて双一次補間する。
img.Image _warpImage(
  Uint8List source,
  int sourceWidth,
  int sourceHeight,
  _Homography map,
  int outWidth,
  int outHeight,
) {
  final buffer = Uint8List(outWidth * outHeight * 3);
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final point = map.apply(x + 0.5, y + 0.5);
      _sampleInto(
        source,
        sourceWidth,
        sourceHeight,
        point.x,
        point.y,
        buffer,
        (y * outWidth + x) * 3,
      );
    }
  }
  return img.Image.fromBytes(
    width: outWidth,
    height: outHeight,
    bytes: buffer.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}

/// 双一次補間した 1 画素を buffer の offset へ書き込む。範囲外は端で丸める。
void _sampleInto(
  Uint8List source,
  int width,
  int height,
  double sx,
  double sy,
  Uint8List buffer,
  int offset,
) {
  final x0 = sx.floor().clamp(0, width - 1);
  final y0 = sy.floor().clamp(0, height - 1);
  final x1 = math.min(x0 + 1, width - 1);
  final y1 = math.min(y0 + 1, height - 1);
  final fx = (sx - x0).clamp(0.0, 1.0);
  final fy = (sy - y0).clamp(0.0, 1.0);
  final topLeft = (y0 * width + x0) * 3;
  final topRight = (y0 * width + x1) * 3;
  final bottomLeft = (y1 * width + x0) * 3;
  final bottomRight = (y1 * width + x1) * 3;
  for (var channel = 0; channel < 3; channel++) {
    final top =
        source[topLeft + channel] * (1 - fx) + source[topRight + channel] * fx;
    final bottom =
        source[bottomLeft + channel] * (1 - fx) +
        source[bottomRight + channel] * fx;
    buffer[offset + channel] = (top * (1 - fy) + bottom * fy).round().clamp(
      0,
      255,
    );
  }
}

// ======================================================================
// 補助
// ======================================================================

/// 写真ディレクトリの JPEG をファイル名順に返す。
List<File> _collectPhotos(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    stderr.writeln('写真ディレクトリがありません: $path');
    exitCode = 1;
    return const <File>[];
  }
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.jpg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

class _Point {
  const _Point(this.x, this.y);

  final double x;
  final double y;
}

/// 画像座標の矩形（左上・右下）。
class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => math.max(right - left, 0);
  double get height => math.max(bottom - top, 0);

  static _Box union(List<_Box> boxes) {
    var left = boxes.first.left;
    var top = boxes.first.top;
    var right = boxes.first.right;
    var bottom = boxes.first.bottom;
    for (final box in boxes) {
      left = math.min(left, box.left);
      top = math.min(top, box.top);
      right = math.max(right, box.right);
      bottom = math.max(bottom, box.bottom);
    }
    return _Box(left, top, right, bottom);
  }

  /// 画像の外へはみ出さないように内側へ寄せる。
  _Box clampTo(int width, int height) => _Box(
    left.clamp(0, width.toDouble()),
    top.clamp(0, height.toDouble()),
    right.clamp(0, width.toDouble()),
    bottom.clamp(0, height.toDouble()),
  );
}
