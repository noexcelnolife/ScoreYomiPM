// 記録詳細画面のコピー可能テキスト化（01a20b17）のテスト。
//
// ユーザー指示 2026-11-24「記録詳細画面の曲名、スコアや判定数の数字を
// コピー可能なテキストにできますか」への対応。リードがユーザーへ確認し、
// **対象 8 値 = 7 行**で確定した:
//   曲名・スコア・判定数（COOL/GREAT/GOOD/BAD）・MAX COMBO・難易度・レベル・機種
// 対象外（従来どおり）: 日時・メダル・状態・記録元（いずれも確定スコープ外）。
//
// 検証対象:
// (a) コピー対象 7 行（8 値）が SelectableText で描画される
// (b) 非対象（日時・メダル・状態・記録元）は SelectableText にならない
// (c) 難易度の着色（2a11d80）が SelectableText 化後も維持される
// (d) null 値は従来どおり「—」「（曲名未入力）」で SelectableText 化しない

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/difficulty_color.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';
// メダル行が対象外であることを実値で検証するため ClearMedalCategory を使う
// （play_record.dart は import のみで re-export していないため直接参照する）。
import 'package:scoreyomipm/validation/validation_issue.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// 値が揃った確定レコード（難易度・レベル・機種・メダルも含む）。
///
/// メダルは非対象行であることを「実際に値が入った状態」で検証するため、
/// null（"—"）ではなく実ラベルを出る値にしてある。
PlayRecord _fullRecord(File image) =>
    PlayRecordDraft(
      songName: 'テスト曲',
      score: 98108,
      cool: 1000,
      great: 500,
      good: 100,
      bad: 10,
      maxCombo: 1234,
      level: 45,
      difficulty: GameDifficulty.ex,
      machine: 'H☆C!!',
      clearMedal: ClearMedalCategory.clear,
      status: PlayRecordStatus.confirmed,
      source: PlayRecordSource.playshare,
    ).toPlayRecord(
      id: 'r-1',
      resultImagePath: image.path,
      playedAt: DateTime(2026, 11, 22, 12, 34),
    );

/// 曲名・数値がすべて未入力の未確定レコード。
PlayRecord _blankRecord(File image) =>
    PlayRecordDraft(
      songName: null,
      status: PlayRecordStatus.pending,
      source: PlayRecordSource.playshare,
    ).toPlayRecord(
      id: 'r-2',
      resultImagePath: image.path,
      playedAt: DateTime(2026, 11, 22, 9),
    );

/// 詳細画面を単独で開く（行の描画だけを見るため route 経由は不要）。
Future<void> _pumpDetail(WidgetTester tester, PlayRecord record) async {
  final FakePlayRecordRepository repository = FakePlayRecordRepository();
  repository.store[record.id] = record;
  await tester.pumpWidget(
    MaterialApp(
      home: PlayRecordDetailScreen(
        playRecordRepository: repository,
        ocrEngine: FakeOcrEngine(),
        recordId: record.id,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('コピー対象 8 値（7 行）が SelectableText で描画される', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    await _pumpDetail(tester, _fullRecord(image));

    const Map<String, String> targets = <String, String>{
      '難易度': 'EX',
      'レベル': 'Lv45',
      '曲名': 'テスト曲',
      'スコア': '98,108',
      '判定内訳': 'COOL 1000 / GREAT 500 / GOOD 100 / BAD 10',
      'MAX COMBO': '1234',
      '機種': 'H☆C!!',
    };
    for (final MapEntry<String, String> entry in targets.entries) {
      expect(
        find.widgetWithText(SelectableText, entry.value),
        findsOneWidget,
        reason: '${entry.key}（${entry.value}）はコピー可能であること',
      );
    }
  });

  testWidgets('コピー対象は 7 行のみで、日時・メダル・状態・記録元は対象外', (WidgetTester tester) async {
    final File image = createTestImageFile();
    await _pumpDetail(tester, _fullRecord(image));

    // WHY: 対象を確定スコープ（7 行 / 8 値）に限定する。日時・メダル・状態・
    // 記録元はユーザーが求めた「他アプリへ貼る値」ではなく、選択可能にすると
    // 長押しで意図せず選択メニューが出て操作の邪魔になる。総数固定で
    // 「意図しない行まで選択可能になった」退行を検出する。
    //
    // 数え方の注意: リード指定の「8 値」は判定数（COOL/GREAT/GOOD/BAD）を
    // 個別の値として数えた表現。画面上は 4 値が「判定内訳」1 行に同居する
    // （既存レイアウト・既存テストの文字列を変えないため行は分割しない）ので、
    // SelectableText ウィジェットは **7 個**になる。1 行をコピーすると 4 値が
    // まとめて取れる（分割しない方針はリード確定済み）。
    expect(find.byType(SelectableText), findsNWidgets(7));

    for (final String nonTarget in <String>[
      '2026/11/22 12:34', // 日時
      'クリア', // メダル（通常の Text 行）
      '確定', // 状態（Chip）
      'プレーシェア', // 記録元
    ]) {
      // 先に行が実在することを確かめる。これが無いと「行が消えた」場合でも
      // SelectableText 不在のアサーションが通ってしまい、検出力が落ちる。
      expect(
        find.text(nonTarget),
        findsOneWidget,
        reason: '$nonTarget の行自体は表示されている前提で検証する',
      );
      expect(
        find.widgetWithText(SelectableText, nonTarget),
        findsNothing,
        reason: '$nonTarget はコピー対象外（SelectableText にしない）',
      );
    }
  });

  testWidgets('難易度は SelectableText 化しても着色が維持される', (WidgetTester tester) async {
    final File image = createTestImageFile();
    await _pumpDetail(tester, _fullRecord(image));

    final SelectableText difficulty = tester.widget<SelectableText>(
      find.widgetWithText(SelectableText, 'EX'),
    );
    expect(
      difficulty.style?.color,
      difficultyColor(GameDifficulty.ex, brightness: Brightness.light),
      reason: '難易度の着色（2a11d80）を SelectableText 化で失わない',
    );
  });

  testWidgets('null 値は SelectableText 化せず「—」「（曲名未入力）」のまま', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    await _pumpDetail(tester, _blankRecord(image));

    expect(
      find.widgetWithText(SelectableText, '（曲名未入力）'),
      findsNothing,
      reason: '曲名未入力のプレースホルダはコピー対象にしない',
    );
    expect(
      find.widgetWithText(SelectableText, '—'),
      findsNothing,
      reason: '「—」プレースホルダはコピー対象にしない',
    );
    // 判定内訳の行は値が揃う前から常に選択可能（個別値が「—」でも行としては
    // コピー可能にしておく）。よって SelectableText は判定内訳の 1 つのみ。
    expect(
      find.byType(SelectableText),
      findsOneWidget,
      reason: '未入力レコードでは判定内訳行だけが SelectableText',
    );
    // 既存の null 表示規約（数値 5 件 + 難易度/メダル/機種）が保たれていること。
    expect(find.text('—'), findsNWidgets(6));
  });
}
