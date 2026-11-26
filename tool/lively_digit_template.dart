// 数字テンプレート照合の試作。Lively リザルトの数値 7 項目を、ML Kit を使わずに
// 「明るい画素の連結成分 → 行にまとめる → 桁に分割 → テンプレート照合」で読む。
//
// 行の特定だけは ML Kit のラベル検出に頼る（COOL/GREAT/... の語は安定して取れる）。
// 値の読み取りは完全に画素だけで行うので、ML Kit が数値を返さない欄でも読める。
//
// テンプレートは「正解が分かっている画像」から採り、「正解を知らない画像」で評価する。
// 既定の評価は leave-one-out（評価する 1 枚以外の全部から採る）。同じ画像から採って
// 同じ画像で評価すると自明に当たるので、donor と評価画像は必ず分ける。
//
// 実測（126 セル）: 単独 71/126 (56.3%) / ML Kit 単独 56/126 (44.4%) /
// 和集合 84/126 (66.7%)。律速は字形ではなく桁の切り出し（桁数一致 90 セルで 78.9%、
// 不一致 36 セルで 0%）。詳細は docs/lively_digit_template_2026-11-25.md。
//
// 設計上の要点: 行の上下端はラベル中心から計算しない。ラベル中心は値の中心と一致せず、
// 隣の行の数字が混ざって桁数が狂う（当初これで 29.6% だった）。画素から行を検出し、
// 「どのラベルに一番近いか」で名前を付ける。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const _fieldOrder = ['score', 'cool', 'great', 'good', 'bad', 'combo', 'best'];

// 行の位置を決めるのに使うラベル。SCORE は使わない:
// BEST SCORE 行のラベルが「BEST」「SCORE」の 2 要素に割れて返るため、
// SCORE を探すと BEST 行を指してしまう（実測）。
// COMBO はラベル検出が不安定（GOMBO/GOmUO など）なので BAD と BEST から補間する。
const _labelOf = {
  'cool': ['COOL'],
  'great': ['GREAT'],
  'good': ['GOOD'],
  'bad': ['BAD'],
  'best': ['BEST'],
};

const _gw = 10;
const _gh = 16;

/// 1 桁の縦横比（幅 / 高さ）。文字盤の実測はおおむね 0.5〜0.63。
/// 正規化のキャンバス幅をこれで決めることで、幅の狭い "1" を潰さずに済む。
const _aspect = 0.6;

/// 1 セルあたりの標本点数（1 辺）。
const _sub = 4;

bool _debug = false;
String? _debugId;

