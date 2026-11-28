// HomeScreen（FR-4: OCR 失敗時の未確定レコード自動保存・履歴導線）のテスト。
//
// 検証対象:
// (a) OcrEngineException 時に画像だけの未確定レコードが自動保存される
// (b) 自動保存時に SnackBar でユーザーへ通知される
// (c) 履歴アイコンから未確定レコード一覧へ遷移できる
// (d) OCR 成功で編集画面から戻ったとき、プレビューはクリアされる（v2 UX 改修1）
// (e) OCR run をまたぐライブ辞書キャッシュは各 run で再構築される（v2 UX #13 フォローアップ）

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'real_async_helper.dart';
import 'root_bundle_warmup.dart';
import 'test_image_helper.dart';

/// 必ず OcrEngineException を投げる OCR エンジン。
Future<OcrPageResult> _throwOnRecognize(Uint8List encodedImageBytes) async =>
    throw const OcrEngineException('テスト用OCR失敗');

class _FakeSongDatabaseService implements SongDatabaseService {
  @override
  Future<String> loadDistributionUrl() async => '';

  @override
  Future<void> saveDistributionUrl(String url) async {}

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async =>
      const SongImportResult(success: false);

  @override
  Future<SongDatabaseStatus> loadStatus() async => const SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );
}

/// pickImage の戻り値だけを制御できるフェイク。
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this._result);

  final XFile? _result;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => _result;
}

/// allSongs をテスト途中で差し替えられる SongRepository フェイク。
///
/// WHY(#13 フォローアップ): 「OCR run 1 → ライブ検索（キャッシュ構築）→ 辞書内容
/// 変更 → run 2 → ライブ検索」のシナリオを再現するため、構築後の allSongs 差し替えを
/// 許す。他メンバーは song_title_element_matcher_test.dart の既存フェイクと同形。
class _SwappableSongRepository implements SongRepository {
  _SwappableSongRepository(this.songs);

  /// 差し替え可能な楽曲リスト（テストが途中で書き換える）。
  List<SongEntry> songs;

  @override
  String get sourceName => 'fakeSwappable';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => List<SongEntry>.unmodifiable(songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final SongEntry song in songs) {
      if (song.normalizedKey == normalizedKey) {
        return song;
      }
    }
    return null;
  }

  @override
  int get length => songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) {
    return findByNormalizedKey(normalizedKey) != null;
  }
}

