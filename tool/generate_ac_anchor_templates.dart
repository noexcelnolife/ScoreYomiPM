// ac_v1 アンカーパック実測校正ツール（01a2060d Phase 7・リード引き取り分）。
//
// 目的:
// - 30 枚実機計測フィクスチャ（test/fixtures/ocr/ac_hc_batch_results.json）から
//   ラベルアンカー 7 種の canonical を主群 4:3横バケット（23 枚）中央値で導出する。
// - モーダル解像度（2048x1536）写真から NCC テンプレート PNG を切り出し
//   assets/anchors/ac_v1/ へ書き出す。
// - frameRight（columnEdge）の canonical を画素実測（列強度ピーク）で更新する。
// - 実行時検出（lib/ocr/ui_anchor.dart）の正確なミラーで全 30 枚を検証し、
//   解像度別ヒット率を正直に報告する（Q3 証跡: 単一スケール NCC の限界）。
//
// 使い方:
//   C:\dev\flutter\bin\dart.bat run tool/generate_ac_anchor_templates.dart
//   C:\dev\flutter\bin\dart.bat run tool/generate_ac_anchor_templates.dart --images=<実機写真ディレクトリ>
//   （testimage/ はリポジトリに同梱していないため、手元のパスを渡す）
//
// WHY ui_anchor.dart を import しない: private 定数群（_nccScoreThreshold 等）
// の値をツール側でも固定値としてミラー保持する（実行時ゲートと生成値の二重化。
// ずれは asset 契約テスト test/ac_anchor_pack_contract_test.dart で検知する）。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'tool_paths.dart';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

/// 実機写真ディレクトリ。実画像は公開リポジトリに同梱していないため、
/// main の先頭で `--images=<dir>` の指定があれば差し替える。
String _imageDir = 'testimage/AC-HC-photo';
const String _outDir = 'assets/anchors/ac_v1';

/// ui_anchor.dart `_downscale` のミラー（探索/テンプレ共通の縮小率）。
const int _downscale = 4;

/// ui_anchor.dart `_nccSearchRadiusPx` のミラー（canonical 予測中心から・
/// 正規化前 px の探索窓半径）。
const double _nccSearchRadiusPx = 96;

/// ui_anchor.dart `_nccScoreThreshold` のミラー（NCC 採用最低スコア）。
const double _nccScoreThreshold = 0.55;

/// ui_anchor.dart `_columnEdgeSearchRadiusPx` のミラー。
const double _columnEdgeSearchRadiusPx = 12;

/// ui_anchor.dart `_columnEdgeMinStrength` のミラー（列平均 |dx|・0-255）。
const double _columnEdgeMinStrength = 25;

/// テンプレート余白（モーダル解像度 2048px 基準・フル解像度 px）。
/// WHY 10: hc_v1 は 6px@1200 基準。2048/1200 倍の比率換算（≈10.2）で
/// スケール不変の余白率を保つ。
const int _templateMarginPx = 10;

/// 主群バケットのアスペクト比窓 [1.25, 1.45]。
/// WHY: 30 枚は 4:3横 21 枚 + 準 4:3横 2 枚（1.317 / 1.399）+ 16:9横 5 枚 +
/// 4:3縦 2 枚。canonical は構図クラスを混合しないため主群のみから導出する
///（16:9 と縦構図はレイアウト比率が違い、中央値を汚す）。
const double _bucketAspectMin = 1.25;
const double _bucketAspectMax = 1.45;

/// frameRight 再計測帯（現行推定 canonical x=0.88 の近傍を広めに覆う）。
const double _frameRightBandMin = 0.80;
const double _frameRightBandMax = 0.94;

/// ラベルアンカー契約 id → マッチャテキスト（実行時 _anchorKinds と同テキスト）。
/// labelScore のみ 1 写真に 2 要素（最上行 + BEST SCORE 行）が存在するため
/// 最上行（最小 cy）のみを採用する（_keepTopmostPerPhoto）。
const Map<String, String> _labelTexts = {
  'labelScore': 'SCORE',
  'labelBest': 'BEST',
  'labelCool': 'COOL',
  'labelGreat': 'GREAT',
  'labelGood': 'GOOD',
  'labelBad': 'BAD',
  'labelCombo': 'COMBO',
};

