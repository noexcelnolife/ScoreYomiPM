//
// ac_v1 バッチ計測フィクスチャ構築ツール。
//
// 使い方（リポジトリルートで実行）:
//   dart run tool/build_ac_fixture.dart
//   dart run tool/build_ac_fixture.dart --images=<原本写真ディレクトリ>
//   （testimage/ はリポジトリに同梱していないため、手元のパスを渡す）
//
// 入力（読み取り専用）:
//   - lib/ocr/batch_measurement_output.txt（エミュレータ実機 30 枚一括計測の
//     stdout 記録。30 記録の JSONL + summary 行）
//   - <原本写真ディレクトリ>/*.jpg（計測対象の原本写真・変更禁止領域。既定は testimage/AC-HC-photo）
// 出力（コミット対象）:
//   - test/fixtures/ocr/ac_hc_batch_results.json
//     （hc_v1 の playshare_batch_results.json と同じレポート形式 + 画像寸法）
//
// WHY テキストログから機械変換する: 計測結果の実体ファイルはエミュレータ
// 側に保存されたがアプリ再インストールで消失した。stdout 記録の 1 行 1 記録
// は jsonEncode の完全な出力であり、手作業転記せず機械変換 + 検証で作る。
//
// WHY 画像寸法を焼き込む: hc_v1 フィクスチャは寸法を持たず実画像を都度
// デコードしていた。ac_v1 は抽出検証テストを純 JSON で高速・決定的に走らせ
// たいので、寸法を 1 度だけ取得してフィクスチャに焼き込む（回転 EXIF の
// ML Kit 座標系との整合診断もここで出す）。
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'tool_paths.dart';

/// 計測 stdout 記録（読み取り専用）。
const String _logPath = 'lib/ocr/batch_measurement_output.txt';

/// 原本写真ディレクトリ（読み取り専用・変更禁止領域）。
/// 実画像は公開リポジトリに同梱していないため、main の先頭で
/// `--images=<dir>` の指定があれば差し替える。
String _imageDir = 'testimage/AC-HC-photo';

/// 出力先（コミット対象・上書き冪等）。
const String _outPath = 'test/fixtures/ocr/ac_hc_batch_results.json';

/// ラベル候補の診断用ゲート（暫定 canonical 周辺 ±）。
const double _labelGateCxMin = 0.03;
const double _labelGateCxMax = 0.22;
const double _labelGateCyHalfWidth = 0.045;

/// 暫定 canonical（anchor_pack.json の WIP 値・診断ゲートの中心）。
const Map<String, double> _provisionalCy = {
  'SCORE': 0.065,
  'BEST': 0.125,
  'COOL': 0.255,
  'GREAT': 0.325,
  'GOOD': 0.395,
  'BAD': 0.465,
  'COMBO': 0.535,
};

void main(List<String> args) {
  _imageDir = resolveImageDir(args, _imageDir);
  ensureImageDirExists(_imageDir);
  final records = _loadRecords();
  final summary = _loadSummary();
  final results = _withImageDims(records);
  _writeReport(results, summary);
  _printDiagnostics(results);
}

/// stdout 記録から計測記録（file+elements を持つ JSON 行）を抽出する。
List<Map<String, dynamic>> _loadRecords() {
  final lines = File(_logPath).readAsLinesSync();
  final out = <Map<String, dynamic>>[];
  for (final line in lines) {
    final t = line.trim();
    if (!t.startsWith('{')) {
      continue;
    }
    final obj = jsonDecode(t) as Map<String, dynamic>;
    if (obj.containsKey('file') && obj.containsKey('elements')) {
      out.add(obj);
    }
  }
  if (out.length != 30) {
    throw StateError('records=${out.length} expect 30');
  }
  return out;
}

/// stdout 記録から summary 行（totalImages を持つ JSON 行）を抽出する。
Map<String, dynamic> _loadSummary() {
  final lines = File(_logPath).readAsLinesSync();
  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('{') && t.contains('"totalImages"')) {
      return jsonDecode(t) as Map<String, dynamic>;
    }
  }
  throw StateError('summary line not found');
}

