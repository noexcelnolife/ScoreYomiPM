//
// ac_v1 列窓・同一直行許容の実測校正ツール。
//
// 使い方（リポジトリルートで実行）:
//   dart run tool/measure_ac_windows.dart
//
// 入力: test/fixtures/ocr/ac_hc_batch_results.json（30 枚実機計測）
// 出力: stdout（フィールド別のアンカー↔値 相対 dx/dy 分布・失敗モード集計・
//        ラベル canonical 中央値）→ field_extractor.dart の _acV1Windows と
//        anchor_pack.json の canonical を実測値で更新する根拠。
//
// WHY 実測から算出する: _acV1Windows は暫定見積り（FIXME 済）で、実データは
// 写真フレーミング差が大きい。ラベル基準の相対 dx はフレーミング不変なので、
// 実測分布から窓を決めるのが唯一の正当な方法。
import 'dart:convert';
import 'dart:io';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

/// ラベル語彙（field_extractor.dart _anchorKinds の ac 該当分をミラー）。
const Map<String, String> _anchorTextToKind = {
  'SCORE': 'score',
  'COOL': 'cool',
  'GREAT': 'great',
  'GOOD': 'good',
  'BAD': 'bad',
  'COMBO': 'maxCombo',
  'MAX COMBO': 'maxCombo',
};

/// 連結形検出（COMBO0 / GREAT143 等・label+digits）。
final RegExp _mergedPattern = RegExp(
  r'^(SCORE|COOL|GREAT|GOOD|BAD|COMBO)(\d{1,6})$',
);

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final results = fixture['results'] as List<dynamic>;
  final samples = <String, List<_PairSample>>{
    for (final k in {'score', 'cool', 'great', 'good', 'bad', 'maxCombo'})
      k: <_PairSample>[],
  };
  final anchorPositions = <String, List<_PairSample>>{};
  final failures = <_Failure>[];
  for (final r in results) {
    _processRecord(
      r as Map<String, dynamic>,
      samples,
      anchorPositions,
      failures,
    );
  }
  _printPairStats(samples);
  _printAnchorStats(anchorPositions);
  _printFailures(failures);
}

class _PairSample {
  _PairSample(this.file, this.dx, this.dy);
  final String file;
  final double dx;
  final double dy;
}

class _Failure {
  _Failure(this.file, this.kind, this.reason);
  final String file;
  final String kind;
  final String reason;
}

void _processRecord(
  Map<String, dynamic> rec,
  Map<String, List<_PairSample>> samples,
  Map<String, List<_PairSample>> anchorPositions,
  List<_Failure> failures,
) {
  final file = rec['file'] as String;
  final w = (rec['imageWidth'] as num).toDouble();
  final h = (rec['imageHeight'] as num).toDouble();
  final elements = rec['elements'] as List<dynamic>;
  final anchors = <String, ({double cx, double cy})>{};
  for (final e in elements) {
    final map = e as Map<String, dynamic>;
    final text = (map['text'] as String).trim().toUpperCase();
    final kind = _anchorTextToKind[text];
    final bb = map['boundingBox'] as Map<String, dynamic>;
    final cx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
    final cy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
    if (kind != null) {
      // WHY 先勝ち: ランタイム _collectAnchors と同一規則（重複は 1 つ目）。
      anchors.putIfAbsent(kind, () => (cx: cx, cy: cy));
      anchorPositions
          .putIfAbsent(text, () => <_PairSample>[])
          .add(_PairSample(file, cx, cy));
      continue;
    }
    final merged = _mergedPattern.firstMatch(text);
    if (merged != null) {
      failures.add(_Failure(file, merged.group(1)!, 'merged: ${map['text']}'));
    }
  }
  for (final entry in anchors.entries) {
    final pair = _collectPairsFor(
      entry.key,
      entry.value,
      elements,
      anchors.keys.toSet(),
      file,
      w,
      h,
      samples,
      failures,
    );
    // WHY ペアが真同一行（|dy|<=0.012）でない時だけ出す: 値が ML Kit で
    // 取れていない/誤読されている写真だけを診断する（0→O 等の誤読語彙の
    // 収集が目的。正常ペアの NEAR 出力はノイズになる）。
    if (pair == null || pair.dy.abs() > 0.012) {
      _printNearLabel(elements, file, entry.key, entry.value, w, h);
    }
  }
  for (final expected in [
    'score',
    'cool',
    'great',
    'good',
    'bad',
    'maxCombo',
  ]) {
    if (!anchors.containsKey(expected)) {
      failures.add(_Failure(file, expected, 'anchor miss'));
    }
  }
}