/// パック相対のテンプレート PNG ファイル名。
const Map<String, String> _templateFiles = {
  'labelScore': 'label_score.png',
  'labelBest': 'label_best.png',
  'labelCool': 'label_cool.png',
  'labelGreat': 'label_great.png',
  'labelGood': 'label_good.png',
  'labelBad': 'label_bad.png',
  'labelCombo': 'label_combo.png',
};

/// 短縮表示用（検証サマリの表幅を保つ）。
const Map<String, String> _shortIds = {
  'frameRight': 'fRight',
  'labelScore': 'score',
  'labelBest': 'best',
  'labelCool': 'cool',
  'labelGreat': 'great',
  'labelGood': 'good',
  'labelBad': 'bad',
  'labelCombo': 'combo',
};

/// フィクスチャの 1 ラベル候補要素。
class _Candidate {
  const _Candidate(
    this.file,
    this.bbox,
    this.cx,
    this.cy,
    this.width,
    this.height,
  );

  final String file;
  final Map<String, dynamic> bbox;
  final double cx;
  final double cy;
  final int width;
  final int height;
}

/// 1 アンカーの導出結果。
class _AnchorDerivation {
  const _AnchorDerivation({
    required this.canonicalX,
    required this.canonicalY,
    required this.reference,
    required this.candidateCount,
  });

  final double canonicalX;
  final double canonicalY;
  final _Candidate reference;
  final int candidateCount;
}

/// 検証 1 件（1 写真 × 1 アンカー）の記録。
class _HitRecord {
  const _HitRecord(
    this.file,
    this.res,
    this.id,
    this.hit,
    this.score,
    this.errPx,
  );

  final String file;
  final String res;
  final String id;
  final bool hit;
  final double? score;
  final double? errPx;
}

/// テンプレート実体（縮小グレースケール・実行時 UiAnchorTemplate のミラー）。
typedef _Template = (Uint8List gray, int width, int height);

/// 縮小グレースケール画像と寸法。
typedef _SmallImage = (Uint8List gray, int width, int height);

void main(List<String> args) {
  _imageDir = resolveImageDir(args, _imageDir);
  ensureImageDirExists(_imageDir);
  final fixture = _loadFixture();
  final dims = _imageDims(fixture);
  final files = dims.keys.toList()..sort();
  final candidatesAll = _collectCandidates(fixture, files, dims);
  final bucketFiles = files
      .where((f) => _isBucketPhoto(dims[f]!.$1, dims[f]!.$2))
      .toList(growable: false);
  stdout.writeln(
    'photos: ${files.length}, bucket(主群 4:3横): ${bucketFiles.length}',
  );
  final modal = _modalSize(bucketFiles.map((f) => dims[f]!).toList());
  stdout.writeln('modal resolution: ${modal.$1}x${modal.$2}');

  final derivations = <String, _AnchorDerivation>{};
  for (final id in _templateFiles.keys) {
    final bucketCandidates = candidatesAll[id]!
        .where((c) => bucketFiles.contains(c.file))
        .toList(growable: false);
    derivations[id] = _deriveAnchor(id, bucketCandidates, modal);
    _writeTemplatePng(derivations[id]!.reference, _templateFiles[id]!);
  }
  final frameRightX = _measureFrameRight(bucketFiles);
  _writePackJson(derivations, frameRightX, bucketFiles.length);
  _writeManifest(derivations, frameRightX, modal, bucketFiles.length);
  _validate(files, candidatesAll, derivations, frameRightX);
}

Map<String, dynamic> _loadFixture() {
  return jsonDecode(File(_fixturePath).readAsStringSync())
      as Map<String, dynamic>;
}

