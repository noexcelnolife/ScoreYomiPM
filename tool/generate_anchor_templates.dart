// ST-3.5: 共通 UI アンカーパック（assets/anchors/hc_v1/）の生成ツール。
//
// 使い方（リポジトリルートで実行・読み取り専用入力/生成物のみ書き込み）:
//   dart run tool/generate_anchor_templates.dart
//   dart run tool/generate_anchor_templates.dart --images=<参照画像ディレクトリ>
//   （testimage/ はリポジトリに同梱していないため、手元のパスを渡す）
//
// 入力（読み取り専用・変更しない）:
//   - test/fixtures/ocr/playshare_batch_results.json（ML Kit 要素 bbox）
//   - <参照画像ディレクトリ>/*.jpg（30 枚の横スクショ・参照画像ソース。既定は testimage/playshare）
// 出力（コミット対象）:
//   - assets/anchors/hc_v1/anchor_pack.json（パック契約 JSON）
//   - assets/anchors/hc_v1/{gauge_header,settings_normal,difficulty_ex}.png
//   - assets/anchors/hc_v1/manifest.json（生成由来: 参照画像名 + bbox）
//
// WHY lib/ocr/ui_anchor.dart を import しない: 同ファイルは dart:ui
//（Offset/Rect）と flutter/services（rootBundle）に依存し、純 Dart CLI
// からは解決できない。代わりに探索数式（縮小率・Pearson NCC・列強度・
// 探索窓・閾値）を named 定数ごとミラーし、生成時検証が実行時 detect と
// 同一条件になるようにする（齟齬は asset 契約テストで検知）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'tool_paths.dart';

/// 要素 bbox の取得元フィクスチャ（読み取り専用）。
const String _fixturePath = 'test/fixtures/ocr/playshare_batch_results.json';

/// 参照画像ディレクトリ（読み取り専用・変更禁止領域）。
/// 実画像は公開リポジトリに同梱していないため、main の先頭で
/// `--images=<dir>` の指定があれば差し替える。
String _imageDir = 'testimage/playshare';

/// 出力先（コミット対象・上書き冪等）。
const String _outDir = 'assets/anchors/hc_v1';

/// 縮小率（lib/ocr/ui_anchor.dart の _downscale のミラー・設計 §1.2）。
const int _downscale = 4;

/// テンプレート切り出しマージン（設計 §1.2: ML Kit bbox + 6px）。
const int _templateMarginPx = 6;

/// NCC 採用最低スコア（_nccScoreThreshold のミラー・設計 §1.4）。
const double _nccScoreThreshold = 0.55;

/// columnEdge 採用最低列強度（_columnEdgeMinStrength のミラー・0-255）。
const double _columnEdgeMinStrength = 25;

/// NCC 探索窓半径（_nccSearchRadiusPx のミラー・正規化前 px）。
const double _nccSearchRadiusPx = 96;

/// columnEdge 探索窓半径（_columnEdgeSearchRadiusPx のミラー）。
const double _columnEdgeSearchRadiusPx = 12;

/// frameRight の canonical x（設計 §1.1: 枠線 x≈536px/1200 実測 30/30）。
const double _frameRightCanonicalX = 0.4467;

/// frameRight の canonical y（列エッジに y 方向の意味はないため固定値）。
const double _frameRightCanonicalY = 0.5;

/// フィクスチャ 1 要素のアンカー候補（読み取り専用の抽出結果）。
class _Candidate {
  const _Candidate(this.file, this.bbox, this.cx, this.cy);

  final String file;
  final Map<String, dynamic> bbox;
  final double cx;
  final double cy;
}

/// 1 アンカー分の導出結果（canonical・参照画像・候補統計）。
class _AnchorDerivation {
  const _AnchorDerivation({
    required this.canonicalX,
    required this.canonicalY,
    required this.reference,
    required this.matchedImages,
  });

  final double canonicalX;
  final double canonicalY;
  final _Candidate reference;
  final int matchedImages;
}