void main() {
  // WHY は test/root_bundle_warmup.dart を参照（複数ファイルで共有する）。
  setUpAll(warmRootBundleAssets);

  testWidgets('OCR 失敗時、画像だけの未確定レコードが自動保存され SnackBar が出る', (
    WidgetTester tester,
  ) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(onRecognize: _throwOnRecognize),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );

    // v3（01a20785-a302）: ホーム入口が種別選択シート経由に変わったため操作
    // 手順も追従する（WHY: 契約更新・期待内容は不変）。
    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HC プレーシェア'));
    await tester.pump();
    // WHY(実 I/O を待つか): 失敗時は原画像を読み出して未確定レコードとして
    // 保存する。FakeAsync 下ではその読み出しが完了しないため、実時間を進める。
    await pumpThroughRealIo(tester);

    expect(find.textContaining('OCRに失敗したため未確定レコードとして保存しました'), findsOneWidget);
    expect(repository.createdDrafts, hasLength(1));
    expect(repository.createdDrafts.single.status, PlayRecordStatus.pending);
    expect(repository.createdDrafts.single.songName, isNull);
    expect(repository.createdDrafts.single.source, PlayRecordSource.playshare);
    expect(repository.store, hasLength(1));
    expect(repository.store.values.single.resultImagePath, isNotEmpty);
    // 改修1: OCR 失敗時は編集画面へ遷移していないため、プレビューはクリアしない
    //（エラーカードと合わせて取り込み直しの文脈を保持する・リード裁定）。
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('収録曲辞書のタイトル行に総曲数の subtitle を常設する（案A）', (
    WidgetTester tester,
  ) async {
    createTestImageFile();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 折りたたみ中でも件数が見えるよう、ExpansionTile の subtitle に置く。
    expect(find.text('収録曲辞書'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('song-db-total-subtitle')),
      findsOneWidget,
    );
  });

  testWidgets('履歴アイコンから未確定レコード一覧へ遷移する', (WidgetTester tester) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('pending-records-button')),
    );
    await tester.pumpAndSettle();

    // FR-10: 遷移先は全件対象の記録一覧画面。
    expect(find.text('記録一覧'), findsOneWidget);
    expect(find.text('記録はありません'), findsOneWidget);
  });

  testWidgets('プレーシェア画像の失効ガイドを表示する（FR-8）', (WidgetTester tester) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );

    // FR-8: 画像選択ボタン直下に常設ガイド 1 行を出す（設計 §1/§2）。
    // WHY 日数で検索しないか: 失効までの日数はプレーシェア側の仕様なので、
    // アプリの文言では断定しない（2026-11-26 ユーザー変更）。
    expect(find.textContaining('プレーシェアは一定期間で見られなくなる'), findsOneWidget);
  });

  testWidgets('失効ガイド文言は確定文言どおりに表示される（FR-8・文言固定）', (WidgetTester tester) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );

    // FR-8: 文言は完全一致で固定する（変更はユーザー判断）。
    expect(find.text('プレーシェアは一定期間で見られなくなるため、お早めに取り込みください'), findsOneWidget);
  });

  testWidgets('OCR 成功で編集画面から戻ったあとは、プレビューをクリアする（v2 UX 改修1）', (
    WidgetTester tester,
  ) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          // WHY: 寸法未指定の空結果 = 領域再 OCR・抽出をスキップする成功結果。
          // 抽出内容は作り込まず、「push → 戻る」の導線だけを検証対象にする。
          ocrEngine: FakeOcrEngine(
            onRecognize: (_) async => const OcrPageResult.empty(),
          ),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
        ),
      ),
    );

    // v3（01a20785-a302）: 入口が種別選択シート経由に変わったため追従
    //（WHY: 契約更新・期待内容は不変）。
    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HC プレーシェア'));
    // WHY(pumpAndSettle を使わないか): 種別を選ぶとシートが閉じ、続けて OCR が
    // 始まって進捗スピナー（無限アニメーション）が出る。スピナーが回り続ける間は
    // pumpAndSettle がタイムアウトする。pop アニメーションぶんだけ固定で進めてから、
    // OCR 経路の実 I/O は pumpThroughRealIo で待つ。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await pumpThroughRealIo(tester);

    // OCR 成功 → 確認・編集画面へ遷移している。
    expect(find.byType(OcrResultScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    // WHY: プレビュークリアの setState は pop 完了直後のマイクロタスクで走り
    // 得るため、追加 1 フレーム描画してから検査する。
    await tester.pump();

    // 改修1: 使い終わったプレーシェア画像は 1 回の取り込みで消化される情報源。
    // 編集を終えて home へ戻ったらプレビューをクリアし、次の取り込みを阻害しない。
    expect(find.byType(Image), findsNothing);
    expect(find.text('リザルト画面を選択して\nOCRでスコアを自動読み取りします'), findsOneWidget);
  });

  testWidgets('OCR run をまたぐとライブ辞書キャッシュが再構築される（v2 UX #13 フォローアップ）', (
    WidgetTester tester,
  ) async {
    createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    // 辞書 v1: 旧曲のみ。run 1 のライブ検索がこの辞書で照合することを先に証明する。
    final _SwappableSongRepository songRepository = _SwappableSongRepository(
      <SongEntry>[
        SongEntry(
          id: 'follow-up-old',
          title: 'テスト旧曲A',
          normalizedKey: normalizeSongTitle('テスト旧曲A'),
        ),
      ],
    );

    // WHY: 寸法（imageWidth/imageHeight）を持つ 1 要素の結果。寸法が無い fake
    //（OcrPageResult.empty 等）ではパイプラインが抽出をスキップして
    // extractionResult = null となり、0 要素 + 抽出なしは空状態着地でフィールド欄
    // が出ない。要素テキストは曲名照合（seed 33 曲と距離 3 超）・フィールド抽出の
    // 双方で実質無害な数値列とする。onRecognizeRegion は実アンカーパック
    //（assets/anchors/hc_v1）読み込み成功時に領域再 OCR が発火し得るため空結果を
    // 返す（既定 fake は UnimplementedError を投げる。空結果 = 有効数値候補なし
    // → runner が全 spec 不採用 → マージはフル抽出値）。
    final FakeOcrEngine ocrEngine = FakeOcrEngine(
      onRecognize: (_) async => const OcrPageResult(
        elements: <OcrElement>[
          OcrElement(
            text: '99999',
            boundingBox: Rect.fromLTWH(0, 0, 60, 16),
            confidence: 0.9,
          ),
        ],
        fullText: '99999',
        imageWidth: 1200,
        imageHeight: 800,
      ),
      onRecognizeRegion: (
        _,
        _, {
        required OcrScript script,
        double pixelScale = 1.0,
        bool contrastRetry = false,
      }) async => const OcrPageResult(elements: <OcrElement>[], fullText: ''),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: ocrEngine,
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          imagePicker: _FakeImagePicker(XFile(createTestImageFile().path)),
          mainSongRepository: songRepository,
        ),
      ),
    );

    // WHY: パイプライン内のアンカーパック読み込みとライブ検索の seed ロードは
    // rootBundle（実 I/O）で FakeAsync 下では進まないため、runAsync で実非同期の
    // 完了を待ってから pump する（play_record_detail_screen_test.dart の再 OCR
    // 待ちと同一パターン）。
    Future<bool> runOcrAndSearch(String query) async {
      // v3（01a20785-a302）: 入口が種別選択シート経由に変わったため追従
      //（WHY: 契約更新・期待内容は不変）。
      await tester.tap(find.text('画像を取り込む'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HC プレーシェア'));
      var opened = false;
      for (var i = 0; i < 60 && !opened; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        opened = find.byType(OcrResultScreen).evaluate().isNotEmpty;
      }
      expect(opened, isTrue, reason: 'OCR run が完了していない（セットアップ要確認）');
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        query,
      );
      var arrived = false;
      for (var i = 0; i < 60 && !arrived; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        arrived = find
            .byKey(const ValueKey<String>('candidate-chip-0'))
            .evaluate()
            .isNotEmpty;
      }
      return arrived;
    }

    // run 1: 旧曲を 2 文字差（距離 2 = 候補表示・自動決定なし）で照合する。
    // ここでライブ検索機構（seed ロード + 照合 + チップ表示）の動作を証明する。
    // なお OCR 時点の候補は存在しない（songMatchResult が null または候補なし）
    // ため、チップの表示源はライブ検索結果に限定される（red-first の切りの精度向上）。
    final bool arrivedRun1 = await runOcrAndSearch('テスト旧曲ABC');
    expect(
      arrivedRun1,
      isTrue,
      reason: 'run 1 のライブ検索が完了していない（seed ロード待ち等・セットアップ要確認）',
    );
    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsOneWidget,
    );
    expect(find.text('曲名候補（タップで入力）'), findsOneWidget);
    expect(find.text('テスト旧曲A'), findsOneWidget);

    // WHY: 曲名入力済み（dirty）のまま戻ると P-6 の破棄確認ダイアログが出て
    // ホームへ戻れない。空に戻して非 dirty 化してから Back する（空入力は
    // ライブ検索を再発火させない・#13 の early return）。
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // 辞書 v2 へ差し替え（旧曲を外し新曲を入れる）。DB 更新が次 run から反映される
    // 状況の再現。
    songRepository.songs = <SongEntry>[
      SongEntry(
        id: 'follow-up-new',
        title: 'テスト新曲A',
        normalizedKey: normalizeSongTitle('テスト新曲A'),
      ),
    ];

    // run 2: 新曲を 2 文字差で照合。pipeline 側は毎 run で MergedSongRepository を
    // 再構築する（DB 更新が次 run から反映される原則）ため、ライブ検索も run 2 開始
    // 時点の辞書（v2）で照合されて新曲が候補に出るべき。
    await runOcrAndSearch('テスト新曲ABC');
    expect(
      find.byKey(const ValueKey<String>('candidate-chip-0')),
      findsOneWidget,
    );
    expect(find.text('テスト新曲A'), findsOneWidget);
  });
}
