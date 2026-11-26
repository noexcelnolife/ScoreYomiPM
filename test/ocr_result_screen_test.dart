// OcrResultScreen（FR-3 確認・修正画面）のウィジェットテスト。
//
// 検証対象:
// (a) 抽出済みフィールドの表示（値・信頼度）
// (b) isValid=false フィールドの強調表示（errorContainer 色 + validationMessage）
// (c) 未抽出フィールドの手入力欄（GREAT 等）
// (d) extractionResult = null 時の要素一覧フォールバック
// (e) 抽出済み値の編集可否（FR-3 は「確認・修正」画面のため）
// (f) レベル抽出表示 / 未抽出時手入力（Wave 2 リージョン再 OCR 由来）
// (g) 画像プレビューの InteractiveViewer 拡大縮小（v2 UX 改修2）
// (h) 未抽出かつ未入力の欄の黄色強調とライブ解除（v2 UX 改修3）
// (i) 手入力候補選択の DB 総ノーツリンク（v2 UX #15）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/validation/validation_issue.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';

import 'fake_play_record_repository.dart';

/// テスト用テーマ（アプリ本体と同じ Material 3 + indigo シード）。
final ThemeData _testTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
);

OcrPageResult _pageResult() {
  return OcrPageResult(
    fullText: 'SCORE 98,108',
    elements: <OcrElement>[
      OcrElement(
        text: 'SCORE',
        boundingBox: Rect.fromLTWH(10, 10, 50, 20),
        confidence: 0.9,
      ),
      OcrElement(
        text: '98,108',
        boundingBox: Rect.fromLTWH(70, 10, 80, 20),
        confidence: 0.88,
      ),
    ],
  );
}

/// 0 要素（読めない画像）のフィクスチャ。
///
/// WHY: smoke test 修正②の対象 — 読めない画像は全項目空フォームに着地し
/// 「読めなかった」ことが伝わらない。実フロー同等に寸法付きで構成する。
OcrPageResult _emptyPageResult() {
  return OcrPageResult(
    fullText: '',
    elements: <OcrElement>[],
    imageWidth: 1080,
    imageHeight: 1920,
  );
}

/// スコア（有効）/ COOL（無効）/ レベル（有効）を抽出済み、他は未抽出のフィクスチャ。
FieldExtractionResult _extraction() {
  return FieldExtractionResult(
    numericFields: <NumericFieldKind, ExtractedField>{
      NumericFieldKind.score: ExtractedField(
        kind: NumericFieldKind.score,
        value: 98108,
        rawText: '98,108',
        confidence: 0.95,
        boundingBox: Rect.fromLTWH(70, 10, 80, 20),
        isValid: true,
        validationMessage: null,
        evidence: const <OcrElement>[],
      ),
      NumericFieldKind.cool: ExtractedField(
        kind: NumericFieldKind.cool,
        value: 999999,
        rawText: '999,999',
        confidence: 0.7,
        boundingBox: Rect.fromLTWH(70, 60, 80, 20),
        isValid: false,
        validationMessage: 'cool は 0〜99999 の範囲外です: 999999',
        evidence: const <OcrElement>[],
      ),
      NumericFieldKind.level: ExtractedField(
        kind: NumericFieldKind.level,
        value: 30,
        rawText: 'Lv.30',
        confidence: 0.92,
        boundingBox: Rect.fromLTWH(70, 100, 40, 20),
        isValid: true,
        validationMessage: null,
        evidence: const <OcrElement>[],
      ),
    },
    sourceElementCount: 3,
  );
}

/// レベルを未抽出のフィクスチャ（Wave 2 未接続・クロップ空の場合）。
FieldExtractionResult _extractionWithoutLevel() {
  return FieldExtractionResult(
    numericFields: <NumericFieldKind, ExtractedField>{
      NumericFieldKind.score: ExtractedField(
        kind: NumericFieldKind.score,
        value: 98108,
        rawText: '98,108',
        confidence: 0.95,
        boundingBox: Rect.fromLTWH(70, 10, 80, 20),
        isValid: true,
        validationMessage: null,
        evidence: const <OcrElement>[],
      ),
    },
    sourceElementCount: 1,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: _testTheme,
    home: Scaffold(body: child),
  );
}