/// ファイル名 → (幅, 高さ)。フィクスチャに焼き込まれた実寸を使う
///（build_ac_fixture.dart が image パッケージ実デコードで焼き込んだ値）。
Map<String, (int, int)> _imageDims(Map<String, dynamic> fixture) {
  final out = <String, (int, int)>{};
  for (final raw in fixture['results'] as List<dynamic>) {
    final map = raw as Map<String, dynamic>;
    out[map['file'] as String] = (
      (map['imageWidth'] as num).toInt(),
      (map['imageHeight'] as num).toInt(),
    );
  }
  return out;
}

/// 主群 4:3横 バケット判定（横構図かつアスペクト比が [_bucketAspectMin, _bucketAspectMax]）。
bool _isBucketPhoto(int width, int height) {
  if (width <= height) {
    return false;
  }
  final aspect = width / height;
  return aspect >= _bucketAspectMin && aspect <= _bucketAspectMax;
}

/// 最頻解像度（枚数最大・同数時は面積大を優先、次に幅大で決定的化）。
(int, int) _modalSize(List<(int, int)> sizes) {
  final counts = <(int, int), int>{};
  for (final size in sizes) {
    counts[size] = (counts[size] ?? 0) + 1;
  }
  final entries = counts.keys.toList()
    ..sort((a, b) {
      final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
      if (byCount != 0) {
        return byCount;
      }
      final byArea = (b.$1 * b.$2).compareTo(a.$1 * a.$2);
      if (byArea != 0) {
        return byArea;
      }
      return a.$1.compareTo(b.$1);
    });
  return entries.first;
}

