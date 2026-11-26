// 入力画面・詳細画面の項目表示順（01a20b34）のテスト。
//
// ユーザー指示（2026-11-24）: 記録詳細画面と記録入力画面の項目順序を
// 「クリアメダル → 難易度 → レベル → 曲名 → スコア → COOL → GREAT → GOOD
// → BAD → MAX COMBO → 機種」に揃える（リザルト画面の並びに合わせる）。
//
// 契約:
// - 並び順のみの変更。key・ラベル・保存パス・データ層・バリデーションは不変。
// - 詳細画面は上記 11 項目を同じ順に並べる。11 項目に含まれない
//   日時（ヘッダ情報）を先頭、状態・記録元（メタ情報）を末尾に置く。
// - 難易度色・null 表示（「—」「未指定」）・フォームロジックは不変。
//
// WHY(red-first): 並び順の契約をテストで先に固定し、実装前は赤になることを
// 確認してから並べ替える（赤のままコミットしないよう、実装と同じコミットに
// 同梱する）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// 各ラベルの描画位置（上端 y）を表示順に返す。
List<double> _tops(WidgetTester tester, List<String> labels) {
  return <double>[
    for (final String label in labels) tester.getTopLeft(find.text(label)).dy,
  ];
}

/// 上が狭く下が広い = 指定順に縦に並んでいることを検証する。
void _expectVerticalOrder(WidgetTester tester, List<String> labels) {
  final List<double> tops = _tops(tester, labels);
  for (int i = 1; i < tops.length; i++) {
    expect(
      tops[i],
      greaterThan(tops[i - 1]),
      reason:
          '「${labels[i]}」が「${labels[i - 1]}」より上に描画されている'
          '（y: ${tops[i - 1]} → ${tops[i]}）',
    );
  }
}

PlayRecord _record(File image, {required String id}) {
  return PlayRecordDraft(
    songName: '曲A',
    score: 98108,
    level: 42,
    difficulty: GameDifficulty.ex,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(
    id: id,
    resultImagePath: image.path,
    playedAt: DateTime(2026, 11, 25, 10),
  );
}

void main() {
  testWidgets('入力画面の項目順は メダル→難易度→レベル→曲名→スコア→COOL→GREAT→GOOD→BAD→MAX COMBO→機種', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              OcrResultScreen.route(
                playRecordRepository: repository,
                appBarTitle: 'スコア手入力',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    _expectVerticalOrder(tester, <String>[
      'クリアメダル',
      '難易度',
      'レベル',
      '曲名',
      'スコア',
      'COOL',
      'GREAT',
      'GOOD',
      'BAD',
      'MAX COMBO',
      '機種',
    ]);
  });

  testWidgets('詳細画面の項目順は 日時→メダル→難易度→レベル→曲名→スコア→判定内訳→MAX COMBO→機種→状態→記録元', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['p-1'] = _record(image, id: 'p-1');
    await tester.pumpWidget(
      MaterialApp(
        home: PlayRecordDetailScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
          recordId: 'p-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    _expectVerticalOrder(tester, <String>[
      '日時',
      'メダル',
      '難易度',
      'レベル',
      '曲名',
      'スコア',
      '判定内訳',
      'MAX COMBO',
      '機種',
      '状態',
      '記録元',
    ]);
  });
}
