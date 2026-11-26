// GT（ユーザー記入の正解値）に対する ac 抽出精度測定とスコア式分析ツール。
//
// WHY: 以前の行整合性検証は OCR 出力の内部整合しか見えず、値の真偽は判定できな
// かった。ユーザー記入 GT が揃ったため、①フィールド別正答率の実測、②スコア式
// FR-6 の分母（総ノーツ）の実態解明、を機械判定する。②は「分母 = Σ判定数」と
// いう仮定が偽陽性を出した（HOjcQkD/HXQFG2 の bad は真値だった）ことへの訂正
// 調査でもある。
//
// 使い方: dart run tool/analyze_ac_gt.dart [計測出力パス]
// 計測出力パスを省略した場合は run-3（lib/ocr/batch_measurement_output_wave2.txt）。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const _gtPath = 'test/fixtures/ocr/ac_ground_truth.json';
const _wave2Path = 'lib/ocr/batch_measurement_output_wave2.txt';
const _dbPath = 'db/popn_hc_main_v1.json';

const _numericFields = ['score', 'cool', 'great', 'good', 'bad', 'maxCombo'];

/// WHY: GT JSON は既存 ground_truth.json（プレーシェア）と同型のキー
/// （coolCount 等）を採用したため、抽出側フィールド名からの変換が必要。
const _gtKeyOf = {
  'score': 'score',
  'cool': 'coolCount',
  'great': 'greatCount',
  'good': 'goodCount',
  'bad': 'badCount',
  'maxCombo': 'maxCombo',
};

int? _valueOf(String? raw) {
  if (raw == null) {
    return null;
  }
  if (raw == 'null' || raw.isEmpty) {
    return null;
  }
  return int.tryParse(raw.split(' ').first);
}

Map<String, dynamic> _loadJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// 抽出値の生テキストも合わせて返す（誤読の型診断用）。
(int?, String?) _extractedValue(Map<String, dynamic> record, String field) {
  final raw = record[field] as String?;
  if (raw == null || raw == 'null') {
    return (null, null);
  }
  return (_valueOf(raw), raw);
}