void main(List<String> args) {
  final opts = _parseArgs(args);
  final gt = _loadGt(opts['gt']!);
  final elements = _loadElements(opts['elements']!);
  final panelDir = opts['panels']!;
  _mergeStyles = opts['merge-styles'] == '1';
  inkPct = double.tryParse(opts['ink-pct'] ?? '') ?? 0.25;
  _debug = opts['debug'] != null;
  _debugId = opts['debug'];

  final ids = gt.keys.where((k) => elements.containsKey(k)).toList()..sort();
  _warn('GT ${gt.length} 件 / OCR ${elements.length} 件 / 照合可能 ${ids.length} 件');

  final images = <String, img.Image>{};
  for (final id in ids) {
    final f = File('$panelDir${Platform.pathSeparator}$id.jpg');
    if (!f.existsSync()) {
      _warn('画像なし $id');
      continue;
    }
    images[id] = img.decodeImage(f.readAsBytesSync())!;
  }

  // 画素から行を検出し、ラベルで名前を付ける
  final rows = <String, Map<String, _ValueRow>>{};
  for (final id in images.keys) {
    rows[id] = _locateRows(id, elements[id]!, images[id]!);
  }

  // donor 選択: 数字 0-9 が埋まるまで greedy に足す（最低 6 枚は確保して標本を増やす）。
  // 'loo' を指定したときは donor 方式を使わないので、ここでは解釈しない。
  final donorOpt = opts['donors'];
  final donorTarget =
      (donorOpt == null || donorOpt == 'auto' || donorOpt == 'loo')
      ? null
      : int.parse(donorOpt);
  const allDigits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

  // 行の検出と桁の切り出しは画像ごとに 1 回だけ行う。donor の選び方に依存しないので、
  // 何度も評価する leave-one-out でも計算は 1 回で済む。
  final reads = <String, Map<String, _ReadResult?>>{};
  for (final id in ids) {
    if (!images.containsKey(id)) continue;
    final m = <String, _ReadResult?>{};
    for (final field in _fieldOrder) {
      final row = rows[id]![field];
      m[field] = row == null ? null : _readParts(images[id]!, row);
    }
    reads[id] = m;
  }

  // 画像ごとの標本。同じ数字でも標本は平均せず 1 件ずつ持つ（理由は _Sample の注記）。
  // 桁数が GT と一致した行だけ採る（ずれたまま採ると字形が隣の桁と混ざる）。
  final samplesByImage = <String, List<_Sample>>{};
  var harvestHit = 0;
  var harvestMiss = 0;
  for (final id in reads.keys) {
    final g = gt[id]!;
    final list = <_Sample>[];
    for (final field in _fieldOrder) {
      final text = g[field]!;
      if (text.isEmpty || !_isDigits(text)) continue;
      final read = reads[id]![field];
      if (read == null || read.parts.length != text.length) {
        harvestMiss++;
        continue;
      }
      harvestHit++;
      _addSamples(
        list,
        _styleOf(field),
        text,
        read.parts,
        images[id]!,
        read.thr,
      );
    }
    samplesByImage[id] = list;
  }
  _warn('template 収集: 採用 $harvestHit 行 / 桁数不一致 $harvestMiss 行');

  // donor 方式（既定）: 先頭から順に、10 桁が揃うまで donor にする。
  // leave-one-out 方式: 評価する画像以外のすべてを標本に使う。標本数が最大になり、
  // 評価集合が縮まないので、精度が標本数に比例するかどうかを素直に測れる。
  final loo = opts['donors'] == 'loo';
  final donors = <String>{};
  if (!loo) {
    final covered = <String>{};
    for (final id in reads.keys) {
      if (donorTarget != null && donors.length >= donorTarget) break;
      if (donorTarget == null &&
          donors.length >= 6 &&
          covered.containsAll(allDigits)) {
        break;
      }
      donors.add(id);
      covered.addAll(_digitsOf(gt[id]!));
    }
    _warn(
      'donor ${donors.length} 件 / 収集した数字 ${covered.length}/10 '
      '(欠け: ${allDigits.where((d) => !covered.contains(d)).join(",")})',
    );
  } else {
    _warn('leave-one-out: 評価 1 枚につき残り ${reads.length - 1} 枚を標本に使う');
  }

  final poolAll = samplesByImage.values.expand((e) => e).toList();
  for (final style in ['score', 'count']) {
    final byDigit = <String, int>{};
    for (final s in poolAll.where((s) => s.style == style)) {
      byDigit[s.digit] = (byDigit[s.digit] ?? 0) + 1;
    }
    final keys = byDigit.keys.toList()..sort();
    _warn(
      'template style=$style 数字=${keys.join()} '
      '標本数=${keys.map((k) => '$k:${byDigit[k]}').join(',')}',
    );
  }

  if (opts['dump-templates'] == '1') {
    for (final style in ['score', 'count']) {
      final byDigit = <String, List<List<double>>>{};
      for (final s in poolAll.where((s) => s.style == style)) {
        byDigit.putIfAbsent(s.digit, () => []).add(s.vec);
      }
      _warn('=== templates[$style] (平均表示)');
      final keys = byDigit.keys.toList()..sort();
      for (final k in keys) {
        final vs = byDigit[k]!;
        final v = List<double>.filled(_gw * _gh, 0);
        for (final one in vs) {
          for (var i = 0; i < v.length; i++) {
            v[i] += one[i] / vs.length;
          }
        }
        final art = <String>[];
        for (var gy = 0; gy < _gh; gy++) {
          final b = StringBuffer();
          for (var gx = 0; gx < _gw; gx++) {
            final f = v[gy * _gw + gx];
            b.write(f > 0.66 ? '#' : (f > 0.33 ? '+' : (f > 0.1 ? '.' : ' ')));
          }
          art.add(b.toString());
        }
        _warn('digit $k (n=${vs.length})');
        for (final r in art) {
          _warn('  |$r|');
        }
      }
    }
  }

  // 評価
  // Excel（日本語環境）でそのまま開けるよう BOM を付ける。
  final out = StringBuffer(
    '\uFEFFid,field,gt,got,ok,parts,style,mlkit,mlkit_ok,union_ok\n',
  );
  var total = 0;
  var ok = 0;
  var skip = 0;
  var evalCount = 0;
  // ML Kit 単独（1x 切り出し）と、テンプレートとの和集合。同じセルで突き合わせる。
  var mkOk = 0;
  var unionOk = 0;
  final mkPerField = <String, List<int>>{
    for (final f in _fieldOrder) f: [0, 0],
  };
  final unionPerField = <String, List<int>>{
    for (final f in _fieldOrder) f: [0, 0],
  };
  final evalAll = opts['eval-all'] == '1';
  final perField = <String, List<int>>{
    for (final f in _fieldOrder) f: [0, 0],
  };
  for (final id in reads.keys) {
    if (!loo && donors.contains(id) && !evalAll) continue;
    evalCount++;
    final List<_Sample> samples = loo
        ? [
            for (final e in samplesByImage.entries)
              if (e.key != id) ...e.value,
          ]
        : [for (final j in donors) ...samplesByImage[j]!];
    final g = gt[id]!;
    for (final field in _fieldOrder) {
      if (g[field]!.isEmpty) {
        out.writeln('$id,$field,,,skip,0,-');
        skip++;
        continue;
      }
      final read = reads[id]![field];
      // ML Kit 単独の答え: 同じ行の帯にある「数字だけの要素」。桁数は最大 5 なので
      // 帯に複数あれば最も横幅の大きいもの（＝値そのもの）を採る。
      final mkRow = rows[id]![field];
      final mk = mkRow == null
          ? null
          : _mlkitDigitsIn(elements[id] ?? const [], mkRow);
      final mkIsOk = mk == g[field];
      var got = '';
      var isOk = false;
      if (read == null) {
        // テンプレート側は「桁が取れない」。分母からは外さず 0 点として数える。
        total++;
        perField[field]![1]++;
      } else {
        final style = _styleOf(field);
        final pool = _poolFor(samples, style);
        final parts = read.parts;
        if (_debug && _debugId == id) {
          _warn(
            '    $field labelRight=${rows[id]![field]!.labelRight} '
            'thr=${read.thr} n=${parts.length} '
            'parts=${parts.map((p) => '${p.l}-${p.r}').join(' ')}',
          );
        }
        final buf = StringBuffer();
        var sumS = 0.0;
        for (final p in parts) {
          final vec = _normalize(images[id]!, p, read.thr);
          final hit = _bestMatch(pool, vec);
          sumS += hit.score;
          buf.write(hit.digit);
        }
        got = buf.toString();
        isOk = got == g[field];
        if (_debug && _debugId == id) {
          _warn(
            '    $field n=${parts.length} got=$got '
            'mean=${(sumS / parts.length).toStringAsFixed(3)}',
          );
        }
        total++;
        perField[field]![1]++;
      }
      mkPerField[field]![1]++;
      unionPerField[field]![1]++;
      if (isOk) {
        ok++;
        perField[field]![0]++;
      }
      if (mkIsOk) {
        mkOk++;
        mkPerField[field]![0]++;
      }
      if (isOk || mkIsOk) {
        unionOk++;
        unionPerField[field]![0]++;
      }
      out.writeln(
        '$id,$field,${g[field]},$got,${isOk ? 1 : 0},${got.length},'
        '${_styleOf(field)},${mk ?? ""},${mkIsOk ? 1 : 0},'
        '${isOk || mkIsOk ? 1 : 0}',
      );
    }
  }
  File(opts['out']!).writeAsStringSync(out.toString());

  _warn(
    '評価 $evalCount 枚 / $total セル / 一致 $ok '
    '(${(100 * ok / math.max(1, total)).toStringAsFixed(1)}%) / skip $skip',
  );
  _warn(
    '項目別: ${perField.entries.map((e) => '${e.key} ${e.value[0]}/${e.value[1]}').join('  ')}',
  );
  _warn(
    'ML Kit 単独: $mkOk/$total '
    '(${(100 * mkOk / math.max(1, total)).toStringAsFixed(1)}%)  '
    '${mkPerField.entries.map((e) => '${e.key} ${e.value[0]}/${e.value[1]}').join('  ')}',
  );
  _warn(
    '和集合: $unionOk/$total '
    '(${(100 * unionOk / math.max(1, total)).toStringAsFixed(1)}%)  '
    '${unionPerField.entries.map((e) => '${e.key} ${e.value[0]}/${e.value[1]}').join('  ')}',
  );
}

