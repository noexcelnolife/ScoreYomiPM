// PlayRecordDetailScreen（FR-11 記録詳細・FR-12 修正/削除/再OCR）のテスト。
//
// 検証対象:
// (a) 値ありレコードの全フィールド表示（難易度・メダルの常設「—」行を含む）
// (b) null 項目の表示規約（曲名→（曲名未入力）・数値→「—」・判定内訳の個別「—」）
// (c) 画像が保存先に無いときのフォールバック表示
// (d) 修正 → 手入力モード OcrResultScreen（タイトル「スコア修正」・既存値復元）
// (e) 削除 → 確認ダイアログ（confirm-delete-button は FR-4 と統一）→ 削除で詳細クローズ
// (f) 再OCR ボタンは未確定のみ表示・失敗時 SnackBar・確定では非表示
// (g) 自己ベスト判定: 同キー最高スコアのレコードに「自己ベスト」表示（FR-7）
// (h) 原画像プレビューの InteractiveViewer 拡大縮小（v2 UX #14・一覧は対象外）

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// テスト用レコードが持つ画像ファイル名。
///
/// WHY(パスではなく名前か): resultImagePath は basename だけを持ち、実体は
/// 保存先（BlobStore）にある。詳細画面は readImage(この名前) で読む。
const String _imageName = 'result.png';

/// 画像 1 枚入りの保存先を作る。
///
/// WHY(ここで画像を入れるか): レコードと画像は別々に保存されるため、
/// 画像を入れ忘れたテストは「画像が無い」経路を通ってしまう。表示の検証を
/// したいテストは必ずこれを使い、画像なしの経路は明示的に作る。
FakePlayRecordRepository _imageRepository() {
  final Uint8List bytes = createTestImageBytes();
  return FakePlayRecordRepository()..images[_imageName] = bytes;
}

/// ルート画面から詳細を push する形式のラッパー。
///
/// WHY: 削除後の詳細クローズ（pop）を実アプリと同じ経路で検証するため、
/// 詳細を root に直接置かず route 経由で開く。
Widget _wrapWithEntry({
  required PlayRecordRepository repository,
  required OcrEngine ocrEngine,
  required String recordId,
}) {
  return MaterialApp(
    home: Builder(
      builder: (BuildContext context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          PlayRecordDetailScreen.route(
            playRecordRepository: repository,
            ocrEngine: ocrEngine,
            recordId: recordId,
          ),
        ),
        child: const Text('open'),
      ),
    ),
  );
}

/// 値の揃った確定レコード。
PlayRecord _fullRecord() =>
    PlayRecordDraft(
      songName: 'テスト曲',
      score: 98108,
      cool: 1000,
      great: 500,
      good: 100,
      bad: 10,
      maxCombo: 1234,
      level: 45,
      status: PlayRecordStatus.confirmed,
      source: PlayRecordSource.playshare,
    ).toPlayRecord(
      id: 'r-1',
      resultImagePath: _imageName,
      playedAt: DateTime(2026, 11, 22, 12, 34),
    );

/// 数値・曲名がすべて未入力の未確定レコード。
PlayRecord _blankRecord() =>
    PlayRecordDraft(
      songName: null,
      status: PlayRecordStatus.pending,
      source: PlayRecordSource.playshare,
    ).toPlayRecord(
      id: 'r-2',
      resultImagePath: _imageName,
      playedAt: DateTime(2026, 11, 22, 9),
    );

/// スコアと日時を指定した確定レコード（FR-7 自己ベスト判定用）。
PlayRecord _recordWithScore({
  required String id,
  required String songName,
  required int score,
  required DateTime playedAt,
}) => PlayRecordDraft(
  songName: songName,
  score: score,
  status: PlayRecordStatus.confirmed,
  source: PlayRecordSource.playshare,
).toPlayRecord(id: id, resultImagePath: _imageName, playedAt: playedAt);