void main(List<String> args) {
  final gt = _loadJson(_gtPath);
  final samples = (gt['samples'] as List).cast<Map<String, dynamic>>();

  // WHY: 計測出力を引数で差し替え可能にし、修正前後の比較を同じツールで行う。
  final wave2Lines = File(args.isNotEmpty ? args[0] : _wave2Path)
      .readAsLinesSync();
  final Map<String, Map<String, dynamic>> wave2 = {};
  for (final line in wave2Lines) {
    if (!line.startsWith('{"file"')) {
      continue;
    }
    final rec = jsonDecode(line) as Map<String, dynamic>;
    wave2[rec['file'] as String] = rec;
  }

  // WHY: 引数指定時は計測元を明示する（既定は run-3・修正前計測）。
  final runLabel = args.isNotEmpty ? '指定計測 ${args[0]}' : 'run-3';
  print('## A. 抽出値 vs GT（$runLabel・30 枚）');
  final correct = <String, int>{for (final f in _numericFields) f: 0};
  final misses = <String, int>{for (final f in _numericFields) f: 0};
  final falses = <String, int>{for (final f in _numericFields) f: 0};
  for (final s in samples) {
    final file = s['file'] as String;
    final rec = wave2[file];
    if (rec == null) {
      print('-- $file: wave2 レコードなし（スキップ）');
      continue;
    }
    final cells = <String>[];
    for (final field in _numericFields) {
      // WHY: GT JSON のキーは coolCount 等なので _gtKeyOf で変換する。
      final gtInt = s[_gtKeyOf[field]] as int?;
      final (ex, exRaw) = _extractedValue(rec, field);
      if (ex == null) {
        misses[field] = misses[field]! + 1;
        cells.add('$field:未抽出(GT=$gtInt)');
        continue;
      }
      if (gtInt != null && ex == gtInt) {
        correct[field] = correct[field]! + 1;
        continue;
      }
      falses[field] = falses[field]! + 1;
      cells.add('$field:偽/ex=$ex raw=$exRaw GT=$gtInt');
    }
    if (cells.isNotEmpty) {
      print('-- $file: ${cells.join(' | ')}');
    }
  }
  print('-- 集計（正答/未抽出/不一致・GT 30 件基準）:');
  for (final field in _numericFields) {
    print(
      '   $field: 正答 ${correct[field]}/30 未抽出 ${misses[field]} '
      '不一致 ${falses[field]}',
    );
  }

  print('');
  print('## B. スコア式の分母推定（FR-6 重み cool1.0/great0.7/good0.4/bad0 仮定）');
  // impliedN = (cool + 0.7great + 0.4good) * 100000 / score
  // 同一曲+難易度の写真群で impliedN が一致すれば、分母は譜面固有の総ノーツ
  // （Σ判定数ではない）で式が確定する。
  final db = _loadJson(_dbPath);
  final dbSongs = (db['songs'] as List).cast<Map<String, dynamic>>();
  String? dbNotesFor(String title) {
    for (final s in dbSongs) {
      if (s['title'] == title) {
        final n = s['totalNotes'];
        return n?.toString();
      }
    }
    return null;
  }

  String? dbLevelFor(String title, String difficulty) {
    for (final s in dbSongs) {
      if (s['title'] == title) {
        final levels = s['levels'] as Map<String, dynamic>?;
        return levels?[difficulty]?.toString();
      }
    }
    return null;
  }

  final groups = <String, List<Map<String, dynamic>>>{};
  for (final s in samples) {
    final key = '${s['songTitleRaw']}|${s['difficulty']}';
    groups.putIfAbsent(key, () => []).add(s);
  }
  for (final entry in groups.entries) {
    final parts = entry.key.split('|');
    final title = parts[0];
    final difficulty = entry.key.split('|')[1];
    final dbNotes = dbNotesFor(title);
    final dbLevel = dbLevelFor(title, difficulty);
    print(
      '-- 譜面群 ${entry.key}（DB totalNotes=${dbNotes ?? '無'} '
      'DB$difficulty レベル=${dbLevel ?? '無'}）',
    );
    final impliedNs = <double>[];
    for (final s in entry.value) {
      final score = s['score'] as int;
      final cool = s['coolCount'] as int;
      final great = s['greatCount'] as int;
      final good = s['goodCount'] as int;
      final bad = s['badCount'] as int;
      final sum = cool + great + good + bad;
      final weighted = cool + 0.7 * great + 0.4 * good;
      final impliedN = weighted * 100000 / score;
      impliedNs.add(impliedN);
      final gtLevel = s['level'] as int?;
      final levelNote = (dbLevel != null && gtLevel.toString() != dbLevel)
          ? ' ★レベル不一致'
          : '';
      print(
        '   ${s['file']}: impliedN=${impliedN.toStringAsFixed(2)} '
        'Σ判定=$sum (bad=$bad) score=$score level=$gtLevel$levelNote',
      );
    }
    // WHY: 単写真グループは比較対象がないため「単写真(判定不可)」と表示する。
    // 旧実装は reduce 差分積算のため 1 要素では自身との差になり誤判定した。
    final maxN = impliedNs.reduce((a, b) => a > b ? a : b);
    final minN = impliedNs.reduce((a, b) => a < b ? a : b);
    final spread = maxN - minN;
    final first = impliedNs.first.toStringAsFixed(2);
    final consistent = spread < 0.5;
    final verdict = impliedNs.length < 2
        ? '単写真(判定不可)'
        : consistent
        ? 'YES'
        : 'NO';
    print(
      '   → 分母一致: $verdict '
      '(最初の値=$first・最大差=${spread.toStringAsFixed(2)})',
    );
  }
}