/// 行の帯にある「数字だけの要素」を 1 つ返す（最も横幅が大きいもの）。
String? _mlkitDigitsIn(List<_Elem> elems, _ValueRow row) {
  final h = row.b - row.t + 1;
  String? best;
  var bestW = -1;
  for (final e in elems) {
    final text = e.text.trim();
    if (text.isEmpty || !_isDigits(text)) continue;
    final cy = (e.box.t + e.box.b) / 2;
    if (cy < row.t - h * 0.15 || cy > row.b + h * 0.15) continue;
    final w = e.box.r - e.box.l;
    if (w > bestW) {
      bestW = w;
      best = text;
    }
  }
  return best;
}

/// 1 行から桁の並びと、その行の二値化しきい値を取り出す。
/// テンプレート収集と評価で同じ手順を使う。
///
/// しきい値は行（数値の帯）単位で決める。桁ごとに決めるとインクの多い桁だけ
/// しきい値が持ち上がって同じ字形が別物になり、パネル全体で決めると背景の
/// にじみに引っ張られる。行の中なら「数字 と 地」の 2 峰で素直に割れる。
_ReadResult? _readParts(img.Image im, _ValueRow row) {
  final cluster = _valueCluster(im, row);
  if (cluster == null) return null;
  final bb = cluster.bbox();
  final thr = _thresholdIn(im, bb);
  final parts = _projectionParts(im, bb, thr);
  if (parts.isEmpty) return null;
  return _ReadResult(parts, thr);
}