/// 全写真から 7 ラベルの候補要素を収集する（検証の GT 近接にも使う）。
Map<String, List<_Candidate>> _collectCandidates(
  Map<String, dynamic> fixture,
  List<String> files,
  Map<String, (int, int)> dims,
) {
  final byFile = <String, List<Map<String, dynamic>>>{};
  for (final raw in fixture['results'] as List<dynamic>) {
    final map = raw as Map<String, dynamic>;
    byFile[map['file'] as String] = (map['elements'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }
  final out = <String, List<_Candidate>>{
    for (final id in _labelTexts.keys) id: <_Candidate>[],
  };
  for (final file in files) {
    final (w, h) = dims[file]!;
    for (final element in byFile[file] ?? const <Map<String, dynamic>>[]) {
      final text = (element['text'] as String).trim().toUpperCase();
      final b = element['boundingBox'] as Map<String, dynamic>;
      final cx = ((b['l'] as num) + (b['r'] as num)) / 2 / w;
      final cy = ((b['t'] as num) + (b['b'] as num)) / 2 / h;
      for (final id in _labelTexts.keys) {
        if (text != _labelTexts[id]) {
          continue;
        }
        out[id]!.add(_Candidate(file, b, cx, cy, w, h));
      }
    }
  }
  _keepTopmostPerPhoto(out['labelScore']!);
  return out;
}

/// 最上行 SCORE のみを残す（1 写真に 2 要素: 最上行 + BEST SCORE 行）。
/// WHY 最小 cy: 実行時テキストアンカーは ML Kit 読み順（左上優先）の先勝ち
/// で最上行 SCORE を採るため、テンプレ参照も同一要素に合わせる。
void _keepTopmostPerPhoto(List<_Candidate> candidates) {
  final bestByFile = <String, _Candidate>{};
  for (final c in candidates) {
    final best = bestByFile[c.file];
    if (best == null || c.cy < best.cy) {
      bestByFile[c.file] = c;
    }
  }
  final kept = bestByFile.values.toList()
    ..sort((a, b) => a.file.compareTo(b.file));
  candidates
    ..clear()
    ..addAll(kept);
}

/// バケット候補の中央値から canonical を導出し、テンプレ参照写真を選ぶ。
_AnchorDerivation _deriveAnchor(
  String id,
  List<_Candidate> candidates,
  (int, int) modal,
) {
  if (candidates.isEmpty) {
    throw StateError('label anchor $id has no bucket candidate');
  }
  final xs = candidates.map((c) => c.cx).toList()..sort();
  final ys = candidates.map((c) => c.cy).toList()..sort();
  final mx = _median(xs);
  final my = _median(ys);
  // 参照候補はモーダル解像度写真から選ぶ（テンプレートは単一スケールのため
  // 最頻解像度で切り出すのが期待命中率を最大化する）。
  final modalPool = candidates
      .where((c) => c.width == modal.$1 && c.height == modal.$2)
      .toList(growable: false);
  final pool = modalPool.isEmpty ? candidates : modalPool;
  var best = pool.first;
  var bestDist = double.infinity;
  for (final c in pool) {
    // WHY (h/w) 重み: dx は幅基準・dy は高さ基準のため物理距離へ同一化する。
    final dx = c.cx - mx;
    final dy = (c.cy - my) * c.height / c.width;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < bestDist) {
      bestDist = dist;
      best = c;
    }
  }
  stdout.writeln(
    'derive $id: candidates=${candidates.length} '
    'median=(${mx.toStringAsFixed(4)}, ${my.toStringAsFixed(4)}) '
    'ref=${best.file} (${best.width}x${best.height})',
  );
  return _AnchorDerivation(
    canonicalX: mx,
    canonicalY: my,
    reference: best,
    candidateCount: candidates.length,
  );
}

/// frameRight の canonical x を画素実測で導出する（主群バケット全枚）。
double _measureFrameRight(List<String> bucketFiles) {
  final xs = <double>[];
  final strengths = <double>[];
  for (final file in bucketFiles) {
    final loaded = _decodeDownscaledGray('$_imageDir/$file');
    if (loaded == null) {
      stdout.writeln('frameRight measure: decode failed: $file');
      continue;
    }
    final (gray, w, h) = loaded;
    final byCol = _columnStrengths(gray, w, h);
    final band = _strongestColumnInBand(
      byCol,
      w,
      _frameRightBandMin,
      _frameRightBandMax,
    );
    if (band == null) {
      continue;
    }
    xs.add(band.$1 / w);
    strengths.add(band.$2);
    stdout.writeln(
      'frameRight $file: x=${(band.$1 / w).toStringAsFixed(4)} '
      'strength=${band.$2.toStringAsFixed(1)}',
    );
  }
  if (xs.isEmpty) {
    throw StateError('frameRight: no measurable column in band');
  }
  final sortedXs = List<double>.of(xs)..sort();
  final mx = _median(sortedXs);
  final sortedStrengths = List<double>.of(strengths)..sort();
  stdout.writeln(
    'frameRight median x=${mx.toStringAsFixed(4)} '
    '(min=${sortedXs.first.toStringAsFixed(4)}, max=${sortedXs.last.toStringAsFixed(4)}) '
    'strength median=${_median(sortedStrengths).toStringAsFixed(1)} '
    '(min=${sortedStrengths.first.toStringAsFixed(1)}, max=${sortedStrengths.last.toStringAsFixed(1)})',
  );
  return mx;
}

/// 帯 [xMin, xMax]（正規化 x）内で最強の列を返す（測定帯用・閾値判定なし）。
(int, double)? _strongestColumnInBand(
  Float64List strengths,
  int w,
  double xMin,
  double xMax,
) {
  final minCol = (xMin * w).floor().clamp(0, w - 2).toInt();
  final maxCol = (xMax * w).floor().clamp(0, w - 2).toInt();
  var bestX = -1;
  var best = 0.0;
  for (var x = minCol; x <= maxCol; x++) {
    if (strengths[x] > best) {
      best = strengths[x];
      bestX = x;
    }
  }
  if (bestX < 0) {
    return null;
  }
  return (bestX, best);
}

/// 参照写真からテンプレート PNG（フル解像度クロップ）を書き出す。
void _writeTemplatePng(_Candidate ref, String fileName) {
  final bytes = File('$_imageDir/${ref.file}').readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    throw StateError('template reference decode failed: ${ref.file}');
  }
  final b = ref.bbox;
  final left = ((b['l'] as num).toInt() - _templateMarginPx).clamp(
    0,
    image.width - 1,
  );
  final top = ((b['t'] as num).toInt() - _templateMarginPx).clamp(
    0,
    image.height - 1,
  );
  final right = ((b['r'] as num).toInt() + _templateMarginPx).clamp(
    left,
    image.width - 1,
  );
  final bottom = ((b['b'] as num).toInt() + _templateMarginPx).clamp(
    top,
    image.height - 1,
  );
  final crop = img.copyCrop(
    image,
    x: left,
    y: top,
    width: right - left + 1,
    height: bottom - top + 1,
  );
  Directory(_outDir).createSync(recursive: true);
  File('$_outDir/$fileName').writeAsBytesSync(img.encodePng(crop));
  stdout.writeln(
    'template $fileName: ${crop.width}x${crop.height} px from ${ref.file} '
    'crop=($left,$top)-($right,$bottom)',
  );
}

