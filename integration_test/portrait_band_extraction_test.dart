// ST-5 フェーズ2-A: portraitWithEmbedded 埋め込み帯抽出の実画像検証（9 枚）
//
// 1. scr001-009 全 9 枚が portraitWithEmbedded と分類されること（回帰ガード）
// 2. 前処理で行分散最長 run による全幅帯抽出が成功すること:
//    - aspectValid=true（帯アスペクト ≒1.5 が既存検証を通過）
//    - embeddedRect が全幅（left=0・right=元幅）で帯高さ ≒720px（実測 GT）
//    - クロップ後が横長ストリップ（レイアウト正規化・横 spec 群が効く空間）
//
// GT: 9 枚実測（ホスト側行分散プローブ・/data/local/tmp/poc_scr/ と同一 PNG）
// で帯は全枚 y 864-1583（高さ 720px・全幅レターボックス）。旧実装（x バウンダ
// リ bounding box）では rect≈(4,53,1075,2369)・aspectValid=false のため、
// 本テストは旧実装で RED になる。
//
// 制約: 9 枚 PNG（/data/local/tmp/poc_scr/・testimage push 分）は変更禁止。
//
// 実行: flutter test integration_test/portrait_band_extraction_test.dart -d emulator-5554
// （QA-Docs 効果検証計測と同時実行しない: adb 競合で計測が乱れる）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'package:scoreyomipm/ocr/input_preprocessing.dart';

const String _playshareDir = '/data/local/tmp/pm_test/testimage';

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
    '$_playshareDir/Screenshot_20261122-${_scrTimestamps[id] ?? ''}.png';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final dir = Directory(_playshareDir);
  final prepared =
      dir.existsSync() &&
      _scrIds.every((id) => File(_scrPath(id)).existsSync());

  testWidgets('portraitWithEmbedded 埋め込み帯抽出（9 枚実画像 GT・行分散最長 run）', (
    tester,
  ) async {
    if (!prepared) {
      // 端末未準備（push 未実施）時はスキップではなく明示レポートで停止扱いにしない
      // （既存 realdata ハーネスと同一の方針）。
      // ignore: avoid_print
      print('[SKIP] $_playshareDir に 9 枚 PNG がありません（push を実施してから再実行）');
      return;
    }

    var okCount = 0;
    final failures = <String>[];

    for (final id in _scrIds) {
      final file = File(_scrPath(id));
      final original = await file.readAsBytes();
      final decodedOriginal = img.decodePng(original);
      if (decodedOriginal == null) {
        failures.add('$id: 元画像デコード失敗');
        continue;
      }
      final origW = decodedOriginal.width;
      final origH = decodedOriginal.height;

      final preprocessor = InputPreprocessor();
      final classified = preprocessor.classify(file);
      final result = await preprocessor.preprocess(file);

      final problems = <String>[];
      if (classified != InputImageClass.portraitWithEmbedded) {
        problems.add('分類=$classified（期待 portraitWithEmbedded）');
      }
      if (result.embeddedRect == null) {
        problems.add('embeddedRect=null（帯検出失敗）');
      } else {
        final rect = result.embeddedRect!;
        final bandHeight = rect.height;
        // GT ウィンドウ: 実測帯 top 864・高さ 720（9 枚全共通）に対し
        // ±64px の許容。旧実装（top≈53・height≈2316）は大きく外れる。
        if (rect.top < 800 || rect.top > 930) {
          problems.add('帯top=${rect.top}（GT ウィンドウ 800-930）');
        }
        if (bandHeight < 660 || bandHeight > 790) {
          problems.add('帯高さ=$bandHeight（GT ウィンドウ 660-790）');
        }
        if (rect.left != 0 || rect.right != origW) {
          problems.add(
            '全幅でない: left=${rect.left} right=${rect.right}（幅 $origW）',
          );
        }
      }
      if (!result.aspectRatioValid) {
        problems.add('aspectValid=false（帯アスペクト ≒1.5 不成立）');
      }

      final decodedCrop = img.decodePng(
        await result.preprocessedFile.readAsBytes(),
      );
      if (decodedCrop == null) {
        problems.add('クロップ画像デコード失敗');
      } else {
        if (decodedCrop.width <= decodedCrop.height) {
          problems.add(
            'クロップ後が横長でない: ${decodedCrop.width}x${decodedCrop.height}',
          );
        }
        if (decodedCrop.width != origW) {
          problems.add('クロップ幅不一致: ${decodedCrop.width}（元幅 $origW）');
        }
      }

      if (problems.isEmpty) {
        okCount++;
        // ignore: avoid_print
        print(
          '[OK] $id (${origW}x$origH) -> 帯top=${result.embeddedRect!.top} '
          '高さ=${result.embeddedRect!.height} '
          'クロップ=${decodedCrop!.width}x${decodedCrop.height}（横長正規化）',
        );
      } else {
        failures.add('$id: ${problems.join(' / ')}');
        // ignore: avoid_print
        print('[NG] $id (${origW}x$origH): ${problems.join(' / ')}');
      }
    }

    // ignore: avoid_print
    print('\n------------------------------------------------------------');
    // ignore: avoid_print
    print('埋め込み帯抽出  $okCount/9 枚  成功（aspectValid・全幅・横長正規化）');
    // ignore: avoid_print
    print('------------------------------------------------------------');

    expect(failures, isEmpty, reason: '帯抽出失敗: ${failures.join(' | ')}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
