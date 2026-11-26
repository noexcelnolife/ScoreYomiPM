// PlayRecordsScreen（FR-10 記録一覧）のテスト。
//
// 検証対象:
// (a) 全件表示（未確定＋確定）・未確定グループが先頭・各グループは新しい順
// (b) グループ見出し（未確定 N 件 / 確定 N 件）は 0 件のグループを表示しない
//     （設計判断: 情報量 0 の見出しは視認性を下げるため非表示・テストで固定）
// (c) 行タップで記録詳細（FR-11）へ遷移する
// (d) 空状態（記録 0 件）
// (e) 一覧サムネイルは InteractiveViewer 対象外（v2 UX #14・ユーザー裁定の固定）
// (f) v4 案3 v2: 統計カード 3 値 / ソート切替 / 自己ベストバッジ（キーは
//     (曲名, 難易度)）/ 空時の非表示 / 切替後の詳細遷移非回帰（設計確認書 §4-7〜11）
//     + 副題の難易度表示（v2 改訂・FR-10 準拠: 「HYPER Lv42」形式）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/play_records_screen.dart';
import 'package:scoreyomipm/validation/validation_issue.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// ドラフトからテスト用レコードを組み立てるヘルパー。
PlayRecord _record(
  File image, {
  required String id,
  required DateTime playedAt,
  String? songName,
  int? score,
  int? level,
  GameDifficulty? difficulty,
  ClearMedalCategory? medal,
  PlayRecordStatus status = PlayRecordStatus.pending,
}) {
  return PlayRecordDraft(
    songName: songName,
    score: score,
    level: level,
    difficulty: difficulty,
    clearMedal: medal,
    status: status,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(id: id, resultImagePath: image.path, playedAt: playedAt);
}

/// v4 案3: 統計カード・ソート切替・ベストバッジを載せた一覧を描画する。
Future<void> _pumpList(WidgetTester tester, FakePlayRecordRepository r) async {
  await tester.pumpWidget(
    _wrap(
      PlayRecordsScreen(playRecordRepository: r, ocrEngine: FakeOcrEngine()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('全件を未確定→確定の順に表示し、各グループは新しい順', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['p-old'] = _record(
        image,
        id: 'p-old',
        playedAt: DateTime(2026, 11, 20),
        songName: '古い未確定',
      )
      ..store['p-new'] = _record(
        image,
        id: 'p-new',
        playedAt: DateTime(2026, 11, 21),
        songName: '新しい未確定',
      )
      ..store['c-1'] = _record(
        image,
        id: 'c-1',
        playedAt: DateTime(2026, 11, 22),
        songName: '確定済み',
        status: PlayRecordStatus.confirmed,
      );

    await tester.pumpWidget(
      _wrap(
        PlayRecordsScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未確定 2 件'), findsOneWidget);
    expect(find.text('確定 1 件'), findsOneWidget);
    expect(find.text('古い未確定'), findsOneWidget);
    expect(find.text('新しい未確定'), findsOneWidget);
    expect(find.text('確定済み'), findsOneWidget);

    // 未確定グループ内で新しい順。
    expect(
      tester.getTopLeft(find.text('新しい未確定')).dy,
      lessThan(tester.getTopLeft(find.text('古い未確定')).dy),
    );
    // 未確定グループが確定グループより先。
    expect(
      tester.getTopLeft(find.text('古い未確定')).dy,
      lessThan(tester.getTopLeft(find.text('確定済み')).dy),
    );
  });

  testWidgets('0 件のグループの見出しは表示しない', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-1'] = _record(
        image,
        id: 'c-1',
        playedAt: DateTime(2026, 11, 22),
        songName: '確定済み',
        status: PlayRecordStatus.confirmed,
      );

    await tester.pumpWidget(
      _wrap(
        PlayRecordsScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未確定 0 件'), findsNothing);
    expect(find.text('確定 1 件'), findsOneWidget);
  });

  testWidgets('行タップで記録詳細へ遷移する', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['p-1'] = _record(
        image,
        id: 'p-1',
        playedAt: DateTime(2026, 11, 21),
        songName: '詳細テスト',
      );

    await tester.pumpWidget(
      _wrap(
        PlayRecordsScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('record-row-p-1')));
    await tester.pumpAndSettle();

    expect(find.text('記録詳細'), findsOneWidget);
    expect(find.text('詳細テスト'), findsOneWidget);
  });

  testWidgets('記録 0 件では空状態を表示する', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        PlayRecordsScreen(
          playRecordRepository: FakePlayRecordRepository(),
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('記録はありません'), findsOneWidget);
  });

  testWidgets('一覧のサムネイルには InteractiveViewer を導入しない（v2 UX #14 一覧対象外の固定）', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-1'] = _record(
        image,
        id: 'c-1',
        playedAt: DateTime(2026, 11, 22),
        songName: '確定済み',
        status: PlayRecordStatus.confirmed,
      );

    await tester.pumpWidget(
      _wrap(
        PlayRecordsScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // WHY: ユーザー裁定「一覧画面では不要」（2026-11-23）。サムネイルは現行の
    // 56px 固定表示を維持する。将来の改修で拡縮を一覧にまで広げる回帰を防ぐ
    // ため、対象外であることをテストで固定する。
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  // ---------------------------------------------------------------
  // v4 案3 v2（docs/v4_list_best_stats_design_2026-11-23.md §4-7〜11・
  // グループキー (曲名, 難易度) へ改訂・副題難易度表示追加）
  // WHY(red-first・案3 v2 運用): 保全 WIP（レベルキー版）の上へ v2 仕様の
  // 期待値へ書き直してから実行し、UI 未実装メソッド（統計カード等）と
  // レベルキー実装に対する赤を実測している。UI 実装完成まではロード失敗で
  // 実行不能なため、赤/緑 2 コミット割りは中間状態の analyze を壊す
  //（0d29308・c9d1e61 前例で実装と同コミット化。逸脱記録は
  // play_record_stats_test.dart ヘッダ参照）。
  // ---------------------------------------------------------------

  testWidgets('統計カードの 3 値が seed データと一致する', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c1'] = _record(
        image,
        id: 'c1',
        playedAt: DateTime(2026, 11, 22),
        songName: 'ソングA',
        score: 100000,
        level: 5,
        medal: ClearMedalCategory.fullComboFamily,
        status: PlayRecordStatus.confirmed,
      )
      ..store['c2'] = _record(
        image,
        id: 'c2',
        playedAt: DateTime(2026, 11, 21),
        songName: 'ソングA',
        score: 90000,
        level: 5,
        medal: ClearMedalCategory.clear,
        status: PlayRecordStatus.confirmed,
      )
      ..store['c3'] = _record(
        image,
        id: 'c3',
        playedAt: DateTime(2026, 11, 20),
        songName: 'ソングB',
        score: 80000,
        level: 4,
        status: PlayRecordStatus.confirmed,
      )
      // pending でもメダル手入力済みならフルコンボ母集団に入る（設計確認書 §1）。
      ..store['p1'] = _record(
        image,
        id: 'p1',
        playedAt: DateTime(2026, 11, 19),
        medal: ClearMedalCategory.fullComboFamily,
      );

    await _pumpList(tester, repository);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('records-stats-total')),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('records-stats-songs')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('records-stats-fullcombo')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    // WHY: 「フルコンボ」は行のサブタイトルにも出るため、ラベル照合はセル内
    // descendant に閉じさせる（上記数値アサートと同じ理由）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('records-stats-fullcombo')),
        matching: find.text('フルコンボ'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('既定は日付順・スコアの高い順切替後は最高スコアが先頭', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['new-null'] = _record(
        image,
        id: 'new-null',
        playedAt: DateTime(2026, 11, 25),
        songName: '新スコアなし',
        level: 5,
        status: PlayRecordStatus.confirmed,
      )
      ..store['mid-hi'] = _record(
        image,
        id: 'mid-hi',
        playedAt: DateTime(2026, 11, 24),
        songName: '中最高得点',
        score: 99000,
        level: 5,
        difficulty: GameDifficulty.hyper,
        status: PlayRecordStatus.confirmed,
      )
      ..store['old-mid'] = _record(
        image,
        id: 'old-mid',
        playedAt: DateTime(2026, 11, 23),
        songName: '古中得点',
        score: 95000,
        level: 5,
        status: PlayRecordStatus.confirmed,
      );

    await _pumpList(tester, repository);

    // 既定（実施日の新しい順）: 新 → 中 → 古。
    expect(
      tester.getTopLeft(find.text('新スコアなし')).dy,
      lessThan(tester.getTopLeft(find.text('中最高得点')).dy),
    );
    expect(
      tester.getTopLeft(find.text('中最高得点')).dy,
      lessThan(tester.getTopLeft(find.text('古中得点')).dy),
    );

    await tester.tap(find.text('スコアの高い順'));
    await tester.pumpAndSettle();

    // スコア順: 99000 → 95000 → null 末尾（設計確認書 §2）。
    expect(
      tester.getTopLeft(find.text('中最高得点')).dy,
      lessThan(tester.getTopLeft(find.text('古中得点')).dy),
    );
    expect(
      tester.getTopLeft(find.text('古中得点')).dy,
      lessThan(tester.getTopLeft(find.text('新スコアなし')).dy),
    );

    // v2 改訂: 副題に難易度ラベル+レベルを表示する（設計確認書 §2「HYPER Lv42」
    // 形式・null 行はラベルなしで従来どおり「Lv のみ」）。
    expect(find.textContaining('HYPER Lv5'), findsOneWidget);
  });

  testWidgets('自己ベストバッジはベスト行のみ表示される', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['best-a'] = _record(
        image,
        id: 'best-a',
        playedAt: DateTime(2026, 11, 22),
        songName: 'ベス曲',
        score: 100000,
        level: 42,
        difficulty: GameDifficulty.hyper,
        status: PlayRecordStatus.confirmed,
      )
      ..store['under-a'] = _record(
        image,
        id: 'under-a',
        playedAt: DateTime(2026, 11, 21),
        songName: 'ベス曲',
        score: 90000,
        level: 42,
        difficulty: GameDifficulty.hyper,
        status: PlayRecordStatus.confirmed,
      )
      ..store['best-a-ex'] = _record(
        image,
        id: 'best-a-ex',
        playedAt: DateTime(2026, 11, 20),
        songName: 'ベス曲',
        score: 70000,
        level: 45,
        difficulty: GameDifficulty.ex,
        status: PlayRecordStatus.confirmed,
      )
      ..store['best-b'] = _record(
        image,
        id: 'best-b',
        playedAt: DateTime(2026, 11, 19),
        songName: '別曲',
        score: 50000,
        level: 5,
        status: PlayRecordStatus.confirmed,
      );

    await _pumpList(tester, repository);

    // v2 改訂（キー (曲名, 難易度)）: ベス曲/HYPER の最高 best-a、同曲 EX は
    // 別グループなのでスコアが低くても各自ベスト、別曲（難易度 null）で 3 行。
    expect(
      find.byKey(const ValueKey<String>('record-best-badge')),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('record-row-best-a')),
        matching: find.byKey(const ValueKey<String>('record-best-badge')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('record-row-best-a-ex')),
        matching: find.byKey(const ValueKey<String>('record-best-badge')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('record-row-under-a')),
        matching: find.byKey(const ValueKey<String>('record-best-badge')),
      ),
      findsNothing,
    );
  });

  testWidgets('空リポジトリでは統計カード・ソート切替を非表示にする', (WidgetTester tester) async {
    await _pumpList(tester, FakePlayRecordRepository());

    expect(find.text('記録はありません'), findsOneWidget);
    // WHY: 0 件の統計は情報量 0（設計確認書 §2・空時は既存の空状態のみ）。
    expect(
      find.byKey(const ValueKey<String>('records-stats-total')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('records-sort-segment')),
      findsNothing,
    );
  });

  testWidgets('ソート切替後も行タップで詳細遷移する（非回帰）', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['r-old'] = _record(
        image,
        id: 'r-old',
        playedAt: DateTime(2026, 11, 20),
        songName: '古い高得点',
        score: 99000,
        level: 5,
        status: PlayRecordStatus.confirmed,
      )
      ..store['r-new'] = _record(
        image,
        id: 'r-new',
        playedAt: DateTime(2026, 11, 21),
        songName: '新しい低得点',
        score: 100,
        level: 5,
        status: PlayRecordStatus.confirmed,
      );

    await _pumpList(tester, repository);
    await tester.tap(find.text('スコアの高い順'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('record-row-r-old')));
    await tester.pumpAndSettle();

    expect(find.text('記録詳細'), findsOneWidget);
    expect(find.text('古い高得点'), findsOneWidget);
  });
}