/// 実測 canonical とテンプレート参照で anchor_pack.json を書き直す。
void _writePackJson(
  Map<String, _AnchorDerivation> derivations,
  double frameRightX,
  int bucketCount,
) {
  final definitions = <Map<String, dynamic>>[
    {
      'id': 'frameRight',
      'kind': 'columnEdge',
      'canonical': {'x': frameRightX, 'y': 0.5},
      'threshold': _columnEdgeMinStrength / 255,
      'template': null,
      'matchedImages': bucketCount,
      'note':
          '主群バケット画素実測（列強度ピーク中央値）。'
          '実行時ゲートは ui_anchor.dart _columnEdgeMinStrength。',
    },
    for (final id in _templateFiles.keys)
      {
        'id': id,
        'kind': 'ncc',
        'canonical': {
          'x': derivations[id]!.canonicalX,
          'y': derivations[id]!.canonicalY,
        },
        'threshold': _nccScoreThreshold,
        'template': _templateFiles[id],
        'matchedImages': derivations[id]!.candidateCount,
        'note': '主群バケット中央値 canonical・モーダル解像度テンプレート。',
      },
  ];
  final pack = {
    'version': 'ac_v1',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'generator': 'tool/generate_ac_anchor_templates.dart (実測校正 2026-11-23)',
    'sourceFixture': _fixturePath,
    'sourceImages': 30,
    'baseImage': '2048x1536 (主群モーダル解像度・テンプレ切り出し基準)',
    'note':
        'ac_v1 実測校正版。canonical は主群 4:3横バケット（aspect [1.25,1.45]）'
        'の ML Kit 実測中央値。NCC テンプレートは単一スケール・固定 canonical のため'
        '構図・解像度が離れると欠落し得る（解像度別ヒット率は生成ツールの検証出力と'
        ' manifest を参照）。欠落時は ML Kit テキストアンカー主経路が抽出を継続する'
        'ため機能への影響はない。実行時ゲート定数は ui_anchor.dart の named 定数群'
        'をミラー（契約テストで一致を固定）。',
    'definitions': definitions,
  };
  const encoder = JsonEncoder.withIndent('  ');
  File('$_outDir/anchor_pack.json')
      .writeAsStringSync('${encoder.convert(pack)}\n');
  stdout.writeln('wrote $_outDir/anchor_pack.json');
}

