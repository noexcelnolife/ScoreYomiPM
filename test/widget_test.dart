// 最小UIフローのビルド検証テスト。
//
// ホーム画面が表示され、プレーシェア画像選択ボタンが存在することを検証する。
// OCR 実行部分は platform channel 依存（ML Kit / image_picker）のため、
// このテストでは対象外とする。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/main.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/platform/platform_capabilities.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/sharing_intent_receiver.dart';

import 'fake_play_record_repository.dart';
import 'root_bundle_warmup.dart';

/// テスト用の空実装エンジン（DIP 注入の確認も兼ねる）。
///
/// ビルド検証テストでは OCR を実行しないため、全メソッドは未実装のままでよい。
class _FakeOcrEngine implements OcrEngine {
  @override
  Future<OcrPageResult> recognize(Uint8List encodedImageBytes) => throw UnimplementedError();

  @override
  Future<OcrPageResult> recognizeRegion(
    Uint8List encodedImageBytes,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    // WHY 追加（docs/st5_f2_g_contrast_preprocess_design_confirmation_
    // 2026-11-22.md・docs コミット 18b2111・リード承認済み）: OcrEngine
    // インターフェースに狭帯前処理再試行フラグが追加されたため（本 fake
    // では使用しない・シグネチャ追従のみ）。
    bool contrastRetry = false,
  }) => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

/// smoke test 用の SongDatabaseService fake（DIP 注入の確認も兼ねる）。
///
/// ホーム画面の表示確認のみのため、更新処理は upToDate を返すだけでよい。
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

void main() {
  setUpAll(warmRootBundleAssets);
  testWidgets('ホーム画面にプレーシェア画像選択ボタンが表示される', (WidgetTester tester) async {
    await tester.pumpWidget(
      ScoremanApp(
        capabilities: const LocalCapabilities(),
        ocrEngine: _FakeOcrEngine(),
        songDatabaseService: _FakeSongDatabaseService(),
        playRecordRepository: FakePlayRecordRepository(),
        mainSongRepository: null,
        additionalSongRepository: null,
        sharingIntentReceiver: SharingIntentReceiver(),
      ),
    );

    // v4 案1（docs/v4_home実用化_design_2026-11-23.md §2.1）: （PoC）表記を
    // 除去し、ユーザー決定のアプリ名「スコアヨミPM」に統一する（2026-11-24）。
    expect(find.text('スコアヨミPM'), findsOneWidget);
    // v3（01a20785-a302）: 入口ボタンは「画像を取り込む」（種別選択シートを開く）
    // に変わった（WHY: 契約更新・アイコンは photo_library_outlined のまま）。
    expect(find.text('画像を取り込む'), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
  });
}