class _ReadResult {
  _ReadResult(this.parts, this.thr);
  final List<_Part> parts;
  final int thr;
}

/// bbox 内の画素からしきい値を求める。
///
/// 既定は「上位 [inkPct] の明るさだけをインクとみなす」割合しきい値。
/// Otsu は地と字の 2 峰がはっきりしている前提で、にじみで峰が潰れた行では
/// しきい値が低く出て、どのセルもインクで埋まる（実測: 被覆率が全セル 1.0 に
/// 飽和し、GOOD の 87 も 66 も "00" になった）。割合で決めれば飽和しない。
int _thresholdIn(img.Image im, _Part bb) {
  final hist = List<int>.filled(256, 0);
  var n = 0;
  for (var y = bb.t; y <= bb.b; y++) {
    for (var x = bb.l; x <= bb.r; x++) {
      final px = im.getPixel(x, y);
      hist[(px.r * 0.299 + px.g * 0.587 + px.b * 0.114).round().clamp(
        0,
        255,
      )]++;
      n++;
    }
  }
  if (n == 0) return 128;
  if (inkPct <= 0) return _otsu(hist);
  final target = (n * inkPct).round();
  var acc = 0;
  for (var v = 255; v >= 0; v--) {
    acc += hist[v];
    if (acc >= target) return v;
  }
  return 0;
}

/// インクとみなす画素の割合。0 以下なら Otsu。
double inkPct = 0.25;

/// bbox 内の列方向インク分布から桁を切り出す。
///
/// 連結成分で切ると、輪郭が光ってにじむ写真では 1 桁が複数の島に割れて破綻する
/// （実測: 3 桁が 13 個の成分になった）。桁は縦に墨が続くので、列ごとのインク量の
/// 谷を桁間ギャップとみなすほうが安定する。
List<_Part> _projectionParts(img.Image im, _Part bbox, int thr) {
  final w = bbox.r - bbox.l + 1;
  final h = bbox.b - bbox.t + 1;
  if (w < 8 || h < 8) return const [];
  final gray = List<int>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(
        (bbox.l + x).clamp(0, im.width - 1),
        (bbox.t + y).clamp(0, im.height - 1),
      );
      gray[y * w + x] = (p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round().clamp(
        0,
        255,
      );
    }
  }
  final colInk = List<int>.filled(w, 0);
  for (var x = 0; x < w; x++) {
    var c = 0;
    for (var y = 0; y < h; y++) {
      if (gray[y * w + x] > thr) c++;
    }
    colInk[x] = c;
  }
  final maxInk = colInk.reduce(math.max);
  if (maxInk == 0) return const [];
  final low = math.max(1, (maxInk * 0.12).round());
  final minGap = math.max(3, (h * 0.06).round());

  // インクのある列の連続区間 = 桁候補
  final runs = <List<int>>[];
  var s = -1;
  var gap = 0;
  for (var x = 0; x < w; x++) {
    if (colInk[x] >= low) {
      if (s < 0) s = x;
      gap = 0;
    } else if (s >= 0) {
      gap++;
      if (gap >= minGap) {
        runs.add([s, x - gap]);
        s = -1;
      }
    }
  }
  if (s >= 0) runs.add([s, w - 1]);
  final kept = runs
      .where((r) => r[1] - r[0] + 1 >= math.max(4, h * 0.10))
      .toList();
  return [
    for (final r in kept) _Part(bbox.l + r[0], bbox.t, bbox.l + r[1], bbox.b),
  ];
}

/// 数字だけの文字列か。
bool _isDigits(String s) =>
    s.isNotEmpty && s.codeUnits.every((c) => c >= 48 && c <= 57);

/// 1 桁ぶんの標本。平均せず 1 件ずつ持つ。
///
/// 平均すると、画像ごとの半画素ずれとにじみの差で字形が丸い塊に潰れる
/// （実測: 平均テンプレートで 0 と 3 と 8 の被覆率がほぼ同じになった）。
class _Sample {
  _Sample(this.style, this.digit, this.vec);
  final String style;
  final String digit;
  final List<double> vec;
}

