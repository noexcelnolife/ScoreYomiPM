// ホーム画面の能力分岐（Web / 端末）のテスト。
//
// 検証対象:
// (1) Web 相当（canPickImages=true / canCaptureWithCamera=false）:
//     「画像を取り込む」が出て、旧注記（画像からの読み取り非対応）は出ない
// (2) Web 相当: 種別選択シートに「ギャラリーから選択」は出るが「カメラで撮影」は出ない
// (3) Web 相当: シートの「写真なしで手入力」からスコア手入力画面へ到達できる
// (4) Web 相当: 曲データベース更新の節（収録曲辞書）が出ない
// (5) 端末相当（LocalCapabilities）: 「画像を取り込む」と注記なし、Android では撮影行も出る
//
// WHY(旧注記の完全一致を見るか): ブラウザ版でも画像からの読み取りが動くように
// なったため、この注記は Web では**出てはいけない**文字列になった。文言が
// 復活すると「実行できるのに実行できないと案内する」状態に戻るので、
// 確定文字列そのものを findsNothing で固定する。

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

/// 画像を取り込めない環境向けの注記（Web では出ない）。
const String _unsupportedNote =
    'この環境は画像からの読み取りに対応していません。'
    '記録は手入力か、バックアップの復元で追加してください';

class _FakeSongDatabaseService extends SongDatabaseService {
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

/// 「画像を取り込む」から種別選択シートを開く。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('画像を取り込む'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(warmRootBundleAssets);

  group('Web 相当の能力（WebCapabilities）', () {
    testWidgets('画像取り込みの入口があり、非対応の注記は出ない', (WidgetTester tester) async {
      await _pumpHome(tester, const WebCapabilities());

      // WHY: ブラウザ版でも OCR は動く（PaddleOCR.js を同梱）。取り込みの
      // 入口を閉じると、動くはずの機能を利用者から隠すことになる。
      expect(find.text('画像を取り込む'), findsOneWidget);
      expect(find.text(_unsupportedNote), findsNothing);
      expect(find.text('記録を追加'), findsNothing);
    });

    testWidgets('種別選択シートに撮影行は出ないが、ギャラリー行は出る', (WidgetTester tester) async {
      await _pumpHome(tester, const WebCapabilities());
      await _openSheet(tester);

      expect(
        find.byKey(const ValueKey<String>('species-row-result-gallery')),
        findsOneWidget,
      );
      // WHY: テスト環境の既定 platform は Android。capability を見ていなければ
      // 撮影行が出てしまうので、この findsNothing が capability gate の証明になる。
      expect(
        find.byKey(const ValueKey<String>('species-row-result-camera')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('species-row-lively-camera')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('species-row-lively-gallery')),
        findsOneWidget,
      );
      // WHY: ブラウザが開くのはファイル選択なので、呼び名もそれに合わせる。
      expect(find.text('ファイルを選択'), findsNWidgets(2));
      expect(find.text('ギャラリーから選択'), findsNothing);
    });

    testWidgets('シートの手入力からスコア手入力画面へ到達できる', (WidgetTester tester) async {
      await _pumpHome(tester, const WebCapabilities());
      await _openSheet(tester);

      // WHY(ensureVisible か): シートは 800x600 のテスト面より縦に長く、
      // 最下段の「写真なしで手入力」は初期表示で画面外にある。
      final Finder manualRow = find.byKey(
        const ValueKey<String>('species-row-manual-entry'),
      );
      await tester.ensureVisible(manualRow);
      await tester.pumpAndSettle();
      await tester.tap(manualRow);
      await tester.pumpAndSettle();

      // WHY 手入力を残すか: 写真が読めない場面（ブレ・欠け）でも記録を増やす
      // 手段が要る。OcrResultScreen の pageResult 無しモードがそのまま使える。
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
    testWidgets('従来どおり画像取り込みの入口があり、非対応の注記は出ない', (
      WidgetTester tester,
    ) async {
      await _pumpHome(tester, const LocalCapabilities());

      expect(find.text('画像を取り込む'), findsOneWidget);
      expect(find.text(_unsupportedNote), findsNothing);
      expect(find.text('記録を追加'), findsNothing);
    });

    testWidgets('Android では撮影行が出る（既定の canCaptureWithCamera=true を保つ）', (
      WidgetTester tester,
    ) async {
      await _pumpHome(tester, const LocalCapabilities());
      await _openSheet(tester);

      // WHY: 能力フラグを渡し忘れた画面で撮影入口が黙って消えないことを
      // ここで固定しておく（既定値 true の意図）。
      expect(
        find.byKey(const ValueKey<String>('species-row-result-camera')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('species-row-lively-camera')),
        findsOneWidget,
      );
      // 端末では従来どおりの呼び名のまま。
      expect(find.text('ギャラリーから選択'), findsNWidgets(2));
      expect(find.text('ファイルを選択'), findsNothing);
    });

    testWidgets('収録曲辞書の節が出る', (WidgetTester tester) async {
      await _pumpHome(tester, const LocalCapabilities());

      expect(find.text('収録曲辞書'), findsOneWidget);
    });
  });
}