/// 校正後窓内の全要素を出す（誤読・連結の実体確認用診断）。
void _printNearLabel(
  List<dynamic> elements,
  String file,
  String kind,
  ({double cx, double cy}) anchor,
  double w,
  double h,
) {
  final near = <String>[];
  for (final e in elements) {
    final map = e as Map<String, dynamic>;
    final bb = map['boundingBox'] as Map<String, dynamic>;
    final cx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
    final cy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
    final dx = cx - anchor.cx;
    final dy = cy - anchor.cy;
    if (dx < 0.06 || dx > 0.30 || dy.abs() > 0.015) {
      continue;
    }
    final conf = (map['confidence'] as num?)?.toStringAsFixed(2) ?? '-';
    near.add('${map['text']}($conf)');
  }
  if (near.isNotEmpty) {
    stdout.writeln(
      'NEAR $file $kind @${anchor.cy.toStringAsFixed(3)}: ${near.join(' | ')}',
    );
  }
}

_PairSample? _collectPairsFor(
  String kind,
  ({double cx, double cy}) anchor,
  List<dynamic> elements,
  Set<String> claimedTexts,
  String file,
  double w,
  double h,
  Map<String, List<_PairSample>> samples,
  List<_Failure> failures,
) {
  _PairSample? best;
  double bestKey = double.infinity;
  for (final e in elements) {
    final map = e as Map<String, dynamic>;
    final text = (map['text'] as String).trim().toUpperCase();
    if (claimedTexts.contains(text)) {
      continue;
    }
    final value = int.tryParse(text);
    if (value == null) {
      continue;
    }
    final bb = map['boundingBox'] as Map<String, dynamic>;
    final cx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
    final cy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
    final dx = cx - anchor.cx;
    final dy = cy - anchor.cy;
    if (dx < -0.05 || dx > 0.9 || dy.abs() > 0.05) {
      continue;
    }
    final key = dy.abs() * 10 + dx.abs();
    if (key < bestKey) {
      bestKey = key;
      best = _PairSample(file, dx, dy);
    }
  }
  if (best == null) {
    failures.add(_Failure(file, kind, 'value miss'));
    return null;
  }
  samples[kind]!.add(best);
  return best;
}

double _percentile(List<double> values, double p) {
  final sorted = values.toList()..sort();
  final idx = (p * (sorted.length - 1)).round();
  return sorted[idx];
}

void _printPairStats(Map<String, List<_PairSample>> samples) {
  stdout.writeln(
    '--- anchor-value pair stats (dx=right of label, dy=same row) ---',
  );
  for (final entry in samples.entries) {
    final list = entry.value;
    final dys = list.map((s) => s.dy).toList();
    // WHY 真同一行（|dy|<=0.012）のみで dx を集計: dy 0.045 前後のペアは
    // 隣接行の誤ペア（実値欠落時）で、窓校正に混ぜると歪む。
    final trueRows = list.where((s) => s.dy.abs() <= 0.012).toList();
    final dxs = trueRows.map((s) => s.dx).toList();
    if (list.isEmpty) {
      stdout.writeln('${entry.key}: n=0');
      continue;
    }
    final b1 = dys.where((d) => d.abs() <= 0.012).length;
    final b2 = dys.where((d) => d.abs() > 0.012 && d.abs() <= 0.025).length;
    final b3 = dys.where((d) => d.abs() > 0.025).length;
    // WHY 全範囲を出す: ランタイムの窓判定はマージンなしの厳密判定なので、
    // p5/p95 ではなく実測 min/max（全 true ペア）を基に窓を決める。
    final dxMin = dxs.isEmpty ? 0.0 : dxs.reduce((a, b) => a < b ? a : b);
    final dxMax = dxs.isEmpty ? 0.0 : dxs.reduce((a, b) => a > b ? a : b);
    stdout.writeln(
      '${entry.key}: n=${list.length} trueRows=${trueRows.length} '
      'dx trueMin=${dxMin.toStringAsFixed(4)} trueMax=${dxMax.toStringAsFixed(4)} '
      'p50=${_percentile(dxs, 0.5).toStringAsFixed(4)} | '
      'dy |<=0.012|=$b1 (0.012,0.025]=$b2 (0.025,0.05]=$b3',
    );
    for (final s in trueRows) {
      stdout.writeln(
        '    true ${entry.key}: ${s.file} dx=${s.dx.toStringAsFixed(4)} dy=${s.dy.toStringAsFixed(4)}',
      );
    }
  }
}

void _printAnchorStats(Map<String, List<_PairSample>> anchorPositions) {
  stdout.writeln('--- label canonical (median over all 30 photos) ---');
  for (final entry in anchorPositions.entries) {
    final cxs = entry.value.map((s) => s.dx).toList();
    final cys = entry.value.map((s) => s.dy).toList();
    stdout.writeln(
      '${entry.key}: n=${entry.value.length} '
      'cx p50=${_percentile(cxs, 0.5).toStringAsFixed(4)} '
      'cy p50=${_percentile(cys, 0.5).toStringAsFixed(4)}',
    );
  }
}

void _printFailures(List<_Failure> failures) {
  stdout.writeln('--- failures (${failures.length}) ---');
  for (final f in failures) {
    stdout.writeln('${f.file} ${f.kind}: ${f.reason}');
  }
}