/// 項目ごとの標本の系統。
///
/// score だけは文字が大きく、にじみ方も違うので別扱いにするのが自然だが、
/// 10×16 に正規化すると大きさの差は消えるので、まとめた方が標本は増える。
/// どちらが良いかは --merge-styles で切り替えて実測する。
String _styleOf(String field) =>
    (field == 'score' && !_mergeStyles) ? 'score' : 'count';

bool _mergeStyles = false;

void _addSamples(
  List<_Sample> samples,
  String style,
  String text,
  List<_Part> parts,
  img.Image im,
  int thr,
) {
  for (var i = 0; i < parts.length && i < text.length; i++) {
    samples.add(_Sample(style, text[i], _normalize(im, parts[i], thr)));
  }
}

/// 照合に使う標本。指定スタイルを優先し、そのスタイルに無い数字だけ他スタイルで補う。
List<_Sample> _poolFor(List<_Sample> samples, String style) {
  final base = samples.where((s) => s.style == style).toList();
  final have = base.map((s) => s.digit).toSet();
  return [
    ...base,
    ...samples.where((s) => s.style != style && !have.contains(s.digit)),
  ];
}

/// 最近傍 1 件で数字を決める。
({String digit, double score}) _bestMatch(
  List<_Sample> pool,
  List<double> vec,
) {
  var bestD = '?';
  var bestS = -1.0;
  for (final s in pool) {
    final v = _similarity(vec, s.vec);
    if (v > bestS) {
      bestS = v;
      bestD = s.digit;
    }
  }
  return (digit: bestD, score: bestS);
}

void _warn(String s) => stderr.writeln(s);

Map<String, String> _parseArgs(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i].startsWith('--')) m[args[i].substring(2)] = args[i + 1];
  }
  return m;
}

/// GT（ファイル名の stem -> 項目 -> 文字列）
Map<String, Map<String, String>> _loadGt(String path) {
  final lines = File(path).readAsLinesSync();
  final header = _csvSplit(lines.first);
  int idx(String name) => header.indexWhere((h) => h.trim() == name);
  final colId = idx('ファイル名');
  final cols = {
    'score': idx('スコア'),
    'cool': idx('COOL'),
    'great': idx('GREAT'),
    'good': idx('GOOD'),
    'bad': idx('BAD'),
    'combo': idx('COMBO表示値'),
    'best': idx('BEST SCORE'),
  };
  final out = <String, Map<String, String>>{};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final c = _csvSplit(line);
    if (c.length <= colId || colId < 0) continue;
    final id = _stem(c[colId]);
    if (id.isEmpty) continue;
    out[id] = {
      for (final e in cols.entries)
        e.key: e.value >= 0 ? c[e.value].trim() : '',
    };
  }
  return out;
}

List<String> _csvSplit(String line) {
  // GT は単純な CSV。ファイル名だけ引用符で囲まれているので外す。
  return line.split(',').map((c) {
    var v = c.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }).toList();
}