void main(List<String> args) {
  _imageDir = resolveImageDir(args, _imageDir);
  ensureImageDirExists(_imageDir);
  final fixture = _loadFixture();
  final files = _imageFileNames(fixture);
  final candidates = _collectCandidates(fixture, files);
  final derivations = <String, _AnchorDerivation>{};
  for (final entry in candidates.entries) {
    if (entry.value.isEmpty) {
      throw StateError('anchor "${entry.key}" has no candidates in fixture');
    }
    derivations[entry.key] = _deriveAnchor(entry.key, entry.value);
  }
  Directory(_outDir).createSync(recursive: true);
  final templateFiles = <String, String>{
    'gaugeHeader': 'gauge_header.png',
    'settingsNormal': 'settings_normal.png',
    'difficultyEx': 'difficulty_ex.png',
  };
  for (final entry in templateFiles.entries) {
    _writeTemplatePng(
      derivations[entry.key]!,
      '$_imageDir/${derivations[entry.key]!.reference.file}',
      '$_outDir/${entry.value}',
    );
  }
  _writePackJson(derivations, templateFiles);
  _writeManifest(derivations, templateFiles, files.length);
  _validate(derivations, templateFiles, files);
}

Map<String, dynamic> _loadFixture() {
  final text = File(_fixturePath).readAsStringSync();
  return jsonDecode(text) as Map<String, dynamic>;
}

/// フィクスチャの画像ファイル名（決定的順序）。
List<String> _imageFileNames(Map<String, dynamic> fixture) {
  final results = fixture['results'] as List<dynamic>;
  final names = <String>[];
  for (final r in results) {
    final file = (r as Map<String, dynamic>)['file'] as String;
    if (File('$_imageDir/$file').existsSync()) {
      names.add(file);
    }
  }
  return names..sort();
}

/// 全画像を走査してアンカー候補（ラベル一致要素）を収集する。
///
/// WHY 実画像で寸法を取る: フィクスチャには画像寸法が無く、正規化座標は
/// 実画像寸法でのみ定義できる（stats §2: 19 パターン・正規化必須）。
Map<String, List<_Candidate>> _collectCandidates(
  Map<String, dynamic> fixture,
  List<String> files,
) {
  final results = fixture['results'] as List<dynamic>;
  final byFile = <String, Map<String, dynamic>>{};
  for (final r in results) {
    byFile[(r as Map<String, dynamic>)['file'] as String] = r;
  }
  final out = <String, List<_Candidate>>{
    'gaugeHeader': <_Candidate>[],
    'settingsNormal': <_Candidate>[],
    'difficultyEx': <_Candidate>[],
  };
  for (final file in files) {
    final size = _imageSize('$_imageDir/$file');
    final w = size.$1.toDouble();
    final h = size.$2.toDouble();
    for (final e in (byFile[file]!['elements'] as List<dynamic>)) {
      final map = e as Map<String, dynamic>;
      final bb = map['boundingBox'] as Map<String, dynamic>;
      final cx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
      final cy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
      final text = (map['text'] as String).trim().toUpperCase();
      if (_isGaugeHeader(text, cy)) {
        out['gaugeHeader']!.add(_Candidate(file, bb, cx, cy));
      }
      if (_isSettingsNormal(text, cx, cy)) {
        out['settingsNormal']!.add(_Candidate(file, bb, cx, cy));
      }
      if (_isDifficultyEx(text, cy)) {
        out['difficultyEx']!.add(_Candidate(file, bb, cx, cy));
      }
    }
  }
  return out;
}

/// GAUGE ヘッダーラベル（ヘッダー帯 cy [0.30,0.40]）。
///
/// WHY 誤読語を含める: ML Kit は GAUGE を 0% 正読（系統誤読 GROOUE・設計
/// §1.2）のため、誤読テキストでも帯内位置で候補にする。
bool _isGaugeHeader(String text, double cy) {
  return (text.contains('GAU') || text.contains('GROU')) &&
      cy >= 0.30 &&
      cy <= 0.40;
}

/// 設定バンド NORMAL（右列 cx ≥ 0.65・cy ≥ 0.60・観測のみアンカー）。
///
/// WHY 右列限定: 設定バンドには左右 2 列の NORMAL 系ラベルがあり
///（左列 cx≈0.635・右列 cx≈0.709）、テンプレ整合のため右列に限定する。
bool _isSettingsNormal(String text, double cx, double cy) {
  return text.contains('MAL') && cy >= 0.60 && cx >= 0.65;
}

/// 難易度 EX（上部難易度行 cy ≤ 0.20）。
bool _isDifficultyEx(String text, double cy) {
  return text == 'EX' && cy <= 0.20;
}