void main() {
  // WHY(シード辞書のプリロード・01a21152): 曲名入力のライブサジェスト配線により、
  // 本ファイルの「修正」系テストも結果画面でシード辞書（rootBundle）を読む。
  // rootBundle はアセット文字列を Future ごとキャッシュし、fake async ゾーン内で
  // 生成された Future は後続テストのゾーンから await しても解決が届かない
  // （home_screen_vr_link_test.dart 冒頭の既知挙動と同根）。ゾーン外で 1 度だけ
  // 読み込んでおけば、各テストは完了済み Future を待つだけで済む。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await rootBundle.loadString('assets/songs/seed_v2.json');
  });

  testWidgets('値ありレコードの全フィールドを表示する', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: _imageRepository()
          ..store['r-1'] = _fullRecord(),
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-1',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('記録詳細'), findsOneWidget);
    expect(find.text('2026/11/22 12:34'), findsOneWidget);
    expect(find.text('テスト曲'), findsOneWidget);
    expect(find.text('Lv45'), findsOneWidget);
    expect(find.text('98,108'), findsOneWidget);
    expect(
      find.text('COOL 1000 / GREAT 500 / GOOD 100 / BAD 10'),
      findsOneWidget,
    );
    expect(find.text('1234'), findsOneWidget); // MAX COMBO の値
    expect(find.text('プレーシェア'), findsOneWidget);
    // 難易度・機種・メダルの常設行（このレコードはいずれも未設定で 3 か所「—」）。
    // WHY 変更(v5 機能 A): 機種行を難易度行の直後へ追加したため「—」が
    // 2 → 3 か所になった（設計 §4.1 の表示仕様と整合）。
    expect(find.text('難易度'), findsOneWidget);
    expect(find.text('機種'), findsOneWidget);
    expect(find.text('メダル'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(3));
    expect(find.text('確定'), findsOneWidget); // status チップ
  });

  testWidgets('null 項目は規約どおりの未入力表示になる', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: _imageRepository()
          ..store['r-2'] = _blankRecord(),
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-2',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('（曲名未入力）'), findsOneWidget);
    expect(find.textContaining('COOL —'), findsOneWidget);
    expect(find.text('未確定'), findsOneWidget);
    // レベル・スコア・MAX COMBO・難易度・機種・メダルの 6 か所が「—」。
    // WHY 変更(v5 機能 A): 機種行追加で 5 → 6 か所（未記録は「—」規約は不変）。
    expect(find.text('—'), findsNWidgets(6));
  });

  testWidgets('保存先に画像が無いときはフォールバック表示になる', (WidgetTester tester) async {
    final PlayRecord record =
        PlayRecordDraft(
          songName: 'テスト曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ).toPlayRecord(
          id: 'r-3',
          resultImagePath: 'definitely-missing-image.png',
          playedAt: DateTime(2026, 11, 22),
        );
    await tester.pumpWidget(
      _wrapWithEntry(
        // WHY 画像を入れないか: このテストだけが「読めなかった」経路を通る。
        repository: FakePlayRecordRepository()..store['r-3'] = record,
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-3',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text('画像が見つかりません'), findsOneWidget);
  });

  testWidgets('修正ボタンでスコア修正モードへ遷移し既存値が復元される', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: _imageRepository()
          ..store['r-1'] = _fullRecord(),
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-1',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('edit-record-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-record-button')));
    await tester.pumpAndSettle();

    expect(find.text('スコア修正'), findsOneWidget);
    // 既存値が復元されている（FR-4 の update 経路をそのまま使う）。
    final TextField scoreField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-score')),
    );
    expect(scoreField.controller!.text, '98108');
  });

  testWidgets('削除は確認ダイアログを経由して実行され、詳細が閉じる', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = _imageRepository()
      ..store['r-1'] = _fullRecord();
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: repository,
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-1',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('delete-record-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('delete-record-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('このレコードを削除しますか？'), findsOneWidget);

    // キャンセルでは消えない。
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(repository.store, hasLength(1));

    await tester.tap(
      find.byKey(const ValueKey<String>('delete-record-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('confirm-delete-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.store, isEmpty);
    // 削除後は詳細が閉じてルートに戻る。
    expect(find.text('記録詳細'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('再OCR は未確定のみ表示され、失敗時は SnackBar で通知する', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = _imageRepository()
      ..store['r-2'] = _blankRecord();
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: repository,
        ocrEngine: FakeOcrEngine(
          onRecognize: (_) => throw const OcrEngineException('再OCRテスト失敗'),
        ),
        recordId: 'r-2',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('rerun-ocr-button')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rerun-ocr-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('rerun-ocr-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('再OCRに失敗しました'), findsOneWidget);
    // 失敗してもレコードは未確定のまま残る。
    expect(repository.store['r-2'], isNotNull);
  });

  testWidgets('確定レコードでは再OCR ボタンを表示しない', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: _imageRepository()
          ..store['r-1'] = _fullRecord(),
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-1',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('rerun-ocr-button')),
      findsNothing,
    );
  });

  testWidgets('同キー最高スコアのレコードは「自己ベスト」を表示する（FR-7）', (WidgetTester tester) async {
    final FakePlayRecordRepository repository = _imageRepository()
      ..store['r-1'] = _recordWithScore(
        id: 'r-1',
        songName: 'テスト曲',
        score: 98108,
        playedAt: DateTime(2026, 11, 20, 10),
      )
      ..store['r-2'] = _recordWithScore(
        id: 'r-2',
        songName: 'テスト曲',
        score: 99000,
        playedAt: DateTime(2026, 11, 22, 10),
      );
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: repository,
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-2',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('自己ベスト'), findsOneWidget);
  });

  testWidgets('同キーで最高スコアでないレコードは「自己ベスト」を表示しない（FR-7）', (
    WidgetTester tester,
  ) async {
    final FakePlayRecordRepository repository = _imageRepository()
      ..store['r-1'] = _recordWithScore(
        id: 'r-1',
        songName: 'テスト曲',
        score: 98108,
        playedAt: DateTime(2026, 11, 20, 10),
      )
      ..store['r-2'] = _recordWithScore(
        id: 'r-2',
        songName: 'テスト曲',
        score: 99000,
        playedAt: DateTime(2026, 11, 22, 10),
      );
    await tester.pumpWidget(
      _wrapWithEntry(
        repository: repository,
        ocrEngine: FakeOcrEngine(),
        recordId: 'r-1',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('自己ベスト'), findsNothing);
  });

  group('再 OCR 経路の matchedSong 渡し（ビルド検証テスト 修正①）', () {
    // WHY: 一次 OCR（home_screen）は pipeline.run() の context から
    // matchedSong を結果画面へ渡すが、再 OCR 経路（_rerunOcr）だけ
    // 渡していなかった → VR-1/VR-3 が再 OCR 確認画面で常に skip になる
    // 非対称（段階 B 機能の経路カバレッジ欠落）。この red テストで
    // 再 OCR 経路でも matchedSong が渡ることを固定する。
    //
    // 検証手段: matchedSong の唯一の観測点は VR-1/VR-3 の発火。
    // full-page に判定ラベル+値を配置し、判定合計（1235）が seed
    // harmonia の総ノーツ数（推定 1036）を超える構成で VR-1 を
    // 意図的に発火させ、4 判定行のメッセージを確認する。

    testWidgets('再 OCR の結果画面でも VR-1 が発火する', (WidgetTester tester) async {
        await tester.pumpWidget(
        _wrapWithEntry(
          repository: _imageRepository()
            ..store['r-2'] = _judgmentPendingRecord(),
          ocrEngine: FakeOcrEngine(
            onRecognize: (_) async => _judgmentFullPageResult(),
            onRecognizeRegion: (
              _,
              _, {
              required OcrScript script,
              double pixelScale = 1.0,
              bool contrastRetry = false,
            }) async => _harmoniaRegionResult(),
          ),
          recordId: 'r-2',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('rerun-ocr-button')));
      // WHY: パイプライン内の seed（rootBundle）・アンカーパック読み込みは
      // FakeAsync 下では進まないため、runAsync で実非同期の完了を待ってから
      // pumpAndSettle する（既存テストの画像読み込み待ちと同一パターン）。
      bool arrived = false;
      for (int i = 0; i < 60 && !arrived; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        arrived = find.byType(OcrResultScreen).evaluate().isNotEmpty;
      }
      await tester.pumpAndSettle();

      // 前提確認: 再 OCR が成功して結果画面へ着地したこと。ここで失敗して
      // いたら VR-1 断言の前にセットアップ要修正。
      expect(find.byType(OcrResultScreen), findsOneWidget);
      // WHY: 通常モード Scaffold の AppBar タイトルは const 'OCR結果確認'
      // （appBarTitle 上書きは手入力モード専用）のため、着地確認は型で行う。
      expect(find.textContaining('総ノーツ数（推定 1036）'), findsNWidgets(4));
    });
  });

  group('詳細画面の画像拡大縮小（v2 UX #14・ユーザー裁定 2026-11-23）', () {
    testWidgets('原画像プレビューが InteractiveViewer で拡縮でき、表示枠の高さは不変', (
      WidgetTester tester,
    ) async {
        await tester.pumpWidget(
        _wrapWithEntry(
          repository: _imageRepository()
            ..store['r-1'] = _fullRecord(),
          ocrEngine: FakeOcrEngine(),
          recordId: 'r-1',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // InteractiveViewer で拡大縮小・パンができる。
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final InteractiveViewer viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      // WHY: #12（ocr_result_screen _ImagePreview）と同一条件の統一原則。
      // minScale 1.0 = 原寸より縮小しない・maxScale 3.0 = 判定文字の判読に足る倍率。
      expect(viewer.minScale, 1.0);
      expect(viewer.maxScale, 3.0);

      // 表示枠（高さ 240）は拡縮導入前と同じで、変換は枠内のみ。
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
  });
}

/// 判定ラベル+値を配置した full-page OCR 結果。
///
/// 判定合計 = 975 + 58 + 2 + 200 = 1235。seed harmonia の totalNotes
/// 1036 を超えるため VR-1 が発火する。配置は field_extractor のアンカー
/// 検出（ラベル cx≈0.139）と値窓に一致させる — 判定系 dx [0.05,0.20]・
/// BAD [0.10,0.25]・dy 許容 0.012・行間 50px（ocr_pipeline_test の
/// GOOD 14 パターンと同一の隣接構成、BAD のみ窓が右寄りなので
/// dx≈0.19 の列に置く）。
OcrPageResult _judgmentFullPageResult() {
  const List<String> labels = <String>['COOL', 'GREAT', 'GOOD', 'BAD'];
  const List<String> values = <String>['975', '58', '2', '200'];
  final List<OcrElement> elements = <OcrElement>[];
  for (int i = 0; i < labels.length; i++) {
    final double top = 100 + i * 50.0;
    elements.add(
      OcrElement(
        text: labels[i],
        boundingBox: Rect.fromLTWH(100, top, 100, 10),
        confidence: 0.99,
      ),
    );
    // 値の x 位置: 判定系 3 種はラベル右隣（dx≈0.065）、BAD は窓中心
    // dx≈0.19（x 335〜375）。
    final double valueLeft = labels[i] == 'BAD' ? 335 : 200;
    elements.add(
      OcrElement(
        text: values[i],
        boundingBox: Rect.fromLTWH(valueLeft, top, 40, 10),
        confidence: 0.99,
      ),
    );
  }
  return OcrPageResult(
    fullText: 'COOL 975 GREAT 58 GOOD 2 BAD 200',
    elements: elements,
    imageWidth: 1080,
    imageHeight: 1920,
  );
}

/// 判定値を持つ未確定レコード。
///
/// WHY: 再 OCR 経路では既存レコード復元（FR-4）が既存値をコントローラへ
/// 上書きするため、抽出値と同一の判定値を持つレコードを用意する。これで
/// 結果画面の判定 4 項目が値を持ち、VR-1 の発火条件（判定 4 値 +
/// totalNotes）が揃う。判定合計 1235 > seed harmonia totalNotes 1036。
PlayRecord _judgmentPendingRecord() {
  return PlayRecord(
    id: 'r-2',
    playedAt: DateTime(2026, 11, 22, 12),
    songName: null,
    score: null,
    cool: 975,
    great: 58,
    good: 2,
    bad: 200,
    maxCombo: null,
    level: null,
    status: PlayRecordStatus.pending,
    source: PlayRecordSource.playshare,
    resultImagePath: _imageName,
  );
}

/// songTitle 帯の領域 OCR 応答（全領域共通 — ocr_pipeline_test の
/// _engineWithSongTitle と同一パターン）。seed harmonia に 1 文字差なく
/// 一致し auto 決定する。
OcrPageResult _harmoniaRegionResult() {
  return OcrPageResult(
    fullText: 'Harmonia',
    elements: <OcrElement>[
      OcrElement(
        text: 'Harmonia',
        boundingBox: Rect.fromLTWH(10, 10, 190, 20),
        confidence: 0.9,
      ),
    ],
    imageWidth: 190,
    imageHeight: 20,
  );
}
