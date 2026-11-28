// HomeScreen と OcrResultScreen の手入力候補選択 → VR 検証リンクの結合テスト
//（v2 UX #15）。
//
// 網羅:
// (a) 手入力候補選択で DB 総ノーツが VR 検証へリンクされる（チップ選択 →
//     onSongEntryResolve → VR-1 が DB 総ノーツ付きで発火）
//
// なお本ファイルは home_screen_test.dart と分離してある。
// WHY: flutter test はテストファイル単位で isolate を分ける。同一ファイル内で
// pipeline.run を完走したテストの後に本テストを続けると、FakeAsync zone を
// またいだ rootBundle/アンカーパックのキャッシュ Future の応答待ちで asset
// ロードが詰まり OCR run が完了しない flutter_test の挙動（2026-11-23 確認・
// runAsync ポールの長さ延長でも解消せず）があるため、単独 isolate で走らせる。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

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
import 'test_image_helper.dart';
import 'root_bundle_warmup.dart';

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
  setUpAll(warmRootBundleAssets);
  testWidgets('手入力候補選択で DB 総ノーツが VR 検証へリンクされる（v2 UX #15）', (
    WidgetTester tester,
  ) async {
    // WHY(v2 UX #15・ユーザー裁定「手入力でも総ノーツ数をリンク」2026-11-23):
    // HomeScreen → OcrResultScreen への onSongEntryResolve 配線と、チップ選択
    // → VR-1 発火（DB 総ノーツ付き）の結合を検証する。候補（SongMatchCandidate）
    // は SongEntry を持たないため、配線がなければチップ選択だけでは VR 検証用の
    // 総ノーツ数が解決できない（本テストの red になる）。
    final _SwappableSongRepository songRepository = _SwappableSongRepository(
      <SongEntry>[
        SongEntry(
          id: 'live-entry',
          title: 'テスト曲A',
          normalizedKey: normalizeSongTitle('テスト曲A'),
          notesCounts: <String, int>{'EX': 1000},
        ),
      ],
    );
    final File image = createTestImageFile();

    // WHY: 寸法を持つ 1 要素の fake（extraction を通しフィールド欄を出す）。
    // onRecognizeRegion は実アンカーパック読み込み成功時に領域再 OCR が発火し
    // 得るため空結果を返す（既定 fake は UnimplementedError）。#13-F テストと
    // 同一パターン。
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

    // WHY: パイプライン内のアンカーパック読み込みとライブ検索の seed ロードは
    // rootBundle（実 I/O）で FakeAsync 下では進まないため、runAsync で実非同期の
    // 完了を待ってから pump する。アセット読み込みは環境負荷で完了時間が揺れる
    // ため余裕を持たせる。
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: ocrEngine,
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          imagePicker: _FakeImagePicker(XFile(image.path)),
          mainSongRepository: songRepository,
        ),
      ),
    );
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

    // WHY: 判定 4 値＋曲名欄＋チップで画面が高くなるため、テスト用にビュー
    // ポートを縦に伸ばしてスクロールに依存しないタップにする（#10・#12 と
    // 同一拡大・実機 ≈829dp ではスクロール可能で本番挙動に影響なし）。
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 判定 4 値入力（合計 1700）。選択前は総ノーツリンクなし → VR-1 は欠損 skip。
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
    expect(find.textContaining('総ノーツ数'), findsNothing);

    // 手入力 → ライブ検索 → チップ表示 → 選択 → VR-1 発火（DB 総ノーツ 1000）。
    // WHY: ライブ検索の seed ロードは rootBundle（実 I/O）で FakeAsync 下では
    // 進まないため、runAsync で実非同期の完了を待ってから pump する。
    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'テスト曲ABC',
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
    expect(arrived, isTrue, reason: 'ライブ検索が完了していない（seed ロード待ち等）');
    await tester.tap(find.byKey(const ValueKey<String>('candidate-chip-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('総ノーツ数（推定 1000）'), findsNWidgets(4));
  });
}