/// 正規化座標の median（偶数は中央 2 値の平均・決定的）。
double _median(List<double> values) {
  final sorted = List<double>.of(values)..sort();
  final n = sorted.length;
  if (n.isOdd) {
    return sorted[n ~/ 2];
  }
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// 1 アンカー分の canonical（median 中心）と参照画像を導出する。
///
/// WHY median 参照: 参照画像を母集団の中央に最も近い要素から切ることで、
/// テンプレが極端な外れ画像に偏らない（生成の決定性も filename tie-break
/// で保つ）。
_AnchorDerivation _deriveAnchor(String id, List<_Candidate> candidates) {
  final mx = _median(candidates.map((c) => c.cx).toList());
  final my = _median(candidates.map((c) => c.cy).toList());
  _Candidate best = candidates.first;
  var bestDist = double.infinity;
  for (final c in candidates) {
    final dx = c.cx - mx;
    final dy = c.cy - my;
    final dist = dx * dx + dy * dy;
    final tie = dist == bestDist && c.file.compareTo(best.file) < 0;
    if (dist < bestDist || tie) {
      bestDist = dist;
      best = c;
    }
  }
  stdout.writeln(
    'derive $id: n=${candidates.length} median=($mx, $my) '
    'reference=${best.file} bbox=${best.bbox}',
  );
  return _AnchorDerivation(
    canonicalX: double.parse(mx.toStringAsFixed(4)),
    canonicalY: double.parse(my.toStringAsFixed(4)),
    reference: best,
    matchedImages: candidates.length,
  );
}

/// 参照画像から bbox + [_templateMarginPx] マージンで切り出し PNG 保存。
void _writeTemplatePng(_AnchorDerivation d, String refPath, String outPath) {
  final image = img.decodeImage(File(refPath).readAsBytesSync());
  if (image == null) {
    throw StateError('cannot decode reference image: $refPath');
  }
  final bb = d.reference.bbox;
  // WHY num 経由の int 化: フィクスチャ JSON の bbox 値は double 表記
  //（例 653.0）のため as int は TypeError になる。
  final left = math.max(0, (bb['l'] as num).toInt() - _templateMarginPx);
  final top = math.max(0, (bb['t'] as num).toInt() - _templateMarginPx);
  final right = math.min(
    image.width,
    (bb['r'] as num).toInt() + _templateMarginPx,
  );
  final bottom = math.min(
    image.height,
    (bb['b'] as num).toInt() + _templateMarginPx,
  );
  final crop = img.copyCrop(
    image,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  File(outPath).writeAsBytesSync(img.encodePng(crop));
  stdout.writeln('template $outPath (${right - left}x${bottom - top})');
}

/// パック契約 JSON（loadFromAssets のパース契約と完全一致）。
void _writePackJson(
  Map<String, _AnchorDerivation> d,
  Map<String, String> templateFiles,
) {
  final definitions = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'frameRight',
      'kind': 'columnEdge',
      'canonical': {'x': _frameRightCanonicalX, 'y': _frameRightCanonicalY},
      'threshold': _columnEdgeMinStrength / 255,
      'template': null,
    },
    for (final entry in templateFiles.entries)
      <String, dynamic>{
        'id': entry.key,
        'kind': 'ncc',
        'canonical': {
          'x': d[entry.key]!.canonicalX,
          'y': d[entry.key]!.canonicalY,
        },
        'threshold': _nccScoreThreshold,
        'template': entry.value,
      },
  ];
  final json = jsonEncode({'definitions': definitions});
  File('$_outDir/anchor_pack.json').writeAsStringSync('$json\n');
  stdout.writeln('pack $_outDir/anchor_pack.json written');
}