/// 各記録に画像寸法を焼き込む（診断のため bbox 最大値も併せて返す）。
List<Map<String, dynamic>> _withImageDims(List<Map<String, dynamic>> records) {
  final out = <Map<String, dynamic>>[];
  for (final r in records) {
    final file = r['file'] as String;
    final image = _decodeImage('$_imageDir/$file');
    final r2 = Map<String, dynamic>.of(r);
    r2['imageWidth'] = image.width;
    r2['imageHeight'] = image.height;
    out.add(r2);
  }
  return out;
}

img.Image _decodeImage(String path) {
  final image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) {
    throw StateError('cannot decode image: $path');
  }
  return image;
}

/// レポート形式（hc_v1 フィクスチャと同構造 + 画像寸法）で書き出す。
void _writeReport(
  List<Map<String, dynamic>> results,
  Map<String, dynamic> summary,
) {
  final report = <String, dynamic>{
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'script': 'MlKitScript.japanese',
    'imageDir': '${recordedPath(_imageDir)}/',
    'summary': summary,
    'results': results,
  };
  const encoder = JsonEncoder.withIndent('  ');
  File(_outPath).writeAsStringSync('${encoder.convert(report)}\n');
  stdout.writeln('fixture written: $_outPath (${results.length} records)');
}

/// 診断出力: 画像寸法系の整合とラベル語彙（マッチャ設計の根拠）。
void _printDiagnostics(List<Map<String, dynamic>> results) {
  stdout.writeln('--- dimension diagnostics ---');
  for (final r in results) {
    final file = r['file'] as String;
    final w = r['imageWidth'] as int;
    final h = r['imageHeight'] as int;
    var maxR = 0;
    var maxB = 0;
    for (final e in (r['elements'] as List<dynamic>)) {
      final bb =
          (e as Map<String, dynamic>)['boundingBox'] as Map<String, dynamic>;
      maxR = (bb['r'] as num).toInt() > maxR ? (bb['r'] as num).toInt() : maxR;
      maxB = (bb['b'] as num).toInt() > maxB ? (bb['b'] as num).toInt() : maxB;
    }
    final aspect = (w / h).toStringAsFixed(3);
    final suspect = maxR > w || maxB > h ? 'ROTATION?' : '';
    stdout.writeln(
      '$file ${w}x$h aspect=$aspect maxR=$maxR maxB=$maxB $suspect',
    );
  }
  _printLabelVocabulary(results);
}

/// ラベル語彙診断: 暫定 canonical ゲート内の全テキストを種類ごとに出す。
///
/// WHY ゲート内の全語彙を出す: マッチャ（完全一致 + 誤読語）は実データの
/// 誤読語彙から設計する。ゲート内に想定外の語があればマッチャ誤設計を防げる。
void _printLabelVocabulary(List<Map<String, dynamic>> results) {
  stdout.writeln('--- label vocabulary near provisional canonical ---');
  final vocab = <String, Set<String>>{
    for (final k in _provisionalCy.keys) k: <String>{},
  };
  for (final r in results) {
    final w = (r['imageWidth'] as num).toDouble();
    final h = (r['imageHeight'] as num).toDouble();
    for (final e in (r['elements'] as List<dynamic>)) {
      final map = e as Map<String, dynamic>;
      final bb = map['boundingBox'] as Map<String, dynamic>;
      final cx = ((bb['l'] as num) + (bb['r'] as num)) / 2 / w;
      final cy = ((bb['t'] as num) + (bb['b'] as num)) / 2 / h;
      if (cx < _labelGateCxMin || cx > _labelGateCxMax) {
        continue;
      }
      final text = (map['text'] as String).trim().toUpperCase();
      for (final entry in _provisionalCy.entries) {
        if ((cy - entry.value).abs() <= _labelGateCyHalfWidth) {
          vocab[entry.key]!.add(text);
        }
      }
    }
  }
  for (final entry in vocab.entries) {
    final texts = entry.value.toList()..sort();
    stdout.writeln('${entry.key}: ${texts.join(' | ')}');
  }
}
