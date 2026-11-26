// ac_v1 行推定フォールバック（01a2065a Q3）のための隣接行デルタ実測ツール。
//
// 目的:
// - ac レイアウトの縦チェーン（SCORE→BEST→COOL→GREAT→GOOD→BAD→COMBO）の
//   隣接ラベル間デルタ（Δcy・Δcx・正規化座標）を 30 枚実機計測フィクスチャ
//   から実測し、ac_row_estimator.dart の定数表の根拠を出す。
// - デルタがバケット（主群 4:3 横 / 16:9 横 / 縦）で異なるかを確認する
//   （WHY: ユーザー裁定「16:9 横 5 枚・4:3 縦 2 枚が canonical seed から
//   ずれる」の実体が行間デルタの差なのかをデータで判定する。異なれば
//   推定は定数 1 種では足りず、設計を再考する）。
// - ラベル要素の正規化高さを実測し、推定 spec の y 半幅（隣行混入排除用）の
//   根拠を出す。
// - HV8q_4WaEAEbLHQ（score ラベル誤読の疑い）と HWxJNv（COOL ラベル不在の
//   疑い）の全要素をダンプし、設計前提（アンカー不在の実態）を検証する。
//
// 入力: test/fixtures/ocr/ac_hc_batch_results.json
// （tool/build_ac_fixture.dart が lib/ocr/batch_measurement_output.txt から構築。
//   ML Kit 全体 OCR の生要素列・寸法焼き込み済み）。
//
// 使い方: C:\dev\flutter\bin\dart.bat run tool/measure_ac_row_deltas.dart
// 出力は標準出力。リダイレクトして tool/ac_row_deltas_output.txt に保存する
// （証跡。実装定数はこの出力の中央値を写す）。
//
// ignore_for_file: avoid_print
// （WHY: 測定結果の標準出力が本ツールの目的。arcade_photo_dims.dart /
//  arcade_probe.dart と同一の慣行）
library;

import 'dart:convert';
import 'dart:io';

/// 縦チェーンのラベル（上→下）。BEST は抽出対象フィールドではないが
/// （NumericFieldKind に存在しない）、score 推定の最寄り参照になり得るため
/// チェーン节点に含める。
const List<String> _chainLabels = [
  'SCORE',
  'BEST',
  'COOL',
  'GREAT',
  'GOOD',
  'BAD',
  'COMBO',
];

void main() {
  final fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';
  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final results = (fixture['results'] as List).cast<Map<String, dynamic>>();
  print('fixture: $fixturePath records=${results.length}');

  // バケット分類（tool/generate_ac_anchor_templates.dart の _isBucketPhoto と
  // 同一の主群定義 + 16:9 横 + 縦。どちらにも属さない中間は other）。
  final buckets = <String, List<Map<String, dynamic>>>{};
  for (final r in results) {
    buckets.putIfAbsent(_bucketOf(r), () => []).add(r);
  }
  print('');
  print('## bucket sizes');
  for (final entry in buckets.entries) {
    print('${entry.key}: ${entry.value.length}');
  }

  // 隣接ペアのデルタ実測（全バケット + バケット別）。
  print('');
  print('## adjacent chain deltas (normalized, per-photo, both detected)');
  _printDeltaTable('ALL', results);
  for (final entry in buckets.entries) {
    _printDeltaTable(entry.key, entry.value);
  }

  // ラベル要素の正規化高さ（推定 spec の y 半幅の根拠）。
  print('');
  print('## label bbox heights (normalized, median)');
  _printLabelHeights('ALL', results);

  // 設計前提の検証: 誤読/不在ラベルの実態ダンプ。
  _dumpPhotoElements(results, 'HV8q');
  _dumpPhotoElements(results, 'HWxJNv');
}

/// 記録をバケットへ分類する（主群 4:3 横 / 16:9 横 / 縦 / other）。
String _bucketOf(Map<String, dynamic> r) {
  final w = (r['imageWidth'] as num).toInt();
  final h = (r['imageHeight'] as num).toInt();
  final aspect = w / h;
  if (h > w) {
    return 'portrait';
  }
  if (aspect >= 1.7) {
    return 'wide169';
  }
  if (aspect >= 1.25 && aspect <= 1.45) {
    return 'main43';
  }
  return 'other';
}