/// 生成由来の記録（参照画像名 + bbox・リード受入条件の再確認事項）。
void _writeManifest(
  Map<String, _AnchorDerivation> d,
  Map<String, String> templateFiles,
  int imageCount,
) {
  final anchors = <String, dynamic>{};
  for (final entry in templateFiles.entries) {
    final a = d[entry.key]!;
    anchors[entry.key] = {
      'template': entry.value,
      'referenceImage': a.reference.file,
      'bbox': a.reference.bbox,
      'cropMarginPx': _templateMarginPx,
      'canonical': {'x': a.canonicalX, 'y': a.canonicalY},
      'matchedImages': a.matchedImages,
    };
  }
  anchors['frameRight'] = {
    'template': null,
    'canonical': {'x': _frameRightCanonicalX, 'y': _frameRightCanonicalY},
    'basis': 'design §1.1 measured edge x≈536px/1200 (30/30)',
    'matchedImages': imageCount,
  };
  final manifest = {
    'version': 'hc_v1',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'generator': 'tool/generate_anchor_templates.dart',
    'sourceFixture': _fixturePath,
    'sourceImages': '${recordedPath(_imageDir)}/',
    'imageCount': imageCount,
    'thresholdNote':
        'definition.threshold mirrors lib/ocr/ui_anchor.dart '
        'named constants (_nccScoreThreshold=0.55, '
        '_columnEdgeMinStrength=25/255); runtime gates are the code '
        'constants and the asset contract test pins the equality',
    'matchers': {
      'gaugeHeader': "text contains 'GAU' or 'GROU', cy in [0.30, 0.40]",
      'settingsNormal': "text contains 'MAL', cy >= 0.60, cx >= 0.65",
      'difficultyEx': "text == 'EX', cy <= 0.20",
    },
    'anchors': anchors,
  };
  File('$_outDir/manifest.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stdout.writeln('manifest $_outDir/manifest.json written');
}

/// 生成パックの実行時同等検証（detect の数式ミラーで 30 枚全走査）。
void _validate(
  Map<String, _AnchorDerivation> d,
  Map<String, String> templateFiles,
  List<String> files,
) {
  final templates = <String, (int, int, Uint8List)>{};
  for (final entry in templateFiles.entries) {
    final bytes = File('$_outDir/${entry.value}').readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw StateError('cannot decode generated template: ${entry.value}');
    }
    final small = img.copyResize(
      image,
      width: image.width ~/ _downscale,
      height: image.height ~/ _downscale,
      interpolation: img.Interpolation.average,
    );
    templates[entry.key] = (small.width, small.height, _gray(small));
  }
  stdout.writeln(
    '--- validation (mirror of lib/ocr/ui_anchor.dart detect) ---',
  );
  for (final file in files) {
    final image = img.decodeImage(File('$_imageDir/$file').readAsBytesSync());
    if (image == null) {
      throw StateError('cannot decode image: $_imageDir/$file');
    }
    final small = img.copyResize(
      image,
      width: image.width ~/ _downscale,
      height: image.height ~/ _downscale,
      interpolation: img.Interpolation.average,
    );
    _validateOnImage(
      d,
      templates,
      file,
      image.width,
      image.height,
      small.width,
      small.height,
      _gray(small),
    );
  }
  _printValidationSummary(d, templates, files);
}

/// 1 画像分の検証（canonical 近傍探索・閾値ゲートまで detect と同式）。
void _validateOnImage(
  Map<String, _AnchorDerivation> d,
  Map<String, (int, int, Uint8List)> templates,
  String file,
  int fullWidth,
  int fullHeight,
  int w,
  int h,
  Uint8List gray,
) {
  final hits = <String, (double, double, double)>{};
  for (final id in templates.keys) {
    final def = d[id]!;
    final (tw, th, tgray) = templates[id]!;
    final hit = _detectNccMirror(def, tw, th, tgray, gray, w, h);
    if (hit == null) {
      continue;
    }
    hits[id] = hit;
    _nccHitCounts[id] = _nccHitCounts[id]! + 1;
    _nccScores[id]!.add(hit.$1);
    final gt = _gtNear(id, file, hit.$2, hit.$3, fullWidth, fullHeight);
    if (gt != null) {
      final dx = hit.$2 - gt.$1;
      final dy = hit.$3 - gt.$2;
      _errors[id]!.add(math.sqrt(dx * dx + dy * dy));
    }
  }
  final frameRight = _detectColumnEdgeMirror(_frameRightCanonicalX, w, h, gray);
  if (frameRight != null) {
    _frameRightHits++;
    _errors['frameRight']!.add((frameRight.$1 - _frameRightCanonicalX).abs());
  }
  final sb = StringBuffer(file);
  for (final id in templates.keys) {
    final hit = hits[id];
    sb.write(' | $id=${hit == null ? '-' : hit.$1.toStringAsFixed(3)}');
  }
  sb.write(' | frameRight=');
  sb.write(frameRight == null ? '-' : frameRight.$1.toStringAsFixed(4));
  stdout.writeln(sb.toString());
}