/// OCR 要素（stem -> 要素一覧）。依存を増やさないため最小限の JSON 走査で読む。
Map<String, List<_Elem>> _loadElements(String path) {
  final text = File(path).readAsStringSync();
  final out = <String, List<_Elem>>{};
  for (final m in RegExp(r'"file"\s*:\s*"([^"]+)"').allMatches(text)) {
    final start = m.end;
    final next = text.indexOf('"file"', start);
    final chunk = text.substring(start, next < 0 ? text.length : next);
    final id = _stem(m.group(1)!);
    final elems = <_Elem>[];
    final re = RegExp(
      r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"boundingBox"\s*:\s*\{\s*'
      r'"l"\s*:\s*(-?[\d.]+)\s*,\s*"t"\s*:\s*(-?[\d.]+)\s*,\s*'
      r'"r"\s*:\s*(-?[\d.]+)\s*,\s*"b"\s*:\s*(-?[\d.]+)',
    );
    for (final e in re.allMatches(chunk)) {
      elems.add(
        _Elem(
          e.group(1)!,
          _ElemBox(
            double.parse(e.group(2)!).round(),
            double.parse(e.group(3)!).round(),
            double.parse(e.group(4)!).round(),
            double.parse(e.group(5)!).round(),
          ),
        ),
      );
    }
    out[id] = elems;
  }
  return out;
}

String _stem(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

Set<String> _digitsOf(Map<String, String> g) {
  final s = <String>{};
  for (final v in g.values) {
    for (final ch in v.split('')) {
      final c = ch.codeUnitAt(0);
      if (c >= 48 && c <= 57) s.add(ch);
    }
  }
  return s;
}

/// 画素から数値の行を検出し、ラベルの近さで項目名を割り当てる。
Map<String, _ValueRow> _locateRows(String id, List<_Elem> elems, img.Image im) {
  final labels = _labelCenters(elems);
  if (labels.isEmpty) return const {};
  final detected = _detectRows(im);
  if (detected.isEmpty) return const {};
  if (_debug && _debugId == id) {
    _warn('--- rows on $id (${im.width}x${im.height})');
    for (var i = 0; i < detected.length; i++) {
      final r = detected[i];
      final xs = r.comps.map((c) => c.l).reduce(math.min);
      final xe = r.comps.map((c) => c.r).reduce(math.max);
      _warn(
        '  row[$i] y=${r.t}..${r.b} c=${r.centerY.toStringAsFixed(0)} '
        'n=${r.comps.length} x=$xs..$xe',
      );
    }
    _warn(
      '  labels: ${labels.entries.map((e) => '${e.key}@${e.value.toStringAsFixed(0)}').join(" ")}',
    );
  }

  // 行間の基準 P（ラベル中心の差の中央値）
  final ordered = _fieldOrder.where(labels.containsKey).toList();
  final gaps = <double>[];
  for (var i = 1; i < ordered.length; i++) {
    final d = labels[ordered[i]]! - labels[ordered[i - 1]]!;
    if (d > 20) gaps.add(d);
  }
  if (gaps.isEmpty) return const {};
  gaps.sort();
  final p = gaps[gaps.length ~/ 2];

  // COMBO は BAD と BEST の間で補間（実測比 0.53）
  if (!labels.containsKey('combo') &&
      labels.containsKey('bad') &&
      labels.containsKey('best')) {
    final bad = labels['bad']!;
    final best = labels['best']!;
    labels['combo'] = bad + (best - bad) * 0.53;
  }
  // SCORE 行はラベルが無いので COOL から上へ外挿（実測で COOL→SCORE は約 1.8P）
  if (!labels.containsKey('score') && labels.containsKey('cool')) {
    labels['score'] = labels['cool']! - 1.80 * p;
  }

  final out = <String, _ValueRow>{};
  final used = <int>{};
  for (final field in _fieldOrder) {
    final y = labels[field];
    if (y == null) continue;
    var bestIdx = -1;
    var bestDiff = double.infinity;
    for (var i = 0; i < detected.length; i++) {
      if (used.contains(i)) continue;
      final d = (detected[i].centerY - y).abs();
      if (d < bestDiff) {
        bestDiff = d;
        bestIdx = i;
      }
    }
    // 近すぎる/遠すぎる行は割り当てない（誤って隣の行を掴むのを防ぐ）
    if (bestIdx < 0 || bestDiff > p * 0.55) continue;
    used.add(bestIdx);
    detected[bestIdx].labelRight = _labelRightNear(elems, y, p * 0.5);
    out[field] = detected[bestIdx];
    if (_debug && _debugId == id) {
      final r = detected[bestIdx];
      _warn(
        '  assign $field -> row[$bestIdx] y=${r.t}..${r.b} '
        'labelY=${y.toStringAsFixed(0)} diff=${bestDiff.toStringAsFixed(0)} '
        'labelRight=${r.labelRight}',
      );
    }
  }
  return out;
}

/// 指定した縦位置の近くにある「文字だけの要素」の右端の最大値。
///
/// 値は数字だけ、ラベルは英字だけなので、この境目がそのまま数値列の左端になる。
/// 画素の隙間から推測するより確実（隙間の大きさは桁幅と同程度で、閾値が置けない）。
int _labelRightNear(List<_Elem> elems, double y, double tol) {
  var best = -1;
  for (final e in elems) {
    final letters = e.text.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
    if (letters.isEmpty) continue;
    final cy = (e.box.t + e.box.b) / 2;
    if ((cy - y).abs() > tol) continue;
    if (e.box.r > best) best = e.box.r;
  }
  return best;
}

/// ラベル語から縦位置を得る。
Map<String, double> _labelCenters(List<_Elem> elems) {
  final found = <String, double>{};
  for (final e in elems) {
    final letters = e.text.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
    if (letters.isEmpty) continue;
    String? bestField;
    var bestDist = 99;
    var secondDist = 99;
    for (final entry in _labelOf.entries) {
      for (final word in entry.value) {
        final d = _editDistance(letters, word);
        if (d < bestDist) {
          secondDist = bestDist;
          bestDist = d;
          bestField = entry.key;
        } else if (d < secondDist) {
          secondDist = d;
        }
      }
    }
    if (bestField == null || bestDist > 2 || secondDist <= bestDist) continue;
    found.putIfAbsent(bestField, () => (e.box.t + e.box.b) / 2);
  }
  // 縦順が崩れていたら捨てる
  final keep = <String>[];
  for (final f in _fieldOrder.where(found.containsKey)) {
    if (keep.isNotEmpty && found[f]! <= found[keep.last]!) continue;
    keep.add(f);
  }
  found.removeWhere((k, _) => !keep.contains(k));
  return found;
}

/// 値の列（右側 60%）から行を検出する。行の上下端は画素から決める。
List<_ValueRow> _detectRows(img.Image im) {
  final x0 = (im.width * 0.40).round();
  final x1 = (im.width * 0.97).round();
  final w = x1 - x0;
  final h = im.height;
  if (w < 50) return const [];
  final gray = List<int>.filled(w * h, 0);
  final hist = List<int>.filled(256, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x0 + x, y);
      final v = (p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round().clamp(0, 255);
      gray[y * w + x] = v;
      hist[v]++;
    }
  }
  final thr = _otsu(hist);
  final comps = _components(gray, w, h, thr)
      .where((c) => c.l > 1 && c.r < w - 2) // 切り出し端に接するものは枠
      .where((c) => (c.r - c.l + 1) <= w * 0.55) // 横に長すぎる帯
      .where((c) => (c.r - c.l + 1) <= (c.b - c.t + 1) * 1.8) // 横長すぎるもの以外
      .where((c) => (c.b - c.t + 1) >= 24) // 小さすぎるノイズ
      // 以降はパネル画像の絶対座標で扱う（_normalize がそのまま画素を読むため）
      .map((c) => _Comp(c.l + x0, c.t, c.r + x0, c.b, c.area))
      .toList();
  if (comps.isEmpty) return const [];

  comps.sort((a, b) => a.t.compareTo(b.t));
  final rows = <_ValueRow>[];
  for (final c in comps) {
    if (rows.isNotEmpty) {
      final r = rows.last;
      final rh = r.b - r.t + 1;
      if (r.centerY >= c.t - rh * 0.35 && r.centerY <= c.b + rh * 0.35) {
        r.comps.add(c);
        r.t = math.min(r.t, c.t);
        r.b = math.max(r.b, c.b);
        continue;
      }
    }
    rows.add(_ValueRow(c.t, c.b, [c]));
  }
  return rows.where((r) => r.b - r.t + 1 >= 30).toList();
}

int _editDistance(String a, String b) {
  final dp = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = 0; i <= a.length; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      dp[i][j] = math.min(
        math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
        dp[i - 1][j - 1] + cost,
      );
    }
  }
  return dp[a.length][b.length];
}