/// manifest.json を書き直す（生成 provenance・バケット定義・限界の明記）。
void _writeManifest(
  Map<String, _AnchorDerivation> derivations,
  double frameRightX,
  (int, int) modal,
  int bucketCount,
) {
  final anchors = <Map<String, dynamic>>[
    {
      'id': 'frameRight',
      'template': null,
      'referenceImage': null,
      'cropMarginPx': 0,
      'canonical': {'x': frameRightX, 'y': 0.5},
      'matchedImages': bucketCount,
      'note': '主群バケット画素実測（列強度ピーク中央値・帯 [0.80, 0.94]）。',
    },
    for (final id in _templateFiles.keys)
      {
        'id': id,
        'template': _templateFiles[id],
        'referenceImage': derivations[id]!.reference.file,
        'cropMarginPx': _templateMarginPx,
        'canonical': {
          'x': derivations[id]!.canonicalX,
          'y': derivations[id]!.canonicalY,
        },
        'matchedImages': derivations[id]!.candidateCount,
        'note':
            '主群バケット中央値 canonical（候補 ${derivations[id]!.candidateCount} 枚）。'
            'テンプレはモーダル解像度 ${modal.$1}x${modal.$2} 写真から切り出し。',
      },
  ];
  final manifest = {
    'version': 'ac_v1',
    'generatedAt': '2026-11-23',
    'generator':
        'tool/generate_ac_anchor_templates.dart (実測校正・01a2060d Phase 7)',
    'sourceFixture': _fixturePath,
    'sourceImages': 30,
    'imageCount': 30,
    'baseImage': '${modal.$1}x${modal.$2} (主群モーダル解像度)',
    'bucketDefinition':
        '主群 4:3横: landscape (w>h) かつ aspect in [1.25, 1.45] → $bucketCount/30 枚',
    'thresholdNote':
        'NCC 閾値 0.55・columnEdge 強度 25（0-255 スケール）は'
        'lib/ocr/ui_anchor.dart の named 定数群のミラー（asset 契約テストで固定）。',
    'limitationNote':
        'NCC テンプレートは単一スケール（${modal.$1}x${modal.$2} 切り出し）'
        'かつ固定 canonical。ラベル位置は写真構図で cy が大きく動く（例: 最上行 SCORE '
        'cy 0.371-0.654）。よって構図・解像度が離れた写真では NCC は欠落し得る。'
        '欠落時は ML Kit テキストアンカー主経路（FieldExtractor LayoutKind.acV1）が'
        '抽出を継続するため実機能への影響はない。マルチスケール対応は未決課題'
        '（裁定 Q3: フォールバック必要）。',
    'designPolicy':
        '実運用条件の多様性を前提とした設計（ユーザー裁定 2026-11-23）。'
        'AC-HC-photo 30 枚は協力者から得られた実運用写真であり、反射・照度・カメラ角度・'
        '解像度差・縦構図といった幾何ばらつきは除外対象ではなく ac_v1 が耐えるべき'
        '実運用条件そのもの。30 枚全員を測定コーパスとし、対象外群は設置しない。',
    'matchers': [
      for (final id in _templateFiles.keys)
        {
          'id': id,
          'kind': 'ncc',
          'text': _labelTexts[id],
          if (id == 'labelScore') 'selection': '最上行（1 写真に 2 要素存在・最小 cy を採用）',
        },
      {
        'id': 'frameRight',
        'kind': 'columnEdge',
        'description': '結果画面右端の縦線（カラムエッジ）。NCC テンプレート未使用。',
      },
    ],
    'anchors': anchors,
  };
  const encoder = JsonEncoder.withIndent('  ');
  File('$_outDir/manifest.json')
      .writeAsStringSync('${encoder.convert(manifest)}\n');
  stdout.writeln('wrote $_outDir/manifest.json');
}

/// 書き出したテンプレ PNG を実行時と同一手順（/4 縮小・平均補間）で読み込む。
Map<String, _Template> _loadTemplatesFromDisk() {
  final out = <String, _Template>{};
  for (final entry in _templateFiles.entries) {
    final bytes = File('$_outDir/${entry.value}').readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw StateError('written template decode failed: ${entry.value}');
    }
    final small = img.copyResize(
      image,
      width: image.width ~/ _downscale,
      height: image.height ~/ _downscale,
      interpolation: img.Interpolation.average,
    );
    out[entry.key] = (_grayscaleOf(small), small.width, small.height);
  }
  return out;
}