/// 実行時 detect と同式の NCC 探索（戻り値: (score, cxNorm, cyNorm)）。
(double, double, double)? _detectNccMirror(
  _AnchorDerivation def,
  int tw,
  int th,
  Uint8List tgray,
  Uint8List gray,
  int w,
  int h,
) {
  final n = tw * th;
  var tSum = 0;
  var tSumSq = 0;
  for (var i = 0; i < n; i++) {
    final v = tgray[i];
    tSum += v;
    tSumSq += v * v;
  }
  final tMean = tSum / n;
  final tVar = tSumSq / n - tMean * tMean;
  if (tVar <= 0) {
    return null;
  }
  final predictedCx = def.canonicalX * w;
  final predictedCy = def.canonicalY * h;
  final radius = (_nccSearchRadiusPx / _downscale).ceil();
  final uMin = (predictedCx - radius - tw / 2).floor().clamp(0, w - tw).toInt();
  final uMax = (predictedCx + radius - tw / 2).floor().clamp(0, w - tw).toInt();
  final vMin = (predictedCy - radius - th / 2).floor().clamp(0, h - th).toInt();
  final vMax = (predictedCy + radius - th / 2).floor().clamp(0, h - th).toInt();
  var bestScore = 0.0;
  var bestU = -1;
  var bestV = -1;
  for (var v = vMin; v <= vMax; v++) {
    for (var u = uMin; u <= uMax; u++) {
      final score = _nccAtMirror(tw, th, tgray, gray, w, u, v, n, tMean, tVar);
      if (score > bestScore) {
        bestScore = score;
        bestU = u;
        bestV = v;
      }
    }
  }
  if (bestU < 0 || bestScore < _nccScoreThreshold) {
    return null;
  }
  return (bestScore, (bestU + (tw - 1) / 2) / w, (bestV + (th - 1) / 2) / h);
}

/// (u, v) 左上の窓とテンプレの Pearson 相関（_nccAt のミラー・0..1）。
double _nccAtMirror(
  int tw,
  int th,
  Uint8List tgray,
  Uint8List gray,
  int w,
  int u,
  int v,
  int n,
  double tMean,
  double tVar,
) {
  var iSum = 0;
  var iSumSq = 0;
  var cross = 0;
  var k = 0;
  for (var y = v; y < v + th; y++) {
    var idx = y * w + u;
    for (var x = 0; x < tw; x++) {
      final pixel = gray[idx];
      iSum += pixel;
      iSumSq += pixel * pixel;
      cross += tgray[k] * pixel;
      k++;
      idx++;
    }
  }
  final iMean = iSum / n;
  final iVar = iSumSq / n - iMean * iMean;
  if (iVar <= 0) {
    return 0;
  }
  final numerator = cross / n - tMean * iMean;
  final denominator = math.sqrt(tVar * iVar);
  final score = numerator / denominator;
  if (score.isNaN) {
    return 0;
  }
  return score.clamp(0.0, 1.0).toDouble();
}

/// 実行時 detect と同式の列エッジ探索（戻り値: (cxNorm, strength)）。
(double, double)? _detectColumnEdgeMirror(
  double canonicalX,
  int w,
  int h,
  Uint8List gray,
) {
  if (w < 2 || h < 1) {
    return null;
  }
  final strengths = Float64List(w);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w - 1; x++) {
      strengths[x] += (gray[y * w + x + 1] - gray[y * w + x]).abs();
    }
  }
  for (var x = 0; x < w - 1; x++) {
    strengths[x] /= h;
  }
  final predicted = canonicalX * w;
  final radius = (_columnEdgeSearchRadiusPx / _downscale).ceil();
  final minCol = (predicted - radius).floor().clamp(0, w - 2).toInt();
  final maxCol = (predicted + radius).floor().clamp(0, w - 2).toInt();
  var bestX = -1;
  var bestStrength = 0.0;
  for (var x = minCol; x <= maxCol; x++) {
    if (strengths[x] > bestStrength) {
      bestStrength = strengths[x];
      bestX = x;
    }
  }
  if (bestX < 0 || bestStrength < _columnEdgeMinStrength) {
    return null;
  }
  return (bestX / w, bestStrength);
}

/// 検証誤差集約（anchor id → 正規化誤差のリスト）。
final Map<String, List<double>> _errors = {
  'gaugeHeader': <double>[],
  'settingsNormal': <double>[],
  'difficultyEx': <double>[],
  'frameRight': <double>[],
};

