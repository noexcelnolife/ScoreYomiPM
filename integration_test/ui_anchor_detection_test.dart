// ST-3.5: UI アンカー検出の実画像 integration red（横 30 枚 + 縦帯 9 枚）
//
// 検証内容:
// 1. asset パック（assets/anchors/hc_v1/）がデバイスで rootBundle 経由で
//    読めること（本物のバンドル Asset 経路の実証）
// 2. 横 30 枚の原画像に対する AnchorRegistration.detect の検出率が
//    設計の実測下限を満たすこと（ホスト検証 tool/generate_anchor_templates.dart
//    の 30 枚検証と同条件・package:image デコードは決定的のため同値期待）:
//    - frameRight 30/30（設計 §1.1 枠線 x≈536px・下限 28/30）
//    - gaugeHeader 29/30・avgScore 0.823（設計 §1.2 下限 25/30）
//    - settingsNormal 30/30・avgScore 0.890（観測のみ・下限 25/30）
//    - difficultyEx 30/30・avgScore 0.870（要素存在 24/30・下限 24/30）
// 3. 縦帯 9 枚（タスク A 正規化クロップ 1080x714-715）への横テンプレ適用
//    （設計 §1.4 クロスアスペクト 18/18・avgNCC 0.78 は緩和閾値 0.495 の
//    実測。実行時ゲートは 0.55 固定のため下限は暫定 6/9 とし、KPI は
//    QA-Docs 第 4 回効果検証で確定する・fake での主張禁止）
// 4. detect 1 画像あたりの所要時間（デコード+縮小+検出）を計測出力
//   （設計 §1.5 の ≤150ms 目標のパイプライン全体計測は QA-Docs 第 4 回）
//
// 制約: testimage push 分（/data/local/tmp/pm_test/testimage/）は変更禁止。
//
// 実行: flutter test integration_test/ui_anchor_detection_test.dart -d emulator-5554
// （QA-Docs 効果検証計測と同時実行しない: adb 競合で計測が乱れる）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/ocr/input_preprocessing.dart';
import 'package:scoreyomipm/ocr/ui_anchor.dart';

const String _deviceDir = '/data/local/tmp/pm_test/testimage';

/// 横 30 枚（fixtures の results[].file と同一・決定的順序）。
final List<String> _landscapeFiles = <String>[
  'p2039987434814058511_media_1795266589578_23bjim.jpg',
  'p2039987434814058511_media_1795266589578_g7p9b2.jpg',
  'p2039987434814058511_media_1795266589578_usnb54.jpg',
  'p2039987434814058511_media_1795266589578_xpnzu8.jpg',
  'p2039987443219517586_media_1795266589611_52c4xa.jpg',
  'p2039987443219517586_media_1795266589611_al9lbl.jpg',
  'p2040049959459066123_media_1795266679054_5p1lg4.jpg',
  'p2040049959459066123_media_1795266679054_711q04.jpg',
  'p2040049959459066123_media_1795266679054_kt1odi.jpg',
  'p2040049959459066123_media_1795266679054_yb5h8w.jpg',
  'p2040662444465643864_media_1795266616011_bet7t4.jpg',
  'p2040662444465643864_media_1795266616011_enco0h.jpg',
  'p2040662444465643864_media_1795266616011_o8li0f.jpg',
  'p2040662444465643864_media_1795266616011_ph0l0k.jpg',
  'p2042268136691630118_media_1795266573291_e6xlzd.jpg',
  'p2042268136691630118_media_1795266573291_lmzm7u.jpg',
  'p2042268136691630118_media_1795266573291_nhgclt.jpg',
  'p2042268136691630118_media_1795266573291_wpybd3.jpg',
  'p2042268146539889135_media_1795266573331_3490q2.jpg',
  'p2042268146539889135_media_1795266573331_bt2qlc.jpg',
  'p2042268146539889135_media_1795266573331_fj61sj.jpg',
  'p2042268146539889135_media_1795266573331_rx3sh6.jpg',
  'p2063580332276990202_media_1795266708358_bk6xxm.jpg',
  'p2063580332276990202_media_1795266708358_r7uamp.jpg',
  'p2063580332276990202_media_1795266708358_s4i71t.jpg',
  'p2063580332276990202_media_1795266708358_z29mk5.jpg',
  'p2103879447929913366_media_1795266602992_12h1bb.jpg',
  'p2103879447929913366_media_1795266602992_ay7zmq.jpg',
  'p2103879447929913366_media_1795266602992_s9cv7b.jpg',
  'p2103879447929913366_media_1795266602992_yyd20v.jpg',
];

/// 縦 9 枚（scr001-009・portrait_band_extraction_test.dart と同一 GT）。
final List<String> _scrIds = <String>[
  'scr001',
  'scr002',
  'scr003',
  'scr004',
  'scr005',
  'scr006',
  'scr007',
  'scr008',
  'scr009',
];

final Map<String, String> _scrTimestamps = <String, String>{
  'scr001': '124336',
  'scr002': '124345',
  'scr003': '124356',
  'scr004': '124401',
  'scr005': '124405',
  'scr006': '124410',
  'scr007': '124414',
  'scr008': '124418',
  'scr009': '124421',
};

String _scrPath(String id) =>
    '$_deviceDir/Screenshot_20261122-${_scrTimestamps[id] ?? ''}.png';

/// 検出率の設計下限（横 30 枚・WHY はコメントの設計節参照）。
const Map<String, int> _landscapeFloors = <String, int>{
  'frameRight': 28,
  'gaugeHeader': 25,
  'settingsNormal': 25,
  'difficultyEx': 24,
};

