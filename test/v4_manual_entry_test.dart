// v4 案2（docs/v4_manual_entry_design_2026-11-23.md）のテスト。
//
// 検証対象:
// (1) repository.create に画像 null を渡すと resultImagePath='' で作成される（§2.3）
// (2) 種別選択シートの「写真なしで手入力」で onManualEntry が発火する（§2.1）
// (3) 手入力保存: confirmed 作成・画面維持・フォームクリア・連続保存（§2.4）
// (4) 一覧: 空画像パスのレコード行はプレースホルダアイコン表示（§2.5）
// (5) 詳細: 空画像パスのレコードで原画像プレビューが非表示（§2.5）

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';
import 'package:scoreyomipm/ui/play_records_screen.dart';
import 'package:scoreyomipm/ui/species_selection_sheet.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';

/// repository テストと同じドラフト（test/play_record_repository_test.dart 準拠）。
PlayRecordDraft _draft({String songName = '曲X', String score = '123456'}) {
  return PlayRecordDraft(
    songName: songName,
    score: score,
    cool: null,
    great: null,
    good: null,
    bad: null,
    maxCombo: null,
    level: null,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
  );
}

void main() {
  group('(1) repository.create の画像省略', () {
    late FilePlayRecordRepository repository;

    setUp(() {
      repository = FilePlayRecordRepository(blobStore: MemoryBlobStore());
    });

    test('画像 null で resultImagePath が空文字のレコードを作成する', () async {
      final PlayRecord record = await repository.create(_draft(), null);

      expect(record.resultImagePath, '');
      // JSONL への追記も崩れない（再読込で回収できる）。
      final List<PlayRecord> all = await repository.listAll();
      expect(all.map((PlayRecord record) => record.id), contains(record.id));
    });

    test('画像あり経路は従来どおりレコードを作成する', () async {
      final Uint8List sourceImage = Uint8List.fromList(<int>[1, 2, 3]);

      final PlayRecord record = await repository.create(_draft(), sourceImage);

      expect(record.resultImagePath, isNot(''));
      expect(await repository.readImage(record.resultImagePath), sourceImage);
    });
  });

  testWidgets('(2) 種別選択シートの「写真なしで手入力」で onManualEntry が発火する', (
    WidgetTester tester,
  ) async {
    bool manualEntryRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (BuildContext sheetContext) =>
                        SpeciesSelectionSheet(
                          // v5 機能 A 対応: コールバックが (String? machine) 引数付きに
                          // 変更されたためのコンパイル追随（機種検証は
                          // v5_difficulty_machine_test.dart が担う）。
                          onPickPlayShare: (_) {},
                          onPickResultGallery: (_) {},
                          onPickResultCamera: (_) {},
                          onPickLivelyGallery: (_) {},
                          onPickLivelyCamera: (_) {},
                          onManualEntry: (_) {
                            manualEntryRequested = true;
                          },
                        ),
                  );
                },
                child: const Text('sheet'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    // WHY(v5 機能 A 追随): シート先頭へ機種 chips 行が増えたため、既定の高さ
    // 制約ある showModalBottomSheet ではこの行が折られて画面外になる。
    // SingleChildScrollView 内なので ensureVisible で可視化してからタップする
    // （ユーザーはスクロールして到達するのと同じ操作経路）。
    await tester.ensureVisible(find.text('写真なしで手入力'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真なしで手入力'));
    await tester.pumpAndSettle();

    expect(manualEntryRequested, isTrue);
  });

  testWidgets('(3) 手入力保存: confirmed 作成・画面維持・フォームクリア・連続保存', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    OcrResultScreen.route(
                      playRecordRepository: repository,
                      appBarTitle: 'スコア手入力',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      '曲X',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-score')),
      // WHY: スコアの有効範囲は 0-100000（範囲外は正規化で null になる）。
      '98765',
    );
    // WHY: enterText 直後はスコア欄にフォーカスが残り、その自動可視化が
    // ensureVisible の後の pumpAndSettle でスクロールを巻き戻すことがある。
    // 先にフォーカスを外してから保存ボタンを可視化して押す。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('save-record-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('save-record-button')));
    await tester.pumpAndSettle();

    // (a) 1 件目が confirmed・画像パス空で作成されている。
    expect(repository.store.length, 1);
    final PlayRecord first = repository.store.values.single;
    expect(first.status, PlayRecordStatus.confirmed);
    expect(first.resultImagePath, '');

    // (b) 画面は閉じない（連続入力のため残る）。
    expect(find.text('スコア手入力'), findsOneWidget);
    // (c) フォームは空へ戻る。
    final TextField scoreField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-score')),
    );
    expect(scoreField.controller?.text, '');
    // (d) SnackBar 文言。
    expect(find.text('スコアを保存しました。続けて入力できます。'), findsOneWidget);

    // (e) 直後の 2 度目の保存で 2 件目が作れる。
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-score')),
      '87654',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('save-record-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('save-record-button')));
    await tester.pumpAndSettle();

    expect(repository.store.length, 2);
    final List<int?> scores = repository.store.values
        .map((PlayRecord record) => record.score)
        .toList(growable: false);
    expect(scores, containsAll(<int?>[98765, 87654]));
  });

  testWidgets('(4) 一覧: 空画像パスのレコード行はプレースホルダアイコン表示', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    repository.store['m1'] = PlayRecord(
      id: 'm1',
      playedAt: DateTime(2026, 11, 23, 12),
      songName: '曲X',
      score: 123456,
      cool: null,
      great: null,
      good: null,
      bad: null,
      maxCombo: null,
      level: null,
      status: PlayRecordStatus.confirmed,
      source: PlayRecordSource.playshare,
      resultImagePath: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlayRecordsScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });

  testWidgets('(5) 詳細: 空画像パスのレコードで原画像プレビューが非表示', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    repository.store['m1'] = PlayRecord(
      id: 'm1',
      playedAt: DateTime(2026, 11, 23, 12),
      songName: '曲X',
      score: 123456,
      cool: null,
      great: null,
      good: null,
      bad: null,
      maxCombo: null,
      level: null,
      status: PlayRecordStatus.confirmed,
      source: PlayRecordSource.playshare,
      resultImagePath: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlayRecordDetailScreen(
          playRecordRepository: repository,
          ocrEngine: FakeOcrEngine(),
          recordId: 'm1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // WHY: 原画像が存在しないのに「画像ファイルが見つかりません」等の誤解を招く
    // 表示を出さない。プレビュー節ごと非表示にする。
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