/// NCC ヒット位置の GT 中心（同一画像内の同ラベル要素・正規化座標）。
///
/// WHY 同画像内照合: フィクスチャ要素 bbox が本パイプラインで得られる
/// 最良の GT であり、設計 §1.2 の誤差評価（テンプレ中心 vs GT 中心）と
/// 同一定義。同ラベル要素が無い画像は null（誤差集約から除外）。
(double, double)? _gtNear(
  String id,
  String file,
  double cx,
  double cy,
  int fullWidth,
  int fullHeight,
) {
  final r = _fixtureResultsCache[file];
  if (r == null) {
    return null;
  }
  final w = fullWidth.toDouble();
  final h = fullHeight.toDouble();
  double? bestDist;
  (double, double)? best;
  for (final e in (r['elements'] as List<dynamic>)) {
    final map = e as Map<String, dynamic>;
    final bb = map['boundingBox'] as Map<String, dynamic>;
    final ecx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
    final ecy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
    if (!_matchesAnchorId(
      id,
      (map['text'] as String).trim().toUpperCase(),
      ecx,
      ecy,
    )) {
      continue;
    }
    final dx = ecx - cx;
    final dy = ecy - cy;
    final dist = dx * dx + dy * dy;
    if (bestDist == null || dist < bestDist) {
      bestDist = dist;
      best = (ecx, ecy);
    }
  }
  return best;
}

/// 検証照合用のアンカー別ラベル判定（生成マッチャと同じ述語）。
bool _matchesAnchorId(String id, String text, double cx, double cy) {
  return switch (id) {
    'gaugeHeader' => _isGaugeHeader(text, cy),
    'settingsNormal' => _isSettingsNormal(text, cx, cy),
    'difficultyEx' => _isDifficultyEx(text, cy),
    _ => false,
  };
}

/// フィクスチャ結果の file → result マップ（遅延構築キャッシュ）。
Map<String, Map<String, dynamic>> get _fixtureResultsCache {
  final cache = _fixtureResultsCacheField;
  if (cache != null) {
    return cache;
  }
  final fixture = _loadFixture();
  final map = <String, Map<String, dynamic>>{};
  for (final r in fixture['results'] as List<dynamic>) {
    final m = r as Map<String, dynamic>;
    map[m['file'] as String] = m;
  }
  _fixtureResultsCacheField = map;
  return map;
}

Map<String, Map<String, dynamic>>? _fixtureResultsCacheField;

/// 検証サマリ（ヒット率・平均スコア・誤差中央値）を印刷する。
void _printValidationSummary(
  Map<String, _AnchorDerivation> d,
  Map<String, (int, int, Uint8List)> templates,
  List<String> files,
) {
  stdout.writeln('--- summary ---');
  for (final id in _errors.keys) {
    final errs = _errors[id]!;
    errs.sort();
    final medianErr = errs.isEmpty
        ? double.nan
        : (errs.length.isOdd
              ? errs[errs.length ~/ 2]
              : (errs[errs.length ~/ 2 - 1] + errs[errs.length ~/ 2]) / 2);
    final idHits = id == 'frameRight' ? _frameRightHits : _nccHitCounts[id]!;
    final scores = id == 'frameRight' ? <double>[] : _nccScores[id]!;
    final avgScore = scores.isEmpty
        ? double.nan
        : scores.reduce((a, b) => a + b) / scores.length;
    stdout.writeln(
      '$id: hits=$idHits/${files.length} '
      'avgScore=${avgScore.isNaN ? '-' : avgScore.toStringAsFixed(3)} '
      'medianErrPx=${medianErr.isNaN ? '-' : (medianErr * 1200).toStringAsFixed(1)} '
      '(reference width 1200px)',
    );
  }
}

/// NCC ヒット数の集約（anchor id → count）。
final Map<String, int> _nccHitCounts = {
  'gaugeHeader': 0,
  'settingsNormal': 0,
  'difficultyEx': 0,
};

/// NCC スコアの集約（anchor id → scores）。
final Map<String, List<double>> _nccScores = {
  'gaugeHeader': <double>[],
  'settingsNormal': <double>[],
  'difficultyEx': <double>[],
};

/// frameRight ヒット数。
int _frameRightHits = 0;

/// 画像寸法（幅, 高さ）を JPEG から取得する。
(int, int) _imageSize(String path) {
  final image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) {
    throw StateError('cannot decode image: $path');
  }
  return (image.width, image.height);
}

/// [image] を 0..255 輝度 row-major 配列へ変換（_grayscaleOf のミラー）。
Uint8List _gray(img.Image image) {
  final gray = Uint8List(image.width * image.height);
  var i = 0;
  for (final p in image) {
    final lum = p.luminance.toInt();
    gray[i++] = lum < 0 ? 0 : (lum > 255 ? 255 : lum);
  }
  return gray;
}
