// メモ機能（記録のメモ欄・テンプレートの選択/管理）のウィジェットテスト。
//
// 検証対象:
// (a) 詳細画面: メモがあるときだけ「メモ」行を出す（長文も SELECTABLE）
// (b) 入力画面: メモ欄が常に出る。テンプレート供給元が無ければボタンを出さない
// (c) 入力画面: テンプレートを選ぶとメモ欄へ差し込まれる（既存文とは改行区切り）
// (d) シート: 空状態の案内 / 追加 / 削除
// (e) シート: 選択した本文が呼び出し元へ返る
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/data/memo_template_repository.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/memo_template_sheet.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';

import 'fake_memo_template_repository.dart';
import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

final ThemeData _testTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
);

Widget _wrap(Widget child) => MaterialApp(theme: _testTheme, home: child);

/// シート本体を単体で pump するためのラッパー。
///
/// WHY Scaffold を挟むか: [MemoTemplateSheet] はモーダルシート内での利用を
/// 前提にしており、ListTile の要求する Material はシート側が供給する。
/// 単体で pump するときは Scaffold でその前提を満たす。
Widget _wrapSheet(Widget child) => _wrap(Scaffold(body: child));

/// メモ付きの確定レコードを作る。
PlayRecord _recordWithMemo(File image, {String? memo}) {
  return PlayRecordDraft(
    songName: 'テスト曲',
    score: 98000,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
    memo: memo,
  ).toPlayRecord(
    id: 'r-memo',
    resultImagePath: image.path,
    playedAt: DateTime(2026, 11, 26, 10),
  );
}

/// 手入力モード（既存レコードの修正）で開くフォーム。
///
/// WHY 既存レコード経由か: フィールドセクションは extractionResult か
/// existingRecordId のどちらかがあるときだけ出る。手入力モードは後者で、
/// メモ欄もそこに含まれる。
Widget _manualForm({
  required FakePlayRecordRepository repository,
  MemoTemplateRepository? memoTemplateRepository,
}) {
  return OcrResultScreen(
    imageFile: null,
    playRecordRepository: repository,
    existingRecordId: 'r-memo',
    memoTemplateRepository: memoTemplateRepository,
  );
}

