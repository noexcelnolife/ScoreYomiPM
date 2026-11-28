// ホーム画面の能力分岐（Web / 端末）のテスト。
//
// 検証対象:
// (1) Web 相当（canCaptureImages=false）: 注記文言が計画 §6.4 の確定文字列と
//     完全一致し、「画像を取り込む」が消え、代わりに「記録を追加」が出る
// (2) Web 相当: 「記録を追加」からスコア手入力画面へ到達できる
// (3) Web 相当: 曲データベース更新の節（収録曲辞書）が出ない
// (4) 端末相当（LocalCapabilities）: 従来どおり「画像を取り込む」と注記なし
//
// WHY 文言の完全一致を見るか: この注記は「この環境では何ができないか」を
// 利用者へ伝える唯一の説明で、言い回しが変わると実行できない操作を案内して
// しまう。計画で確定した文字列をそのまま固定する。

// WHY: この環境の Flutter では package:flutter/material.dart が非推奨で
// material_ui が正規導入（既存テストの import 規約に合わせる）。
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/platform/platform_capabilities.dart';
import 'package:scoreyomipm/platform/web_capabilities.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'root_bundle_warmup.dart';

/// 計画 §6.4 の確定文字列（改行なしの 1 文）。
const String _webNote =
    'ブラウザ版は画像からの読み取りに対応していません。'
    '記録は手入力か、バックアップの復元で追加してください';

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

Future<void> _pumpHome(
  WidgetTester tester,
  PlatformCapabilities capabilities,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        capabilities: capabilities,
        ocrEngine: FakeOcrEngine(
          onRecognize: (_) async => const OcrPageResult.empty(),
        ),
        songDatabaseService: _FakeSongDatabaseService(),
        playRecordRepository: FakePlayRecordRepository(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(warmRootBundleAssets);

  group('Web 相当の能力（WebCapabilities）', () {
    testWidgets('注記が確定文字列と完全一致し、画像取り込みの入口が無い', (WidgetTester tester) async {
      await _pumpHome(tester, const WebCapabilities());

      expect(find.text(_webNote), findsOneWidget);
      // WHY findsNothing: OCR が無い環境で「画像を取り込む」を出すと、押しても
      // 必ず失敗する入口になる（押せないボタンを残さない）。
      expect(find.text('画像を取り込む'), findsNothing);
      expect(find.text('記録を追加'), findsOneWidget);
    });

    testWidgets('「記録を追加」からスコア手入力画面へ到達できる', (WidgetTester tester) async {
      await _pumpHome(tester, const WebCapabilities());

      await tester.tap(find.text('記録を追加'));
      await tester.pumpAndSettle();

      // WHY 手入力を Web の主導線にするか: 画像が読めなくても記録を増やす手段が
      // 要る。OcrResultScreen の pageResult 無しモードがそのまま使える。
      expect(find.byType(OcrResultScreen), findsOneWidget);
      expect(find.text('スコア手入力'), findsOneWidget);
    });

    testWidgets('収録曲辞書の節は常に出る（Web は更新 URL 無し・追加取り込み有り）', (
      WidgetTester tester,
    ) async {
      await _pumpHome(tester, const WebCapabilities());

      // WHY: 節自体は常に描画し、能力フラグで中身を出し分ける。
      expect(find.text('収録曲辞書'), findsOneWidget);
      // ExpansionTile は折りたたみ状態なので、子ウィジェットを確認する前に開く。
      await tester.tap(find.text('収録曲辞書'));
      await tester.pumpAndSettle();

      // Web（canUpdateFromUrl=false）: URL フィールドと更新ボタンは無い。
      expect(find.byKey(const ValueKey('song-db-url-field')), findsNothing);
      expect(find.byKey(const ValueKey('song-db-update-button')), findsNothing);
      // Web（canImportJson=true）: 追加取り込みボタンと注記はある。
      expect(find.byKey(const ValueKey('song-db-import-button')), findsOneWidget);
      expect(
        find.text(
          'ブラウザ版では配信 URL からの更新はできません。JSON ファイルから追加できます。',
        ),
        findsOneWidget,
      );
    });
  });

  group('端末相当の能力（LocalCapabilities）', () {
    testWidgets('従来どおり画像取り込みの入口があり、Web 注記は出ない', (WidgetTester tester) async {
      await _pumpHome(tester, const LocalCapabilities());

      expect(find.text('画像を取り込む'), findsOneWidget);
      expect(find.text(_webNote), findsNothing);
      expect(find.text('記録を追加'), findsNothing);
    });

    testWidgets('収録曲辞書の節が出る', (WidgetTester tester) async {
      await _pumpHome(tester, const LocalCapabilities());

      expect(find.text('収録曲辞書'), findsOneWidget);
    });
  });
}