/// 全 30 枚を実行時検出の正確なミラーで検証する。
void _validate(
  List<String> files,
  Map<String, List<_Candidate>> candidatesAll,
  Map<String, _AnchorDerivation> derivations,
  double frameRightX,
) {
  final templates = _loadTemplatesFromDisk();
  final records = <_HitRecord>[];
  for (final file in files) {
    final loaded = _decodeDownscaledGray('$_imageDir/$file');
    if (loaded == null) {
      stdout.writeln('validate: decode failed: $file');
      continue;
    }
    final (gray, w, h) = loaded;
    final res = '${w * _downscale}x${h * _downscale}';
    for (final id in _templateFiles.keys) {
      final hit = _detectNccMirror(
        templates[id]!,
        gray,
        w,
        h,
        derivations[id]!.canonicalX,
        derivations[id]!.canonicalY,
      );
      final gt = _gtNear(candidatesAll[id]!, file, hit?.$1, hit?.$2);
      records.add(_HitRecord(file, res, id, hit != null, hit?.$3, gt));
    }
    final byCol = _columnStrengths(gray, w, h);
    final edge = _detectColumnEdgeMirror(byCol, w, frameRightX);
    records.add(
      _HitRecord(file, res, 'frameRight', edge != null, edge?.$2, null),
    );
  }
  _printSummary(records, files.length);
}

/// ヒット位置と同一ラベル実測要素中心の距離（2048px 幅基準 px・GT なしは null）。
double? _gtNear(
  List<_Candidate> candidates,
  String file,
  double? hitX,
  double? hitY,
) {
  if (hitX == null || hitY == null) {
    return null;
  }
  final sameFile = candidates.where((c) => c.file == file).toList();
  if (sameFile.isEmpty) {
    return null;
  }
  var best = double.infinity;
  for (final c in sameFile) {
    // WHY x 重み 1・y 重み (4/3): 正規化 x/y のスケール差を 4:3 基準で同一化。
    final dx = (c.cx - hitX) * 2048;
    final dy = (c.cy - hitY) * 2048 * 4 / 3;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < best) {
      best = dist;
    }
  }
  return best;
}

/// 実行時 _detectNcc の正確なミラー（定数・クランプ・中心定義を同一にする）。
(double, double, double)? _detectNccMirror(
  _Template template,
  Uint8List gray,
  int w,
  int h,
  double canonicalX,
  double canonicalY,
) {
  final (tGray, tw, th) = template;
  if (tw < 1 || th < 1 || w < tw || h < th) {
    return null;
  }
  final n = tw * th;
  var tSum = 0;
  var tSumSq = 0;
  for (var i = 0; i < n; i++) {
    final v = tGray[i];
    tSum += v;
    tSumSq += v * v;
  }
  final tMean = tSum / n;
  final tVar = tSumSq / n - tMean * tMean;
  if (tVar <= 0) {
    return null;
  }
  final predictedCx = canonicalX * w;
  final predictedCy = canonicalY * h;
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
      final score = _nccAtMirror(tGray, tw, gray, w, u, v, n, tMean, tVar);
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
  return ((bestU + (tw - 1) / 2) / w, (bestV + (th - 1) / 2) / h, bestScore);
}

/// (u, v) 左上の窓とテンプレートの Pearson 相関（実行時 _nccAt のミラー）。
double _nccAtMirror(
  Uint8List tGray,
  int tw,
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
  // WHY th = n ~/ tw: テンプレートは row-major で n = tw * th。
  final th = n ~/ tw;
  for (var y = v; y < v + th; y++) {
    var idx = y * w + u;
    for (var x = 0; x < tw; x++) {
      final t = tGray[k];
      final pixel = gray[idx];
      iSum += pixel;
      iSumSq += pixel * pixel;
      cross += t * pixel;
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

/// 実行時 _detectColumnEdge の正確なミラー（列強度は呼び出し側で事前計算）。
(double, double)? _detectColumnEdgeMirror(
  Float64List strengths,
  int w,
  double canonicalX,
) {
  final predicted = canonicalX * w;
  final radius = (_columnEdgeSearchRadiusPx / _downscale).ceil();
  final minCol = (predicted - radius).floor().clamp(0, w - 2).toInt();
  final maxCol = (predicted + radius).floor().clamp(0, w - 2).toInt();
  var bestX = -1;
  var best = 0.0;
  for (var x = minCol; x <= maxCol; x++) {
    if (strengths[x] > best) {
      best = strengths[x];
      bestX = x;
    }
  }
  if (bestX < 0 || best < _columnEdgeMinStrength) {
    return null;
  }
  return (bestX / w, best);
}

/// 全高列エッジの列強度（平均 |dx|・実行時と同一実装）。
Float64List _columnStrengths(Uint8List gray, int w, int h) {
  final strengths = Float64List(w);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w - 1; x++) {
      strengths[x] += (gray[y * w + x + 1] - gray[y * w + x]).abs();
    }
  }
  for (var x = 0; x < w - 1; x++) {
    strengths[x] /= h;
  }
  return strengths;
}

/// 生画像を /4 縮小・グレースケール化する（実行時 detect と同一手順）。
_SmallImage? _decodeDownscaledGray(String path) {
  final bytes = File(path).readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    return null;
  }
  final small = img.copyResize(
    image,
    width: image.width ~/ _downscale,
    height: image.height ~/ _downscale,
    interpolation: img.Interpolation.average,
  );
  return (_grayscaleOf(small), small.width, small.height);
}