/// 保存ボタンまでスクロールしてから押す。
///
/// WHY（01a20b34・項目順変更に伴う追随）: 保存ボタンがフォームの最終要素に
/// なった。直前の `enterText` で曲名欄がフォーカスを取っており、フォーカス中の
/// フィールドへ戻す `showOnScreen` が `pumpAndSettle` 中に走るため、
/// `ensureVisible` で送ったスクロールが巻き戻り、ボタンが 800×600 の
/// ビューポート外に残って `tap` が空振りする（保存が呼ばれない）。
/// フォーカスを外してから送ることで巻き戻りを止める。
Future<void> _tapSaveButton(WidgetTester tester) async {
  final Finder saveButton = find.byKey(
    const ValueKey<String>('save-record-button'),
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(saveButton);
  await tester.pumpAndSettle();
  await tester.tap(saveButton);
  await tester.pump();
}

/// FR-5: 未決定（autoDecided=false）の複数候補を持つ照合結果フィクスチャ。
/// 1 件目が bestMatchOriginal（プリフィル対象）と同一の値なので、
/// 曲名欄とチップで同じ文字列が 2 か所に現れる状態を再現する。
const SongMatchResult _undecidedMatch = SongMatchResult(
  rawOcrText: 'london sweet',
  normalizedOcrText: 'london sweet',
  bestMatchNormalized: 'london sweet',
  bestMatchOriginal: 'ロンドン☆スウィート',
  bestDistance: 2,
  topCandidates: <SongMatchCandidate>[
    SongMatchCandidate(
      normalizedTitle: 'london sweet',
      originalTitle: 'ロンドン☆スウィート',
      distance: 2,
    ),
    SongMatchCandidate(
      normalizedTitle: 'london deli',
      originalTitle: 'ロンドン☆デリ',
      distance: 3,
    ),
  ],
  autoDecided: false,
);

void main() {
  testWidgets('抽出済みフィールドの値・信頼度と全フィールド行が表示される', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      ),
    );

    // フィールドセクションのラベル（スコア/MAX COMBO/レベル/COOL/GREAT/GOOD/BAD/曲名）。
    // 本作には MISS 判定が存在しないため MISS 行は表示しない。
    expect(find.text('スコア'), findsOneWidget);
    expect(find.text('MAX COMBO'), findsOneWidget);
    expect(find.text('レベル'), findsOneWidget);
    expect(find.text('COOL'), findsOneWidget);
    expect(find.text('GREAT'), findsOneWidget);
    expect(find.text('GOOD'), findsOneWidget);
    expect(find.text('BAD'), findsOneWidget);
    expect(find.text('MISS'), findsNothing);
    expect(find.text('曲名'), findsOneWidget);

    // (a) 抽出値と信頼度。スコアとレベルは TextField に初期値として入る。
    expect(find.text('98108'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('信頼度: 95.0%'), findsOneWidget);
    expect(find.text('信頼度: 92.0%'), findsOneWidget);

    // 未抽出フィールドは「未抽出（手入力）」表示
    // （数値 7 行のうち score / cool / level が抽出済み → 4 行 + 曲名行 = 5 行）。
    expect(find.text('未抽出（手入力）'), findsNWidgets(5));
  });

  testWidgets('レベル未抽出時は手入力欄として表示される', (WidgetTester tester) async {
    // (f) 未抽出時手入力：level が抽出結果に含まれない場合は空欄の TextField。
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extractionWithoutLevel(),
        ),
      ),
    );

    expect(find.text('レベル'), findsOneWidget);
    expect(find.text('未抽出（手入力）'), findsNWidgets(7));

    final Finder levelInput = find.byKey(
      const ValueKey<String>('field-input-level'),
    );
    expect(levelInput, findsOneWidget);
    expect(find.text('77'), findsNothing);

    await tester.enterText(levelInput, '77');
    await tester.pump();

    expect(find.text('77'), findsOneWidget);
  });

  testWidgets('isValid=false のフィールドは強調表示とvalidationMessageが出る', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      ),
    );

    // (b) validationMessage の表示。
    expect(find.text('cool は 0〜99999 の範囲外です: 999999'), findsOneWidget);

    // errorContainer 色で強調されていること。
    final Container row = tester.widget<Container>(
      find.byKey(const ValueKey<String>('field-row-cool')),
    );
    final BoxDecoration decoration = row.decoration! as BoxDecoration;
    expect(decoration.color, _testTheme.colorScheme.errorContainer);

    // 有効なスコア行・レベル行は強調されないこと。
    for (final id in <String>['score', 'level']) {
      final Container validRow = tester.widget<Container>(
        find.byKey(ValueKey<String>('field-row-$id')),
      );
      final BoxDecoration validDecoration =
          validRow.decoration! as BoxDecoration;
      expect(validDecoration.color, isNull);
    }
  });

  testWidgets('未抽出フィールド（GREAT）は手入力できる', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      ),
    );

    // (c) 未抽出フィールドの入力欄が存在し、空で始まる。
    final Finder greatInput = find.byKey(
      const ValueKey<String>('field-input-great'),
    );
    expect(greatInput, findsOneWidget);
    expect(find.text('1234'), findsNothing);

    await tester.enterText(greatInput, '1234');
    await tester.pump();

    expect(find.text('1234'), findsOneWidget);
  });

  testWidgets('抽出済みの値も編集できる', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      ),
    );

    // FR-3 は「確認・修正」画面のため、抽出済み値も修正可能。
    final Finder scoreInput = find.byKey(
      const ValueKey<String>('field-input-score'),
    );
    await tester.enterText(scoreInput, '99000');
    await tester.pump();

    expect(find.text('99000'), findsOneWidget);
    expect(find.text('98108'), findsNothing);
  });

  testWidgets('extractionResult が null なら要素一覧へフォールバックする', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          // エラー時: extractionResult なし → フィールドセクションを出さない。
          extractionResult: null,
        ),
      ),
    );

    // フィールドセクションが表示されないこと。
    expect(find.text('スコア確認・修正'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('field-input-great')),
      findsNothing,
    );

    // 従来どおり要素一覧が表示されること。
    expect(find.text('検出要素: 2 件'), findsOneWidget);
    expect(find.text('SCORE'), findsOneWidget);
    expect(find.text('98,108'), findsOneWidget);
  });

  // ---- FR-4: 未確定レコード保存 ----

  testWidgets('保存ボタンで曲名つきの確定レコードを作成する', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          playRecordRepository: repository,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ロンドン☆スウィート',
    );
    await _tapSaveButton(tester);

    expect(repository.createdDrafts, hasLength(1));
    final PlayRecordDraft draft = repository.createdDrafts.single;
    expect(draft.songName, 'ロンドン☆スウィート');
    expect(draft.status, PlayRecordStatus.confirmed);
    expect(draft.source, PlayRecordSource.playshare);
    expect(draft.score, '98108');
    expect(find.text('スコアを保存しました。'), findsOneWidget);
  });

  testWidgets('曲名が空のまま保存すると未確定レコードになる', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          playRecordRepository: repository,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-score')),
      '98108',
    );
    await _tapSaveButton(tester);

    expect(repository.createdDrafts, hasLength(1));
    expect(repository.createdDrafts.single.songName, isEmpty);
    expect(repository.createdDrafts.single.status, PlayRecordStatus.pending);
    expect(repository.store.values.single.status, PlayRecordStatus.pending);
    expect(repository.store.values.single.songName, isNull);
  });

  testWidgets('既存レコード指定時は update で保存する', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['rec-1'] =
          PlayRecordDraft(
            songName: null,
            status: PlayRecordStatus.pending,
            source: PlayRecordSource.playshare,
          ).toPlayRecord(
            id: 'rec-1',
            resultImagePath: 'dummy.png',
            playedAt: DateTime(2026, 11, 22, 12),
          );

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          playRecordRepository: repository,
          existingRecordId: 'rec-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 復元済みの値を上書きして保存する。
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-score')),
      '99000',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'テスト曲',
    );
    await _tapSaveButton(tester);

    expect(repository.createdDrafts, isEmpty);
    final PlayRecord updated = repository.store['rec-1']!;
    expect(updated.id, 'rec-1');
    expect(updated.playedAt, DateTime(2026, 11, 22, 12));
    expect(updated.songName, 'テスト曲');
    expect(updated.score, 99000);
    expect(updated.status, PlayRecordStatus.confirmed);
  });

  testWidgets('手入力モード（pageResult なし）でもフィールド入力と保存ができる', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['rec-2'] = PlayRecordDraft(
        songName: null,
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      ).toPlayRecord(id: 'rec-2', resultImagePath: 'dummy.png');

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
          existingRecordId: 'rec-2',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('スコア手入力'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('save-record-button')),
      findsOneWidget,
    );
    expect(find.textContaining('検出要素'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      '手入力の曲',
    );
    await _tapSaveButton(tester);

    expect(repository.store['rec-2']!.songName, '手入力の曲');
  });

  testWidgets('songMatchResult.bestMatchOriginal で曲名が事前入力される', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          songMatchResult: SongMatchResult(
            rawOcrText: 'london sweet',
            normalizedOcrText: 'london sweet',
            bestMatchNormalized: 'london sweet',
            bestMatchOriginal: 'ロンドン☆スウィート',
            bestDistance: 0,
            topCandidates: const <SongMatchCandidate>[],
            autoDecided: true,
          ),
        ),
      ),
    );

    expect(find.text('ロンドン☆スウィート'), findsOneWidget);
    // リポジトリ未注入なら保存ボタンは出ない（FR-3 の「表示だけ」の使い方）。
    expect(
      find.byKey(const ValueKey<String>('save-record-button')),
      findsNothing,
    );
  });

  testWidgets('保存に失敗したら SnackBar で通知する', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository(
      failOnCreate: true,
    );
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          playRecordRepository: repository,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ロンドン☆スウィート',
    );
    await _tapSaveButton(tester);

    expect(find.textContaining('保存に失敗しました'), findsOneWidget);
    // 失敗時は画面に留まり、再試行できる。
    expect(
      find.byKey(const ValueKey<String>('save-record-button')),
      findsOneWidget,
    );
  });

  testWidgets('appBarTitle を指定すると手入力モードのタイトルが変わる', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['rec-3'] = PlayRecordDraft(
        songName: null,
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      ).toPlayRecord(id: 'rec-3', resultImagePath: 'dummy.png');

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
          existingRecordId: 'rec-3',
          appBarTitle: 'スコア修正',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('スコア修正'), findsOneWidget);
    expect(find.text('スコア手入力'), findsNothing);
  });

  testWidgets('リポジトリ未注入では保存ボタンを出さない（FR-3 回帰ガード）', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('save-record-button')),
      findsNothing,
    );
  });

  // ---- 空保存ガード（v2 UX 修正 #10・P-7・リード裁定 2026-11-23） ----
  // WHY: 全項目空の保存は画像だけの pending を誤操作で量産し得る。ただし
  // 画像だけの pending 自体は FR-4 の正当な実体（OcrEngineException 自動
  // 保存がまさにこの形）のため全面禁止はできない — 全項目空のときだけ
  // 確認ダイアログの 1 折りを挟む。部分空（曲名だけ空で値あり等）は FR-4
  // 設計済みの正動作なので対象外。
  // ポンプ構成: 0 要素パイプライン成功相当（実フローの P-7 発生経路）。
  group('空保存ガード', () {
    // 0 要素 + フィールドセクションは ListView 1 項目として高くなり、既定の
    // 800x600 ビューポートでは保存ボタンがスクロール範囲外に描画される
    // （maxScrollExtent を超えるはみ出しで ensureVisible も届かない）。
    // テスト用にビューポートを縦に伸ばして全体を収め、スクロールに依存しない
    // タップにする（実機 ≈829dp では全体が収まっており本番挙動に影響なし）。
    Future<void> pumpAllEmpty(
      WidgetTester tester,
      FakePlayRecordRepository repository,
    ) async {
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _emptyPageResult(),
            extractionResult: FieldExtractionResult(
              numericFields: const <NumericFieldKind, ExtractedField>{},
              sourceElementCount: 0,
            ),
            playRecordRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('全項目空で保存すると確認ダイアログが出て、確認するまで pending は作られない', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpAllEmpty(tester, repository);

      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pump();

      expect(find.text('全ての項目が未入力です'), findsOneWidget);
      expect(find.text('画像だけを未確定レコードとして保存しますか？'), findsOneWidget);
      expect(repository.createdDrafts, isEmpty);

      // キャンセルでは何も作らない（誤操作抑止の反対側も固定）
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(repository.createdDrafts, isEmpty);
    });

    testWidgets('ダイアログを確認すると画像だけの pending が作られる（現行契約維持）', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpAllEmpty(tester, repository);

      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pump();
      await tester.tap(find.text('画像だけ保存する'));
      await tester.pumpAndSettle();

      expect(repository.createdDrafts, hasLength(1));
      expect(repository.createdDrafts.single.songName, isEmpty);
      expect(repository.createdDrafts.single.status, PlayRecordStatus.pending);
    });

    testWidgets('値が 1 つでもあればダイアログを出さずに現行どおり保存する（部分空・通常保存の非回帰）', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpAllEmpty(tester, repository);

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '98108',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pump();

      expect(find.text('全ての項目が未入力です'), findsNothing);
      expect(repository.createdDrafts, hasLength(1));
      expect(repository.createdDrafts.single.songName, isEmpty);
      expect(repository.createdDrafts.single.score, '98108');
      expect(repository.createdDrafts.single.status, PlayRecordStatus.pending);
    });
  });

  // ---- 修正画面の編集破棄確認（v2 UX 修正 #11・P-6・リード裁定 2026-11-23） ----
  // WHY: 修正画面（手入力モード・既存レコード復元）で値変更後に戻ると確認
  // なしで破棄されていた（smoke test レポート P-6）。変更なしの戻りは通常の
  // 閲覧動作なのでダイアログを出さない。dirty 判定は復元値との trim 差分。
  group('修正画面の破棄確認', () {
    // AppBar の自動 BackButton で戻るを実現するため、編集画面を
    // ルートから push して開く（home 直配置は back ボタンを持たない）。
    Future<void> pumpEditFlow(
      WidgetTester tester,
      FakePlayRecordRepository repository,
    ) async {
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      repository.store['rec-edit'] = PlayRecordDraft(
        songName: 'Harmonia',
        score: '98108',
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      ).toPlayRecord(id: 'rec-edit', resultImagePath: 'dummy.png');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext routeContext) => OcrResultScreen(
                      imageFile: File('dummy.png'),
                      pageResult: null,
                      extractionResult: null,
                      existingRecordId: 'rec-edit',
                      playRecordRepository: repository,
                      appBarTitle: 'スコア修正',
                    ),
                  ),
                );
              },
              child: const Text('open-edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-edit'));
      await tester.pumpAndSettle();
    }

    testWidgets('変更ありで戻ると破棄確認ダイアログが出て、破棄で閉じ・更新しない', (tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpEditFlow(tester, repository);

      // 復元値から変える（dirty）
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '99999',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();

      expect(find.text('変更を破棄しますか？'), findsOneWidget);
      // 確認前は update を呼ばない（PlayRecord.score は int 型）
      expect(repository.store['rec-edit']?.score, 98108);

      await tester.tap(find.text('破棄する'));
      await tester.pumpAndSettle();

      // 画面が閉じ・レコードは更新されない
      expect(find.text('open-edit'), findsOneWidget);
      expect(repository.store['rec-edit']?.score, 98108);
    });

    testWidgets('変更なしで戻るとダイアログを出さずに即戻る（閲覧動作の非回帰）', (tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpEditFlow(tester, repository);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();

      expect(find.text('変更を破棄しますか？'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('open-edit'), findsOneWidget);
    });

    testWidgets('値変更後に保存すると、破棄確認なしで画面が閉じる（P-6 フォローアップ）', (tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpEditFlow(tester, repository);

      // 復元値から変えて保存する。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'Harmonia 改',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();

      // WHY(P-6 フォローアップ・リード裁定 2026-11-23): 保存済みの値が新しい
      // 基準値になるため、保存直後の戻りは「未保存の変更」ではない → 破棄確認
      // を出さずに閉じる。現状は maybePop が PopScope(canPop:false) に阻害され
      // dirty 判定のままダイアログが出る（red）。
      expect(find.text('変更を破棄しますか？'), findsNothing);
      expect(find.byType(OcrResultScreen), findsNothing);
      expect(repository.store['rec-edit']!.songName, 'Harmonia 改');
    });
  });

  // ---- FR-5: 曲名複数候補の 1 タップ選択 UI ----
  // 設計: docs/fr5_candidate_selection_ui_design_confirmation_2026-11-22.md
  // red では最初に表示条件の拡張（未決定候補があればセクションを出す）を固定する。

  // FR-5: showFieldSection の拡張条件。これまで
  // extractionResult != null || existingRecordId != null だったが、
  // 未決定（autoDecided=false）かつ topCandidates 非空の場合も表示対象に加える。
  testWidgets('抽出結果が無くても未決定候補があればフィールドセクションを出す', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: null,
          songMatchResult: _undecidedMatch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('スコア確認・修正'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsOneWidget,
    );
  });

  testWidgets('未決定の複数候補をチップで表示し、タップで曲名欄に設定する', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          songMatchResult: _undecidedMatch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 距離昇順で候補チップを並べる。
    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('candidate-chip-1')),
      findsOneWidget,
    );
    // 1 件目のラベルは曲名欄プリフィルと同一文字列のため
    // TextField とチップの両方に現れる（件数断言はしない）。
    // 2 件目はプリフィルと異なる値なので一意に数えられる。
    expect(find.text('ロンドン☆デリ'), findsOneWidget);
    // 距離数値は候補領域に表示しない（設計 §2.3）。
    // スコア等の数値と誤マッチしないよう Wrap 領域に限定して断言する。
    final Finder candidateArea = find.byType(Wrap);
    expect(
      find.descendant(of: candidateArea, matching: find.text('2')),
      findsNothing,
    );
    expect(
      find.descendant(of: candidateArea, matching: find.text('3')),
      findsNothing,
    );

    // タップで曲名欄に候補値を設定する。
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('candidate-chip-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-1')));
    await tester.pump();

    final TextField songNameField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(songNameField.controller!.text, 'ロンドン☆デリ');
  });

  testWidgets('自動決定済みでは候補チップを出さない', (WidgetTester tester) async {
    const SongMatchResult autoDecidedMatch = SongMatchResult(
      rawOcrText: 'london sweet',
      normalizedOcrText: 'london sweet',
      bestMatchNormalized: 'london sweet',
      bestMatchOriginal: 'ロンドン☆スウィート',
      bestDistance: 0,
      topCandidates: <SongMatchCandidate>[
        SongMatchCandidate(
          normalizedTitle: 'london sweet',
          originalTitle: 'ロンドン☆スウィート',
          distance: 0,
        ),
      ],
      autoDecided: true,
    );

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          songMatchResult: autoDecidedMatch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsNothing,
    );
    expect(find.text('曲名候補（タップで入力）'), findsNothing);
    // 自動決定済みでも曲名プリフィルは現状維持（設計 §2.4）。
    final TextField songNameField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(songNameField.controller!.text, 'ロンドン☆スウィート');
  });

  testWidgets('候補が空なら候補チップを出さない', (WidgetTester tester) async {
    const SongMatchResult emptyCandidatesMatch = SongMatchResult(
      rawOcrText: 'unknown song',
      normalizedOcrText: 'unknown song',
      bestMatchNormalized: null,
      bestMatchOriginal: null,
      bestDistance: null,
      topCandidates: <SongMatchCandidate>[],
      autoDecided: false,
    );

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          songMatchResult: emptyCandidatesMatch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsNothing,
    );
    expect(find.text('曲名候補（タップで入力）'), findsNothing);
  });

  testWidgets('既存レコード + 抽出結果あり（再 OCR 経路）では候補タップが prefill 値を上書きする', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['rec-4'] = PlayRecordDraft(
        songName: 'テスト曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ).toPlayRecord(id: 'rec-4', resultImagePath: 'dummy.png');

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
          playRecordRepository: repository,
          existingRecordId: 'rec-4',
          songMatchResult: _undecidedMatch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // WHY: extractionResult 非 null + existingRecordId 非 null は再 OCR 経路
    // と同型であり、復元はスキップされて prefill（bestMatchOriginal）が入る
    // （リード裁定 01a203bc）。初期値の期待を新契約に更新する。
    final TextField songNameField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(songNameField.controller!.text, 'ロンドン☆スウィート');

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('candidate-chip-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-1')));
    await tester.pump();

    // 値のセットは手動入力と同一経路（コントローラへの代入）であることのピン。
    // これにより保存時の deriveStatus 等の挙動が手入力と完全一致する。
    expect(songNameField.controller!.text, 'ロンドン☆デリ');
  });

  // ---- FR-6: 整合性検証（VR-2'・VR-4・VR-3'）の UI 配線 ----
  // 設計: docs/fr6_validation_design_confirmation_2026-11-22.md §7。
  // 検証メッセージは FR-3 の既存ハイライト（errorContainer + メッセージ併記）を流用する。

  /// FR-6: 5 値が揃っているが整合しないフィクスチャ。
  /// score=88000 は tnt' = 1442×100000/88000 = 1638.6（判定合計 1600・差 38.6 > 24）。
  FieldExtractionResult inconsistentExtraction() {
    return FieldExtractionResult(
      numericFields: <NumericFieldKind, ExtractedField>{
        for (final (NumericFieldKind kind, int value, String raw)
            in <(NumericFieldKind, int, String)>[
              (NumericFieldKind.score, 88000, '88,000'),
              (NumericFieldKind.cool, 1200, '1,200'),
              (NumericFieldKind.great, 300, '300'),
              (NumericFieldKind.good, 80, '80'),
              (NumericFieldKind.bad, 20, '20'),
            ])
          kind: ExtractedField(
            kind: kind,
            value: value,
            rawText: raw,
            confidence: 0.9,
            boundingBox: Rect.fromLTWH(70, 10, 80, 20),
            isValid: true,
            validationMessage: null,
            evidence: const <OcrElement>[],
          ),
      },
      sourceElementCount: 5,
    );
  }

  /// FR-6: 5 値が揃っていて整合するフィクスチャ（score=90125 → tnt'=1600.0）。
  FieldExtractionResult consistentExtraction() {
    return FieldExtractionResult(
      numericFields: <NumericFieldKind, ExtractedField>{
        for (final (NumericFieldKind kind, int value, String raw)
            in <(NumericFieldKind, int, String)>[
              (NumericFieldKind.score, 90125, '90,125'),
              (NumericFieldKind.cool, 1200, '1,200'),
              (NumericFieldKind.great, 300, '300'),
              (NumericFieldKind.good, 80, '80'),
              (NumericFieldKind.bad, 20, '20'),
            ])
          kind: ExtractedField(
            kind: kind,
            value: value,
            rawText: raw,
            confidence: 0.9,
            boundingBox: Rect.fromLTWH(70, 10, 80, 20),
            isValid: true,
            validationMessage: null,
            evidence: const <OcrElement>[],
          ),
      },
      sourceElementCount: 5,
    );
  }

  testWidgets('整合しない判定内訳では検証メッセージを表示する（VR-2′）', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: inconsistentExtraction(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // VR-2′ のメッセージは 5 行すべてに表示される（誤読側が確定できないため）。
    // 文言は v2 UX #11（P-9）で差し替え済み。先頭語で固定。
    expect(find.textContaining('スコアから計算したノーツ合計の見込み'), findsNWidgets(5));
    // 対象行は既存の FR-3 ハイライトと同じ errorContainer 良で強調される。
    final Container scoreRow = tester.widget<Container>(
      find.byKey(const ValueKey<String>('field-row-score')),
    );
    final BoxDecoration decoration = scoreRow.decoration! as BoxDecoration;
    expect(decoration.color, isNotNull);
  });

  testWidgets('整合する判定内訳では検証メッセージを表示しない', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: consistentExtraction(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('スコアから計算したノーツ合計の見込み'), findsNothing);
  });

  testWidgets('値を修正すると検証メッセージが消える（ライブ再計算）', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: inconsistentExtraction(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('スコアから計算したノーツ合計の見込み'), findsWidgets);

    // score を整合する値に直す → listener 経由で再検証されメッセージが消える。
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-score')),
      '90125',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('スコアから計算したノーツ合計の見込み'), findsNothing);
  });

  testWidgets('手入力モードでは検証メッセージを出さない', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(OcrResultScreen(imageFile: File('dummy.png'), pageResult: null)),
    );
    await tester.pumpAndSettle();

    // 全値が未入力（null）のため検証はすべてスキップされる。
    expect(find.textContaining('スコアから計算したノーツ合計の見込み'), findsNothing);
    expect(find.textContaining('MAX COMBO が判定合計'), findsNothing);
  });

  group('FR-6 段階 B: matchedSong による VR-1/VR-3 の表示', () {
    // 設計: docs/fr6_stage_b_vr1_vr3_design_confirmation_2026-11-22.md §1/§5/§7。
    // matchedSong は HomeScreen が pipeline.run() の context から分解して渡す
    // （run() 戻り値は context 全体・lib/ocr 変更ゼロの消費者パターン）。
    // notesCounts を 1599（EX/HYPER 同値）にすると判定合計 1600 が上限を超える。

    testWidgets('matchedSong あり: 判定行に VR-1 のメッセージを表示する', (tester) async {
      const SongEntry song = SongEntry(
        id: 'song-1',
        title: 'テスト曲',
        normalizedKey: 'てすときょく',
        notesCounts: <String, int>{'HYPER': 1599, 'EX': 1599},
      );
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: inconsistentExtraction(),
            matchedSong: song,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // VR-1 は 4 判定行（cool/great/good/bad）のみハイライト・score 行は対象外。
      expect(find.textContaining('総ノーツ数（推定 1599）'), findsNWidgets(4));
    });

    testWidgets('matchedSong なし: notes 系メッセージは表示しない', (tester) async {
      // 同じ誤読値でも matchedSong が渡らなければ欠損 skip 契約（設計 §5）。
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: inconsistentExtraction(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('総ノーツ数'), findsNothing);
    });
  });

  group('0 要素時の通知表示（smoke test 修正②）', () {
    // WHY: 読めない画像（0 要素）でもフィールドセクションに着地するため
    // 「読めなかった」ことが伝わらず、FR-3 手入力を自力で発見する必要が
    // あった。0 要素着地時のみ通知 1 行を出し、通常結果・手動モードでは
    // 出さない（no-op ガード）。

    testWidgets('0 要素でフィールドセクションに着地した場合、通知 1 行を表示する', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _emptyPageResult(),
            extractionResult: FieldExtractionResult(
              numericFields: <NumericFieldKind, ExtractedField>{},
              sourceElementCount: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自動読み取りできませんでした。値を手動で入力してください'), findsOneWidget);
    });

    testWidgets('要素がある通常結果では通知を表示しない', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自動読み取りできませんでした。値を手動で入力してください'), findsNothing);
    });

    testWidgets('手動モード（pageResult null）では通知を表示しない', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(OcrResultScreen(imageFile: File('dummy.png'))),
      );
      await tester.pumpAndSettle();

      expect(find.text('自動読み取りできませんでした。値を手動で入力してください'), findsNothing);
    });
  });

  group('再 OCR 経路の抽出値優先（smoke test 修正フォローアップ）', () {
    // WHY: 再 OCR 経路（extractionResult 非 null + existingRecordId 非 null）
    // では既存レコード復元（FR-4 _applyRestoredRecord）が抽出値を復元値
    // （null → 空文字）で上書きし、空フォームに着地していた（リード裁定:
    // 再 OCR の目的は「新鮮な OCR 値の提示」）。復元は extractionResult ==
    // null（手入力・修正モード）のときだけ実行し、re-OCR 経路では曲名
    // prefill（bestMatchOriginal）を有効にする。

    testWidgets('空 pending レコードの再 OCR では抽出値が表示される（復元で消えない）', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['rec-9'] =
            PlayRecordDraft(
              songName: null,
              status: PlayRecordStatus.pending,
              source: PlayRecordSource.playshare,
            ).toPlayRecord(
              id: 'rec-9',
              resultImagePath: 'dummy.png',
              playedAt: DateTime(2026, 11, 22, 12),
            );

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
            playRecordRepository: repository,
            existingRecordId: 'rec-9',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 抽出値が復元（全 null → 空文字）で消えていないこと。
      final TextField scoreField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('field-input-score')),
      );
      expect(scoreField.controller!.text, '98108');
      final TextField coolField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('field-input-cool')),
      );
      expect(coolField.controller!.text, '999999');
    });

    testWidgets('再 OCR 経路で matchedSong が解決していれば曲名欄に事前入力される', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['rec-10'] =
            PlayRecordDraft(
              songName: null,
              status: PlayRecordStatus.pending,
              source: PlayRecordSource.playshare,
            ).toPlayRecord(
              id: 'rec-10',
              resultImagePath: 'dummy.png',
              playedAt: DateTime(2026, 11, 22, 12),
            );

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
            playRecordRepository: repository,
            existingRecordId: 'rec-10',
            songMatchResult: _undecidedMatch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final TextField songNameField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('field-input-songName')),
      );
      expect(songNameField.controller!.text, 'ロンドン☆スウィート');
    });
  });

  group('未抽出空欄の黄色強調（v2 UX 改修3）', () {
    // WHY: 本体実装と同じ値の tying 定数。未抽出（ExtractedField なし）かつ
    // 未入力の欄は「まだ確認していない」状態を黄色系の半透明で示し、入力で
    // ライブ解除する。検証違反（FR-3/FR-6）の errorContainer が最優先。
    final Color unextractedHighlight = Colors.yellow.withValues(alpha: 0.35);

    BoxDecoration rowDecoration(WidgetTester tester, String id) {
      final Container row = tester.widget<Container>(
        find.byKey(ValueKey<String>('field-row-$id')),
      );
      return row.decoration! as BoxDecoration;
    }

    testWidgets('未抽出かつ未入力の行は黄色系で強調される', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extractionWithoutLevel(),
          ),
        ),
      );

      // 抽出済み（score）の行は黄色にしない。
      expect(rowDecoration(tester, 'score').color, isNull);
      // 未抽出かつ空の行（GREAT/GOOD/BAD/最大コンボ/レベル/曲名）は黄色。
      for (final String id in <String>[
        'great',
        'good',
        'bad',
        'maxCombo',
        'level',
        'songName',
      ]) {
        expect(
          rowDecoration(tester, id).color,
          unextractedHighlight,
          reason: 'field-row-$id は未抽出かつ未入力のため黄色であるべき',
        );
      }
    });

    testWidgets('未抽出行への入力で黄色が解消される（曲名・レベルもライブ解除）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extractionWithoutLevel(),
          ),
        ),
      );

      // 曲名（ST-4: 抽出対象外 → 常に「未抽出」扱い）への入力で解除される。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'Harmonia',
      );
      await tester.pump();
      expect(rowDecoration(tester, 'songName').color, isNull);

      // レベル（これまで検証リスナー対象外だった欄）への入力でも解除される。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-level')),
        '19',
      );
      await tester.pump();
      expect(rowDecoration(tester, 'level').color, isNull);

      // 入力していない未抽出行は黄色のまま（解除は入力した行だけ）。
      expect(rowDecoration(tester, 'good').color, unextractedHighlight);
    });

    testWidgets('検証違反の行は黄色ではなく errorContainer が優先される', (
      WidgetTester tester,
    ) async {
      // WHY: 0 要素結果は全欄が未抽出＋空のため、手入力で VR-2′（判定合計
      // 不整合）を起こし、未抽出かつ違反ありの行が黄色ではなく errorContainer
      // になることを固定する。入力値は VR-2′ テストの「GOOD を誤読（+100）」
      // ケースと同一（スコア⇔判定内訳の 5 欄すべてに issue が乗る）。
      // ビューポート拡大の理由は空保存ガード group の pumpAllEmpty と同じ。
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _emptyPageResult(),
            extractionResult: FieldExtractionResult(
              numericFields: const <NumericFieldKind, ExtractedField>{},
              sourceElementCount: 0,
            ),
            playRecordRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '90125',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-cool')),
        '1200',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-great')),
        '300',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-good')),
        '180',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-bad')),
        '20',
      );
      await tester.pumpAndSettle();

      // 未抽出かつ違反ありの行は errorContainer（黄色にしない）。
      expect(
        rowDecoration(tester, 'cool').color,
        _testTheme.colorScheme.errorContainer,
      );
      expect(rowDecoration(tester, 'cool').color, isNot(unextractedHighlight));
      // 違反のない未抽出・未入力行（レベル）は黄色のまま。
      expect(rowDecoration(tester, 'level').color, unextractedHighlight);
    });

    testWidgets('復元値がある欄は黄色にならず、空欄は黄色になる（修正画面）', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['rec-yellow'] = PlayRecordDraft(
          songName: 'Harmonia',
          score: '98108',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ).toPlayRecord(id: 'rec-yellow', resultImagePath: 'dummy.png');

      // 修正モード（extraction null + existingRecordId）は全欄が未抽出扱い。
      // 復元値を持つ曲名・スコアは黄色にせず、空欄だけ黄色にする。
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: null,
            extractionResult: null,
            existingRecordId: 'rec-yellow',
            playRecordRepository: repository,
            appBarTitle: 'スコア修正',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(rowDecoration(tester, 'songName').color, isNull);
      expect(rowDecoration(tester, 'score').color, isNull);
      expect(rowDecoration(tester, 'cool').color, unextractedHighlight);
    });
  });

  group('画像プレビューの拡大縮小（v2 UX 改修2）', () {
    // WHY: 既定 800×600 テストビューポートではフォーム部分（1 ListView 項目
    // ≈950px）が画面を満たし、プレビュー項目がまだ構築されない（実機では
    // ≈829dp に収まる・実バグではない）。空保存ガード group と同じ拡大で全項目
    // を構築させてから検査する。
    Future<void> pumpWide(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(child));
    }

    testWidgets('通常モードの画像プレビューが InteractiveViewer で拡縮でき、表示枠の高さは維持される', (
      WidgetTester tester,
    ) async {
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: _extraction(),
        ),
      );

      expect(find.byType(InteractiveViewer), findsOneWidget);
      final InteractiveViewer viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      // WHY: minScale 1.0 = 原寸より縮小しない（縮小は視認性を下げるだけ）。
      // maxScale 3.0 = プレーシェア画像の細部（判定文字など）の判読に足る倍率。
      expect(viewer.minScale, 1.0);
      expect(viewer.maxScale, 3.0);

      // 表示枠（高さ 240）は拡縮導入前の 200 から、記録詳細画面のプレビューと
      // 同じ高さへそろえた（2026-11-26 のユーザー指示「記録詳細画面のイメージです」）。
      // 拡縮は枠内トランスフォームなので、枠の高さは変わらない。
      final SizedBox frame = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.byType(InteractiveViewer),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(frame.height, 240);
    });

    testWidgets('手入力モードでも画像プレビューが InteractiveViewer で拡縮できる', (
      WidgetTester tester,
    ) async {
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
        ),
      );

      expect(find.byType(InteractiveViewer), findsOneWidget);
    });
  });

  group('曲名手入力時のライブ辞書検索（v2 UX #13）', () {
    // WHY: ユーザー実使用バグ「OCR で曲名が取れず全文字手入力すると、入力して
    // も検索されない」の修正。候補チップの表示源は OCR 時点の静的
    // songMatchResult で固定のため、手入力で再照合が走らない（リード実読確定）。
    // onSongTitleSearch（DIP 注入）で HomeScreen の matcher にライブ照合させる。

    SongMatchResult liveResult({bool autoDecided = false}) {
      return SongMatchResult(
        rawOcrText: 'manual input',
        normalizedOcrText: 'manual input',
        bestMatchNormalized: 'london sweet',
        bestMatchOriginal: 'ロンドン☆スウィート',
        bestDistance: autoDecided ? 0 : 1,
        topCandidates: <SongMatchCandidate>[
          SongMatchCandidate(
            normalizedTitle: 'london sweet',
            originalTitle: 'ロンドン☆スウィート',
            distance: autoDecided ? 0 : 1,
          ),
        ],
        autoDecided: autoDecided,
      );
    }

    testWidgets('手入力モードで曲名を入力するとライブ検索の候補チップが出る', (WidgetTester tester) async {
      final List<String> searched = <String>[];
      Future<SongMatchResult?> onSearch(String title) async {
        searched.add(title);
        return liveResult();
      }

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: null,
            extractionResult: null,
            onSongTitleSearch: onSearch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();

      // 渡された文字列で検索が呼ばれ、戻り値の候補がチップ表示される。
      expect(searched, <String>['ろんどん']);
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-0')),
        findsOneWidget,
      );
      expect(find.text('曲名候補（タップで入力）'), findsOneWidget);
      expect(find.text('ロンドン☆スウィート'), findsOneWidget);
    });

    testWidgets('通常モードでも曲名を入力するとライブ検索の候補チップが出る', (WidgetTester tester) async {
      final List<String> searched = <String>[];
      Future<SongMatchResult?> onSearch(String title) async {
        searched.add(title);
        return liveResult();
      }

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
            onSongTitleSearch: onSearch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();

      expect(searched, <String>['ろんどん']);
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-0')),
        findsOneWidget,
      );
      expect(find.text('曲名候補（タップで入力）'), findsOneWidget);
    });

    testWidgets('曲名をクリアすると OCR 時点の候補表示へ復帰する（非回帰）', (WidgetTester tester) async {
      final List<String> searched = <String>[];
      Future<SongMatchResult?> onSearch(String title) async {
        searched.add(title);
        return liveResult();
      }

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
            songMatchResult: _undecidedMatch,
            onSongTitleSearch: onSearch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 初期状態: prefill（OCR 時点 bestMatchOriginal）＋ OCR 時点の未決定候補
      // が 2 件表示されている（chip-0/chip-1）。
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-1')),
        findsOneWidget,
      );

      // 手入力 → ライブ検索結果（候補 1 件）に切り替わる。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();
      expect(searched, <String>['ろんどん']);
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-1')),
        findsNothing,
      );

      // クリア → OCR 時点の候補表示へ復帰する。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        '',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-1')),
        findsOneWidget,
      );
    });

    testWidgets('onSongTitleSearch 未提供では現行動作のまま（ライブ検索なし）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: null,
            extractionResult: null,
            songMatchResult: _undecidedMatch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // prefill 済み → 従来どおり OCR 時点の候補チップが表示される。
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-1')),
        findsOneWidget,
      );

      // 追加入力しても候補源は変わらない（ライブ検索なし・後方互換）。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ロンドン☆スウィート改',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-1')),
        findsOneWidget,
      );
    });

    testWidgets('autoDecided=true のライブ結果でも曲名欄は書き換えず・チップ消灯のみ', (
      WidgetTester tester,
    ) async {
      final List<String> searched = <String>[];
      Future<SongMatchResult?> onSearch(String title) async {
        searched.add(title);
        return liveResult(autoDecided: true);
      }

      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: null,
            extractionResult: null,
            onSongTitleSearch: onSearch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ロンドン☆スウィート',
      );
      await tester.pumpAndSettle();

      // 自動上書き禁止: 入力値はユーザー入力のまま（ライブ結果で書き換えない・
      // 選択は必ずユーザータップ）。
      final TextField songNameField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('field-input-songName')),
      );
      expect(songNameField.controller!.text, 'ロンドン☆スウィート');
      // autoDecided=true のライブ結果 → チップ行は消灯（選択済みの視覚的完了）。
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-0')),
        findsNothing,
      );
      expect(find.text('曲名候補（タップで入力）'), findsNothing);
    });
  });

  group('手入力候補選択の DB 総ノーツリンク（v2 UX #15）', () {
    // WHY: ユーザー裁定「手入力でも総ノーツ数をリンク」（2026-11-23）。候補
    // （SongMatchCandidate）は SongEntry を持たないため、チップ選択だけでは
    // VR 検証用の総ノーツ数が解決できなかった。onSongEntryResolve（DIP 注入・
    // onSongTitleSearch と同型）で HomeScreen のマージ辞書から SongEntry を
    // 解決し、VR コンテキストへ適用する（選択リンクを最優先・OCR 自動確定値
    // はフォールバック）。レコードへの songId 永続化は本タスクのスコープ外。

    SongMatchResult liveResult() {
      return SongMatchResult(
        rawOcrText: 'manual input',
        normalizedOcrText: 'manual input',
        bestMatchNormalized: 'london sweet',
        bestMatchOriginal: 'ロンドン☆スウィート',
        bestDistance: 2,
        topCandidates: <SongMatchCandidate>[
          SongMatchCandidate(
            normalizedTitle: 'london sweet',
            originalTitle: 'ロンドン☆スウィート',
            distance: 2,
          ),
        ],
        autoDecided: false,
      );
    }

    /// 判定 4 値を入力する（合計 1700 → 総ノーツ 1000 なら VR-1 発火構成）。
    ///
    /// WHY: VR-1 は 4 値と totalNotes が揃ったときだけ発火する欠損 skip 契約
    /// （設計 §5）のため、4 値すべてを埋めて「totalNotes の有無だけで発火が
    /// 切り替わる」構成にする。
    Future<void> enterJudgments(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-cool')),
        '1200',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-great')),
        '300',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-good')),
        '180',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-bad')),
        '20',
      );
      await tester.pumpAndSettle();
    }

    // WHY: 手入力モードは判定 4 値＋曲名欄＋チップで ListView が高くなり、
    // 既定の 800x600 では曲名欄・チップがスクロール範囲外になる。テスト用に
    // ビューポートを縦に伸ばしてスクロールに依存しないタップにする
    // （実機 ≈829dp ではスクロール可能で本番挙動に影響なし・#10 と同一拡大）。
    Future<void> pumpWide(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(child));
    }

    testWidgets('手入力モードでチップ選択すると DB 総ノーツ付きで VR-1 が発火する', (
      WidgetTester tester,
    ) async {
      final Map<String, SongEntry> db = <String, SongEntry>{
        'london sweet': SongEntry(
          id: 'song-entry-1',
          title: 'ロンドン☆スウィート',
          normalizedKey: 'london sweet',
          notesCounts: <String, int>{'EX': 1000},
        ),
      };
      Future<SongMatchResult?> onSearch(String title) async => liveResult();
      Future<SongEntry?> onResolve(String normalizedTitle) async =>
          db[normalizedTitle];

      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongTitleSearch: onSearch,
          onSongEntryResolve: onResolve,
        ),
      );
      await tester.pumpAndSettle();

      // 判定 4 値入力（合計 1700）。この時点では総ノーツリンクが無いため
      // VR-1 は欠損 skip（設計 §5）で発火しない。
      await enterJudgments(tester);
      expect(find.textContaining('総ノーツ数'), findsNothing);

      // 手入力 → ライブ検索 → 候補チップ表示 → 選択。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('candidate-chip-0')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-0')));
      await tester.pumpAndSettle();

      // DB 総ノーツ（1000）と判定合計（1700）の VR-1 が 4 判定行に表示される。
      expect(find.textContaining('総ノーツ数（推定 1000）'), findsNWidgets(4));
    });

    testWidgets('チップ選択後に曲名を書き換えると総ノーツリンクが無効化される', (WidgetTester tester) async {
      final Map<String, SongEntry> db = <String, SongEntry>{
        'london sweet': SongEntry(
          id: 'song-entry-1',
          title: 'ロンドン☆スウィート',
          normalizedKey: 'london sweet',
          notesCounts: <String, int>{'EX': 1000},
        ),
      };
      Future<SongMatchResult?> onSearch(String title) async => liveResult();
      Future<SongEntry?> onResolve(String normalizedTitle) async =>
          db[normalizedTitle];

      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongTitleSearch: onSearch,
          onSongEntryResolve: onResolve,
        ),
      );
      await tester.pumpAndSettle();

      await enterJudgments(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('総ノーツ数（推定 1000）'), findsNWidgets(4));

      // 曲名を別文字へ書き換え → 選択リンク無効化 → VR-1 は消える。
      // WHY: 選択リンクは選択された曲名と一致している間のみ有効（書き換えたら
      // リンクが古い曲を指すため解除する）。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどんX',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('総ノーツ数'), findsNothing);
    });

    testWidgets('OCR 自動確定経路（チップ未選択）では従来どおり matchedSong が使われる', (
      WidgetTester tester,
    ) async {
      const SongEntry song = SongEntry(
        id: 'song-1',
        title: 'テスト曲',
        normalizedKey: 'てすときょく',
        notesCounts: <String, int>{'HYPER': 1599, 'EX': 1599},
      );
      Future<SongMatchResult?> onSearch(String title) async => null;
      Future<SongEntry?> onResolve(String normalizedTitle) async => null;

      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: _pageResult(),
          extractionResult: inconsistentExtraction(),
          matchedSong: song,
          onSongTitleSearch: onSearch,
          onSongEntryResolve: onResolve,
        ),
      );
      await tester.pumpAndSettle();

      // 選択リンクは未選択のまま → フォールバック widget.matchedSong（非回帰）。
      expect(find.textContaining('総ノーツ数（推定 1599）'), findsNWidgets(4));
    });

    testWidgets('onSongEntryResolve が null を返すとリンクなしで VR は発火しない', (
      WidgetTester tester,
    ) async {
      Future<SongMatchResult?> onSearch(String title) async => liveResult();
      Future<SongEntry?> onResolve(String normalizedTitle) async => null;

      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongTitleSearch: onSearch,
          onSongEntryResolve: onResolve,
        ),
      );
      await tester.pumpAndSettle();

      await enterJudgments(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        'ろんどん',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-0')));
      await tester.pumpAndSettle();

      // 解決失敗（null）は従来どおりリンクなし・VR-1 は欠損 skip で発火しない。
      expect(find.textContaining('総ノーツ数'), findsNothing);
    });
  });

  group('v2 機能 A：クリアメダル入力 UI', () {
    // WHY: ChoiceChip の「未設定」チップで解除経路を確保（リード裁定 2026-11-23）。
    // テスト 4 は「選択 → 解除 → 未設定保存」の経路を通ることで解除動作を固定する。
    Future<void> pumpWide(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(child));
    }

    testWidgets('メダル選択 → 保存 → 記録の clearMedal に反映（保存値の固定）', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
        ),
      );
      await tester.pumpAndSettle();

      // 判定欄を入力（保存ガードを回避）。
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '98108',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-cool')),
        '1200',
      );
      await tester.pumpAndSettle();

      // メダル「クリア」を選択。
      await tester.tap(find.byKey(const ValueKey<String>('medal-clear')));
      await tester.pumpAndSettle();

      // 保存ボタンをタップ。
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();

      // 保存値の clearMedal が ClearMedalCategory.clear に固定される。
      expect(repository.createdDrafts.length, 1);
      expect(
        repository.createdDrafts.last.clearMedal,
        ClearMedalCategory.clear,
      );
    });

    testWidgets('BAD=0 & メダル=クリア選択 → VR-4 発火（不整合）', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '98108',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-bad')),
        '0',
      );
      await tester.pumpAndSettle();

      // メダル「クリア」を選択 → BAD=0 と不整合（VR-4 発火）。
      // WHY: VR-4 は双方向（play_record_validator.dart L145/L152）。BAD=0 は FC 系のみ許容。
      await tester.tap(find.byKey(const ValueKey<String>('medal-clear')));
      await tester.pumpAndSettle();
      expect(find.textContaining('BAD=0'), findsOneWidget);

      // メダル「フルコンボ」を選択 → BAD=0 と互換（VR-4 不発）。
      await tester.tap(
        find.byKey(const ValueKey<String>('medal-fullComboFamily')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('BAD=0'), findsNothing);
    });

    testWidgets('BAD>0 & メダル=fullComboFamily 選択 → VR-4 警告表示', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '98108',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-bad')),
        '1',
      );
      await tester.pumpAndSettle();

      // メダル「フルコンボ」を選択 → BAD>0 と不整合（VR-4 発火）。
      // メッセージは "フルコンボ系メダルなのに BAD が 0 ではありません"（validator L149）。
      await tester.tap(
        find.byKey(const ValueKey<String>('medal-fullComboFamily')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('BAD が 0'), findsOneWidget);
    });

    testWidgets('メダル未設定（null）保存 → VR-4 不発・非回帰', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          playRecordRepository: repository,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        '98108',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-bad')),
        '0',
      );
      await tester.pumpAndSettle();

      // メダル「フルコンボ」を選択 → 解除（未設定チップを再タップ）。
      await tester.tap(
        find.byKey(const ValueKey<String>('medal-fullComboFamily')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('medal-unset')));
      await tester.pumpAndSettle();

      // メダル未設定のまま保存 → VR-4 不発、clearMedal は null。
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.createdDrafts.length, 1);
      expect(repository.createdDrafts.last.clearMedal, isNull);
      expect(find.textContaining('BAD=0'), findsNothing);
    });

    testWidgets('編集画面でメダル変更 → 記録更新 + 一覧/詳細画面の表示反映', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['rec-edit-medal'] = PlayRecordDraft(
          songName: '編集テスト曲',
          score: '90000',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ).toPlayRecord(id: 'rec-edit-medal', resultImagePath: 'dummy.png');

      await pumpWide(
        tester,
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          existingRecordId: 'rec-edit-medal',
          playRecordRepository: repository,
          appBarTitle: 'スコア修正',
        ),
      );
      await tester.pumpAndSettle();

      // 初期状態: clearMedal は null（未設定）。
      expect(repository.store['rec-edit-medal']!.clearMedal, isNull);

      // メダル「クリア」を選択。
      await tester.tap(find.byKey(const ValueKey<String>('medal-clear')));
      await tester.pumpAndSettle();

      // 保存 → update() 呼び出し。
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.updatedRecords.containsKey('rec-edit-medal'), isTrue);
      expect(repository.updatedRecords['rec-edit-medal']!.clearMedal, 'clear');
    });
  });

  group('曲名欄と数値欄の左右 padding の一致（01a2106d-b0c1）', () {
    testWidgets('曲名欄の Container padding は数値欄と一致する', (
      WidgetTester tester,
    ) async {
      // WHY: _SongNameFieldRow だけ Container に horizontal: 8 を持っており、
      // 数値欄より左右 8px 内側に縮んで「曲名欄だけ右にずれて見える」状態に
      // なっていた。行ごとの左右 padding が揃っていることを固定する。
      tester.view.physicalSize = const Size(1080, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
          ),
        ),
      );

      EdgeInsets? paddingOf(String id) {
        final Container container = tester.widget<Container>(
          find.byKey(ValueKey<String>('field-row-$id')),
        );
        return container.padding as EdgeInsets?;
      }

      final EdgeInsets? songName = paddingOf('songName');
      expect(
        songName,
        const EdgeInsets.symmetric(vertical: 2),
        reason: '曲名欄も数値欄と同じ上下 2・左右 0 の padding であるべき',
      );
      for (final String id in <String>[
        'score',
        'great',
        'good',
        'bad',
        'maxCombo',
        'level',
      ]) {
        expect(
          paddingOf(id),
          songName,
          reason: 'field-row-$id と曲名欄の padding が一致するべき',
        );
      }
    });
  });

  // 2026-11-26 のユーザー指示「スコア入力画面、編集画面、確認画面のいずれでも、
  // 読み込んだ画像を一番上に配置してください。記録詳細画面のイメージです」。
  //
  // 3 画面はいずれもこの OcrResultScreen の別モード（pageResult あり = 確認/編集、
  // pageResult なし = スコア入力）なので、どのモードでも画像が先頭に来ることを
  // 位置（dy）で固定する。
  group('読み込んだ画像は常に先頭', () {
    /// 画像プレビュー（Image.file）の上端 y。
    double imageTop(WidgetTester tester) {
      final Finder image = find.byType(Image);
      expect(image, findsOneWidget, reason: '画像プレビューが 1 つだけ出ている');
      return tester.getTopLeft(image).dy;
    }

    testWidgets('確認・編集画面（pageResult あり）でも画像が先頭', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _pageResult(),
            extractionResult: _extraction(),
          ),
        ),
      );

      final double top = imageTop(tester);
      expect(top, lessThan(tester.getTopLeft(find.text('曲名')).dy));
      expect(top, lessThan(tester.getTopLeft(find.text('スコア')).dy));
    });

    testWidgets('スコア入力画面（pageResult なし）でも画像が先頭', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(OcrResultScreen(imageFile: File('dummy.png'))),
      );

      final double top = imageTop(tester);
      expect(top, lessThan(tester.getTopLeft(find.text('曲名')).dy));
      expect(top, lessThan(tester.getTopLeft(find.text('スコア')).dy));
    });

    testWidgets('要素 0 件でも画像が先頭で、その下に通知が出る', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          OcrResultScreen(
            imageFile: File('dummy.png'),
            pageResult: _emptyPageResult(),
          ),
        ),
      );

      final double top = imageTop(tester);
      final Finder notice = find.textContaining('テキストは検出されませんでした');
      expect(notice, findsOneWidget);
      expect(top, lessThan(tester.getTopLeft(notice).dy));
    });
  });
}