void main() {
  group('詳細画面のメモ表示', () {
    testWidgets('メモがあると「メモ」行に本文が出る', (WidgetTester tester) async {
      final File image = createTestImageFile();
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(image, memo: '精度重視\nBP 更新');

      await tester.pumpWidget(
        _wrap(
          PlayRecordDetailScreen(
            playRecordRepository: repository,
            ocrEngine: FakeOcrEngine(),
            recordId: 'r-memo',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('メモ'), findsOneWidget);
      expect(find.text('精度重視\nBP 更新'), findsOneWidget);
    });

    testWidgets('メモが無ければ「メモ」行を出さない', (WidgetTester tester) async {
      final File image = createTestImageFile();
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(image);

      await tester.pumpWidget(
        _wrap(
          PlayRecordDetailScreen(
            playRecordRepository: repository,
            ocrEngine: FakeOcrEngine(),
            recordId: 'r-memo',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('メモ'), findsNothing);
    });
  });

  group('入力画面のメモ欄', () {
    testWidgets('メモ欄は供給元が無くても表示される', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(createTestImageFile());

      await tester.pumpWidget(_wrap(_manualForm(repository: repository)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('memo-field')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('memo-template-button')),
        findsNothing,
        reason: 'テンプレート供給元が無いときはボタンを出さない',
      );
    });

    testWidgets('供給元があればテンプレートボタンが出る', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(createTestImageFile());

      await tester.pumpWidget(
        _wrap(
          _manualForm(
            repository: repository,
            memoTemplateRepository: FakeMemoTemplateRepository(<MemoTemplate>[
              const MemoTemplate(id: 't1', title: '精度重視', body: '精度重視でプレイ'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('memo-template-button')),
        findsOneWidget,
      );
    });

    testWidgets('選んだテンプレートが空のメモ欄に差し込まれる', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(createTestImageFile());

      await tester.pumpWidget(
        _wrap(
          _manualForm(
            repository: repository,
            memoTemplateRepository: FakeMemoTemplateRepository(<MemoTemplate>[
              const MemoTemplate(id: 't1', title: '精度重視', body: '精度重視でプレイ'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder templateButton = find.byKey(
        const ValueKey<String>('memo-template-button'),
      );
      // フォームは縦に長く、メモ欄は画面外になりやすい。タップ前に見える位置へ。
      await tester.ensureVisible(templateButton);
      await tester.pumpAndSettle();
      await tester.tap(templateButton);
      await tester.pumpAndSettle();
      expect(find.text('メモのテンプレート'), findsOneWidget, reason: 'シートが開く');
      await tester.tap(find.text('精度重視'));
      await tester.pumpAndSettle();

      final TextField field = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('memo-field')),
      );
      expect(field.controller?.text, '精度重視でプレイ');
    });

    testWidgets('既存メモがあるときは改行で区切って追記する', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r-memo'] = _recordWithMemo(
        createTestImageFile(),
        memo: '既存メモ',
      );

      await tester.pumpWidget(
        _wrap(
          _manualForm(
            repository: repository,
            memoTemplateRepository: FakeMemoTemplateRepository(<MemoTemplate>[
              // タイトルと本文を変えておく（同名だと finder が 2 件に当たる）。
              const MemoTemplate(id: 't1', title: '要復習', body: '要復習です'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder templateButton = find.byKey(
        const ValueKey<String>('memo-template-button'),
      );
      await tester.ensureVisible(templateButton);
      await tester.pumpAndSettle();
      await tester.tap(templateButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('要復習'));
      await tester.pumpAndSettle();

      final TextField field = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('memo-field')),
      );
      expect(field.controller?.text, '既存メモ\n要復習です');
    });
  });

  group('テンプレートシート', () {
    testWidgets('1 件も無ければ案内を出す', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrapSheet(MemoTemplateSheet(repository: FakeMemoTemplateRepository())),
      );
      await tester.pumpAndSettle();

      expect(find.text('テンプレートがありません'), findsOneWidget);
    });

    testWidgets('一覧に名前と本文が出る', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrapSheet(
          MemoTemplateSheet(
            repository: FakeMemoTemplateRepository(<MemoTemplate>[
              const MemoTemplate(id: 't1', title: '精度重視', body: '精度重視でプレイ'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('精度重視'), findsOneWidget);
      expect(find.text('精度重視でプレイ'), findsOneWidget);
    });

    testWidgets('追加ダイアログから保存でき、一覧に反映される', (WidgetTester tester) async {
      final FakeMemoTemplateRepository repository =
          FakeMemoTemplateRepository();
      await tester.pumpWidget(
        _wrapSheet(MemoTemplateSheet(repository: repository)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('テンプレートを追加'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, '名前'), '要復習');
      await tester.enterText(find.widgetWithText(TextFormField, '本文'), '要復習: ');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(repository.addCount, 1);
      expect(find.text('要復習'), findsOneWidget);
    });

    testWidgets('名前が空なら保存せずエラーを出す', (WidgetTester tester) async {
      final FakeMemoTemplateRepository repository =
          FakeMemoTemplateRepository();
      await tester.pumpWidget(
        _wrapSheet(MemoTemplateSheet(repository: repository)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('テンプレートを追加'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(repository.addCount, 0);
      expect(find.text('名前を入力してください'), findsOneWidget);
    });

    testWidgets('削除は確認ダイアログを経て反映される', (WidgetTester tester) async {
      final FakeMemoTemplateRepository repository = FakeMemoTemplateRepository(
        <MemoTemplate>[const MemoTemplate(id: 't1', title: '精度重視', body: '本文')],
      );
      await tester.pumpWidget(
        _wrapSheet(MemoTemplateSheet(repository: repository)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('削除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '削除'));
      await tester.pumpAndSettle();

      expect(await repository.listAll(), isEmpty);
      expect(find.text('テンプレートがありません'), findsOneWidget);
    });
  });
}