/// 0..255 輝度 row-major 配列化（実行時 _grayscaleOf と同一実装）。
Uint8List _grayscaleOf(img.Image image) {
  final gray = Uint8List(image.width * image.height);
  var i = 0;
  for (final p in image) {
    final lum = p.luminance.toInt();
    gray[i++] = lum < 0 ? 0 : (lum > 255 ? 255 : lum);
  }
  return gray;
}

/// 中央値（偶数個は中間 2 値の平均）。
double _median(List<double> values) {
  assert(values.isNotEmpty);
  final sorted = List<double>.of(values)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// 検証サマリ（全体ヒット率・解像度別ヒット表・誤差統計）を出力する。
void _printSummary(List<_HitRecord> records, int photoCount) {
  stdout.writeln('');
  stdout.writeln(
    '=== validation summary (threshold mirror: NCC $_nccScoreThreshold '
    '/ edge $_columnEdgeMinStrength) ===',
  );
  _printOverallTable(records, photoCount);
  _printResolutionTable(records);
}

/// アンカー別の全体ヒット率・スコア・誤差統計を出力する。
void _printOverallTable(List<_HitRecord> records, int photoCount) {
  for (final id in {..._shortIds.keys}) {
    final subset = records.where((r) => r.id == id).toList();
    final hits = subset.where((r) => r.hit).toList();
    final scores = hits.map((r) => r.score ?? 0).toList()..sort();
    final errs = hits.map((r) => r.errPx).whereType<double>().toList()..sort();
    final errText = errs.isEmpty
        ? '-'
        : 'errPx median=${_median(errs).toStringAsFixed(1)} max=${errs.last.toStringAsFixed(1)}';
    final scoreText = scores.isEmpty
        ? '-'
        : 'score median=${_median(scores).toStringAsFixed(3)} min=${scores.first.toStringAsFixed(3)}';
    stdout.writeln(
      '${_shortIds[id]!.padRight(6)} ${hits.length.toString().padLeft(2)}/'
      '${subset.length.toString().padLeft(2)} ($photoCount 枚中) $scoreText $errText',
    );
  }
}

/// 解像度別のヒット数表を出力する（単一スケール限界の正直な証跡）。
void _printResolutionTable(List<_HitRecord> records) {
  final resolutions = records.map((r) => r.res).toSet().toList()..sort();
  final ids = _shortIds.keys.toList(growable: false);
  final header = ids.map((id) => _shortIds[id]!.padLeft(6)).join();
  stdout.writeln('');
  stdout.writeln('resolution      n$header');
  for (final res in resolutions) {
    final subset = records.where((r) => r.res == res).toList();
    final files = subset.map((r) => r.file).toSet();
    final counts = ids
        .map((id) => subset.where((r) => r.id == id && r.hit).length)
        .map((c) => c.toString().padLeft(6))
        .join();
    stdout.writeln(
      '${res.padRight(16)}${files.length.toString().padLeft(2)}$counts',
    );
  }
}