/// 縦帯の暫定下限（§1.4 は緩和閾値 0.495 実測のため 0.55 実行時では余裕を
/// 取る。QA-Docs 第 4 回計測で KPI 確定後に更新する）。
const Map<String, int> _portraitFloors = <String, int>{
  'gaugeHeader': 6,
  'settingsNormal': 6,
};

bool _prepared(List<String> paths) => paths.every((p) => File(p).existsSync());

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ST-3.5: 横 30 枚アンカー検出（設計下限ゲート・コスト計測）', (tester) async {
    final paths = _landscapeFiles.map((f) => '$_deviceDir/$f').toList();
    if (!_prepared(paths)) {
      // ignore: avoid_print
      print('[SKIP] $_deviceDir に横 30 枚がありません（push を実施してから再実行）');
      return;
    }
    final pack = await AnchorPack.loadFromAssets('hc_v1');
    expect(pack, isNotNull, reason: 'asset パックがデバイスで読めない');

    final hits = <String, int>{};
    final scores = <String, List<double>>{};
    final costs = <int>[];
    for (final path in paths) {
      final sw = Stopwatch()..start();
      final registration = AnchorRegistration.detect(
        File(path).readAsBytesSync(),
        pack!,
      );
      sw.stop();
      costs.add(sw.elapsedMilliseconds);
      for (final id in _landscapeFloors.keys) {
        final hit = registration?.hitOf(id);
        if (hit != null) {
          hits[id] = (hits[id] ?? 0) + 1;
          (scores[id] ??= <double>[]).add(hit.score);
        }
      }
      // ignore: avoid_print
      print(
        '[ANCHOR] ${_landscapeFiles[paths.indexOf(path)]} '
        'hits=${registration?.hits.keys.join(',')} '
        '${sw.elapsedMilliseconds}ms',
      );
    }
    _reportAndAssert(hits, scores, costs, _landscapeFloors, 30);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('ST-3.5: 縦帯 9 枚アンカー検出（クロスアスペクト・暫定下限）', (tester) async {
    final paths = _scrIds.map(_scrPath).toList();
    if (!_prepared(paths)) {
      // ignore: avoid_print
      print('[SKIP] $_deviceDir に 9 枚 PNG がありません（push を実施してから再実行）');
      return;
    }
    final pack = await AnchorPack.loadFromAssets('hc_v1');
    expect(pack, isNotNull, reason: 'asset パックがデバイスで読めない');

    final preprocessor = InputPreprocessor();
    final hits = <String, int>{};
    final scores = <String, List<double>>{};
    final costs = <int>[];
    final failures = <String>[];
    for (final id in _scrIds) {
      final result = await preprocessor.preprocess(
        File(_scrPath(id)).readAsBytesSync(),
      );
      if (result.embeddedRect == null || !result.aspectRatioValid) {
        failures.add('$id: 帯抽出失敗（タスク A 回帰）');
        continue;
      }
      final sw = Stopwatch()..start();
      final registration = AnchorRegistration.detect(
        result.preprocessedBytes,
        pack!,
      );
      sw.stop();
      costs.add(sw.elapsedMilliseconds);
      for (final id2 in _portraitFloors.keys) {
        final hit = registration?.hitOf(id2);
        if (hit != null) {
          hits[id2] = (hits[id2] ?? 0) + 1;
          (scores[id2] ??= <double>[]).add(hit.score);
        }
      }
      // WHY difficultyEx は縦帯に実測が無いため観測のみ（設計 §1.4 は
      // GAUGE/NORMAL テンプレの 18/18 のみ）。
      final ex = registration?.hitOf('difficultyEx');
      // ignore: avoid_print
      print(
        '[ANCHOR-P] $id '
        'gauge=${registration?.hitOf('gaugeHeader')?.score.toStringAsFixed(3)} '
        'normal=${registration?.hitOf('settingsNormal')?.score.toStringAsFixed(3)} '
        'ex=${ex?.score.toStringAsFixed(3)} ${sw.elapsedMilliseconds}ms',
      );
    }
    expect(failures, isEmpty, reason: failures.join(' | '));
    _reportAndAssert(hits, scores, costs, _portraitFloors, 9);
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// ヒット率レポート出力＋設計下限アサート＋コスト平均出力。
void _reportAndAssert(
  Map<String, int> hits,
  Map<String, List<double>> scores,
  List<int> costs,
  Map<String, int> floors,
  int total,
) {
  final failures = <String>[];
  for (final entry in floors.entries) {
    final count = hits[entry.key] ?? 0;
    final avg =
        (scores[entry.key] ?? const <double>[]).fold<double>(
          0,
          (a, b) => a + b,
        ) /
        (scores[entry.key]?.length ?? 1);
    // ignore: avoid_print
    print(
      '[RATE] ${entry.key}: $count/$total avgScore='
      '${(scores[entry.key] ?? const <double>[]).isEmpty ? '-' : avg.toStringAsFixed(3)} '
      '(floor ${entry.value})',
    );
    if (count < entry.value) {
      failures.add('${entry.key}: $count/$total < floor ${entry.value}');
    }
  }
  final avgCost = costs.fold<int>(0, (a, b) => a + b) / costs.length;
  // ignore: avoid_print
  print(
    '[COST] detect avg=${avgCost.toStringAsFixed(1)}ms '
    'max=${costs.reduce((a, b) => a > b ? a : b)}ms n=${costs.length}',
  );
  // WHY 500ms サニティ: 設計 §1.5 の ≤150ms はパイプライン全体（QA-Docs
  // 第 4 回計測対象）であり、detect 単体の異常肥大のみここで阻止する。
  expect(avgCost, lessThan(500), reason: 'detect コスト異常肥大');
  expect(failures, isEmpty, reason: failures.join(' | '));
}