/// 行の中で「数値のまとまり」を 1 つ取り出す。
///
/// 切る位置はラベル語の右端（[labelRight]）で決める。以前は「成分間の最大の隙間」で
/// 切っていたが、この写真では桁間の隙間が桁幅と同程度（約 60px / 桁幅 60px）あり、
/// 最大の隙間が数値の内部に来るため先頭の桁を落としていた（実測: COOL 158 が "58"）。
_Cluster? _valueCluster(img.Image im, _ValueRow row) {
  final comps = [...row.comps]..sort((a, b) => a.l.compareTo(b.l));
  if (comps.isEmpty) return null;
  // 高さの基準は最長ではなく中央値にする。最長は飾りや隣の行のはみ出しに引きずられ、
  // 数字の一部まで「低い」と判定して落としてしまう（実測: score 96446 が "34"）。
  final heights = comps.map((c) => (c.b - c.t + 1).toDouble()).toList()..sort();
  final refH = heights[heights.length ~/ 2];
  var kept = comps.where((c) => (c.b - c.t + 1) >= refH * 0.7).toList();
  if (kept.isEmpty) kept = comps;

  if (row.labelRight > 0) {
    final right = kept.where((c) => c.l > row.labelRight + 2).toList();
    // 全部消えたらラベル判定が誤っている。素直に元のまま使う。
    if (right.isNotEmpty) kept = right;
  }
  return _Cluster(kept.map((c) => _Part(c.l, c.t, c.r, c.b)).toList());
}

/// 連結成分ラベリング（8 近傍）
List<_Comp> _components(List<int> gray, int w, int h, int thr) {
  final seen = List<bool>.filled(w * h, false);
  final out = <_Comp>[];
  final stack = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (seen[i] || gray[i] <= thr) continue;
    var l = i % w;
    var r = l;
    var t = i ~/ w;
    var b = t;
    var count = 0;
    stack.add(i);
    seen[i] = true;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final x = p % w;
      final y = p ~/ w;
      count++;
      if (x < l) l = x;
      if (x > r) r = x;
      if (y < t) t = y;
      if (y > b) b = y;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
          final q = ny * w + nx;
          if (seen[q] || gray[q] <= thr) continue;
          seen[q] = true;
          stack.add(q);
        }
      }
    }
    if (count >= 12) out.add(_Comp(l, t, r, b, count));
  }
  return out;
}