/// 1 記録からラベル種別 → 正規化中心座標マップを作る（完全一致・大文字化）。
///
/// WHY 完全一致: 抽出コア（FieldExtractor._collectAnchors）と同一規則。
/// 誤読要素（scORE 等）はここでは参照アンカーにならない（保守的）。
Map<String, ({double cx, double cy, double h})> _labelPositions(
  Map<String, dynamic> r,
) {
  final w = (r['imageWidth'] as num).toDouble();
  final h = (r['imageHeight'] as num).toDouble();
  final positions = <String, ({double cx, double cy, double h})>{};
  for (final e in (r['elements'] as List).cast<Map<String, dynamic>>()) {
    final box = e['boundingBox'] as Map<String, dynamic>;
    final left = (box['l'] as num).toDouble();
    final top = (box['t'] as num).toDouble();
    final right = (box['r'] as num).toDouble();
    final bottom = (box['b'] as num).toDouble();
    final text = ((e['text'] as String?) ?? '').trim().toUpperCase();
    if (_chainLabels.contains(text) && !positions.containsKey(text)) {
      positions[text] = (
        cx: (left + right) / 2 / w,
        cy: (top + bottom) / 2 / h,
        h: (bottom - top) / h,
      );
    }
  }
  return positions;
}

/// バケット群の隣接デルタ表を出力する。
void _printDeltaTable(String bucket, List<Map<String, dynamic>> results) {
  print('-- bucket: $bucket --');
  for (var i = 0; i < _chainLabels.length - 1; i++) {
    final upper = _chainLabels[i];
    final lower = _chainLabels[i + 1];
    final dys = <double>[];
    final dxs = <double>[];
    for (final r in results) {
      final pos = _labelPositions(r);
      final u = pos[upper];
      final l = pos[lower];
      if (u == null || l == null) {
        continue;
      }
      dys.add(l.cy - u.cy);
      dxs.add(l.cx - u.cx);
    }
    if (dys.isEmpty) {
      print('$upper->$lower n=0 (no co-detected photo)');
      continue;
    }
    dys.sort();
    dxs.sort();
    print(
      '$upper->$lower n=${dys.length} '
      'dCy median=${_median(dys).toStringAsFixed(4)} '
      'p5=${_percentile(dys, 0.05).toStringAsFixed(4)} '
      'p95=${_percentile(dys, 0.95).toStringAsFixed(4)} '
      'dCx median=${_median(dxs).toStringAsFixed(4)} '
      'p5=${_percentile(dxs, 0.05).toStringAsFixed(4)} '
      'p95=${_percentile(dxs, 0.95).toStringAsFixed(4)}',
    );
  }
}

/// ラベル要素の正規化高さの中央値を出力する。
void _printLabelHeights(String bucket, List<Map<String, dynamic>> results) {
  print('-- bucket: $bucket --');
  for (final label in _chainLabels) {
    final heights = <double>[];
    for (final r in results) {
      final pos = _labelPositions(r)[label];
      if (pos != null) {
        heights.add(pos.h);
      }
    }
    if (heights.isEmpty) {
      print('$label n=0');
      continue;
    }
    heights.sort();
    print(
      '$label n=${heights.length} h median='
      '${_median(heights).toStringAsFixed(4)} '
      'p95=${_percentile(heights, 0.95).toStringAsFixed(4)}',
    );
  }
}

/// 写真名が [prefix] で始まる記録の全要素をダンプする（設計前提の検証用）。
void _dumpPhotoElements(List<Map<String, dynamic>> results, String prefix) {
  print('');
  print('## elements of photos starting with "$prefix"');
  for (final r in results) {
    final file = (r['file'] as String?) ?? '';
    if (!file.contains(prefix)) {
      continue;
    }
    final w = (r['imageWidth'] as num).toInt();
    final h = (r['imageHeight'] as num).toInt();
    print('-- $file (${w}x$h) --');
    for (final e in (r['elements'] as List).cast<Map<String, dynamic>>()) {
      final box = e['boundingBox'] as Map<String, dynamic>;
      final left = (box['l'] as num).toDouble();
      final top = (box['t'] as num).toDouble();
      final right = (box['r'] as num).toDouble();
      final bottom = (box['b'] as num).toDouble();
      final cx = ((left + right) / 2 / w).toStringAsFixed(4);
      final cy = ((top + bottom) / 2 / h).toStringAsFixed(4);
      final text = (e['text'] as String?) ?? '';
      print('  cy=$cy cx=$cx text="$text"');
    }
  }
}

/// 中央値（要素数が偶数のときは中間 2 値の平均）。
double _median(List<double> sorted) {
  final n = sorted.length;
  if (n.isOdd) {
    return sorted[n ~/ 2];
  }
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// [fraction] 位（0..1）のパーセンタイル。
double _percentile(List<double> sorted, double fraction) {
  final index = (fraction * (sorted.length - 1)).round();
  return sorted[index];
}