int _otsu(List<int> hist) {
  var total = 0;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    total += hist[i];
    sum += i * hist[i];
  }
  if (total == 0) return 128;
  var sumB = 0.0;
  var wB = 0;
  var best = 0.0;
  var bestThr = 128;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > best) {
      best = v;
      bestThr = t;
    }
  }
  return bestThr;
}

/// 部品を _gw × _gh の被覆率ベクトルに正規化する。
/// 縦横比を保ったまま中央に置く。以前は部品の bbox をそのまま 10×16 に引き伸ばして
/// いたため、幅の狭い "1" が全幅の棒になり、どの数字も丸い塊に潰れて区別できなかった
/// （実測: 0→9, 8→6, 5→6 の誤読が支配的で、COMBO は値によらず常に "666"）。
List<double> _normalize(img.Image im, _Part p, int thr) {
  final w = p.r - p.l + 1;
  final h = p.b - p.t + 1;
  final vec = List<double>.filled(_gw * _gh, 0);
  if (w <= 0 || h <= 0) return vec;
  final gray = List<int>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = im.getPixel(p.l + x, p.t + y);
      gray[y * w + x] = (px.r * 0.299 + px.g * 0.587 + px.b * 0.114)
          .round()
          .clamp(0, 255);
    }
  }

  // インクの実体（しきい値を超えた画素）の範囲。投影で切った部品は横は詰まって
  // いるが、縦は行の帯そのままなので上下に余白が残る。
  var il = w, ir = -1, it = h, ib = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (gray[y * w + x] <= thr) continue;
      if (x < il) il = x;
      if (x > ir) ir = x;
      if (y < it) it = y;
      if (y > ib) ib = y;
    }
  }
  if (ir < il || ib < it) return vec;
  final iw = ir - il + 1;
  final ih = ib - it + 1;
  // キャンバス幅は「縦横比から決めた幅」と「実際のインク幅」の大きい方。
  // 小さい方にすると、縦横比より横に広い桁（実測 0.83 前後）が左右に切られ、
  // 8→6, 9→3, 7→2 のように端の画が落ちた字形に化ける。
  final canvasW = math.max(iw.toDouble(), ih * _aspect);
  final offX = (canvasW - iw) / 2; // インク左端をキャンバス上のどこに置くか

  for (var gy = 0; gy < _gh; gy++) {
    for (var gx = 0; gx < _gw; gx++) {
      final cy0 = ih * gy / _gh;
      final cy1 = ih * (gy + 1) / _gh;
      final cx0 = canvasW * gx / _gw;
      final cx1 = canvasW * (gx + 1) / _gw;
      var n = 0;
      var t = 0;
      for (var sy = 0; sy < _sub; sy++) {
        for (var sx = 0; sx < _sub; sx++) {
          final cy = cy0 + (cy1 - cy0) * (sy + 0.5) / _sub;
          final cx = cx0 + (cx1 - cx0) * (sx + 0.5) / _sub;
          t++;
          final px = (cx - offX).round();
          final py = cy.round();
          if (px < 0 || px >= iw || py < 0 || py >= ih) continue;
          if (gray[(it + py) * w + (il + px)] > thr) n++;
        }
      }
      vec[gy * _gw + gx] = t == 0 ? 0 : n / t;
    }
  }
  return vec;
}

double _similarity(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += (a[i] - b[i]).abs();
  }
  return 1 - s / a.length;
}

class _Elem {
  _Elem(this.text, this.box);
  final String text;
  final _ElemBox box;
}

class _ElemBox {
  _ElemBox(this.l, this.t, this.r, this.b);
  final int l;
  final int t;
  final int r;
  final int b;
}

class _ValueRow {
  _ValueRow(this.t, this.b, this.comps);
  int t;
  int b;
  final List<_Comp> comps;

  /// その行のラベル語の右端（画素 x）。値の列はこの右側にある。
  /// BEST SCORE 行は "BEST" と "SCORE" に割れて返り、"SCORE" の右端は値の列まで
  /// 届くので、これが無いとラベルの文字を数字として読んでしまう。
  int labelRight = -1;

  double get centerY => (t + b) / 2;
}

class _Part {
  _Part(this.l, this.t, this.r, this.b);
  final int l;
  final int t;
  final int r;
  final int b;
}

class _Cluster {
  _Cluster(this.parts);
  final List<_Part> parts;

  _Part bbox() => _Part(
    parts.map((p) => p.l).reduce(math.min),
    parts.map((p) => p.t).reduce(math.min),
    parts.map((p) => p.r).reduce(math.max),
    parts.map((p) => p.b).reduce(math.max),
  );
}

class _Comp {
  _Comp(this.l, this.t, this.r, this.b, this.area);
  final int l;
  final int t;
  final int r;
  final int b;
  final int area;
}
