// HomeScreen 共有インテント受付（v2 機能 F・FR-1）の結合テスト。
//
// 検証対象:
// (a) 冷起動: getInitialImagePath に初期パスがある → OCR 成功 → OcrResultScreen 遷移
// (b) 温起動: imagePathStream にパスが流れる → OCR 成功 → OcrResultScreen 遷移
// (c) 温起動: OCR 失敗 → 未確定レコード自動保存（FR-4）＋エラー表示・遷移しない
//
// WHY: 共有インテント経路は imagePicker を経由しないため、picker テストとは
// 別ファイルで receiver をスタブ化した導線テストにする。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// WHY: この環境の Flutter では package:flutter/material.dart が非推奨で
// material_ui が正規導入（既存テスト・lib 側の import 規約に合わせる）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/sharing_intent_receiver.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'real_async_helper.dart';
import 'test_image_helper.dart';
import 'root_bundle_warmup.dart';

/// 必ず OcrEngineException を投げる OCR エンジン（home_screen_test.dart と同形）。
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
  Future<SongImportResult> importAdditionalJson(String sourceFilePath) async =>
      const SongImportResult(success: false);

  @override
  Future<SongDatabaseStatus> loadStatus() async => const SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );
}

/// 共有インテント受付のテスト用スタブ。
///
/// WHY: 実クラスの imagePathStream getter は ReceiveSharingIntent のプラット
/// チャンネルに接続するため、テストでは broadcast StreamController で差し替える。
/// getInitialImagePath も initialPath フィールドに固定する。
class _StubSharingIntentReceiver extends SharingIntentReceiver {
  _StubSharingIntentReceiver({this.initialPath});

  /// 冷起動テストで getInitialImagePath が返すパス（null = 初期インテントなし）。
  final String? initialPath;

  /// 温起動テストで imagePathStream から流すパスの送信口。
  final StreamController<String> streamController =
      StreamController<String>.broadcast();

  @override
  Future<String?> getInitialImagePath() async => initialPath;

  @override
  Stream<String> get imagePathStream => streamController.stream;

  @override
  void cancel() {
    // WHY: HomeScreen の dispose が cancel() を呼ぶ。実クラスはプラットフォーム
    // 接続の購読解放を担うが、スタブではストリーム閉鎖のみで十分。
    if (!streamController.isClosed) {
      unawaited(streamController.close());
    }
  }
}

void main() {
  setUpAll(warmRootBundleAssets);
  testWidgets('冷起動: 初期共有画像あり → OCR 成功 → OcrResultScreen へ遷移する', (
    WidgetTester tester,
  ) async {
    createTestImageFile();
    final _StubSharingIntentReceiver receiver = _StubSharingIntentReceiver(
      initialPath: createTestImageFile().path,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          // WHY: 寸法未指定の空結果 = 領域再 OCR・抽出をスキップする成功結果
          //（home_screen_test.dart の遷移テストと同形）。検証対象は共有導線の遷移のみ。
          ocrEngine: FakeOcrEngine(
            onRecognize: (_) async => const OcrPageResult.empty(),
          ),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          sharingIntentReceiver: receiver,
        ),
      ),
    );

    // WHY: initState の getInitialImagePath() は Future で解決するため、
    // まず 1 フレーム進めてマイクロタスクを流し、その後遷移アニメーションを
    // settle させる（OCR 成功テストと同じ pump 順）。
    // WHY(実 I/O を回すか): OCR 経路は原画像の readAsBytes を伴う。FakeAsync の
    // 下では完了しないため、実時間を進めて遷移まで到達させる。
    await tester.pump();
    await pumpThroughRealIo(tester);

    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('温起動: imagePathStream の共有 → OCR 成功 → OcrResultScreen へ遷移する', (
    WidgetTester tester,
  ) async {
    // WHY(実ファイルを渡すか): 共有インテントが渡してくるのは実ファイルで、
    // 保存経路はその readAsBytes を伴う。存在しないパスでは「読めなかった」
    // 場合しか検証できない。
    final File successImage = createTestImageFile();
    final _StubSharingIntentReceiver receiver = _StubSharingIntentReceiver();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(
            onRecognize: (_) async => const OcrPageResult.empty(),
          ),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          sharingIntentReceiver: receiver,
        ),
      ),
    );

    // 温起動: アプリがメモリ上にある状態で共有された画像がストリームへ流れる。
    receiver.streamController.add(successImage.path);
    // WHY(実 I/O を回すか): OCR 経路は原画像の readAsBytes を伴う。FakeAsync の
    // 下では完了しないため、実時間を進めて遷移まで到達させる。
    await tester.pump();
    await pumpThroughRealIo(tester);

    expect(find.byType(OcrResultScreen), findsOneWidget);
  });

  testWidgets('温起動: OCR 失敗 → 未確定レコード自動保存（FR-4）＋エラー表示・遷移しない', (
    WidgetTester tester,
  ) async {
    final File sharedImage = createTestImageFile();
    final _StubSharingIntentReceiver receiver = _StubSharingIntentReceiver();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(onRecognize: _throwOnRecognize),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: repository,
          sharingIntentReceiver: receiver,
        ),
      ),
    );

    receiver.streamController.add(sharedImage.path);
    await tester.pump();
    // WHY(実 I/O を回すか): OCR 失敗時の未確定レコード保存は原画像の
    // readAsBytes を伴い、これは実 I/O。FakeAsync の下では完了しないため、
    // 実時間を進めないと保存が起きないまま検証してしまう。
    await pumpThroughRealIo(tester);
    // 自動保存される（プレーシェアは一度きりの情報源のため）。
    expect(repository.createdDrafts, hasLength(1));
    expect(repository.createdDrafts.single.status, PlayRecordStatus.pending);
    expect(repository.createdDrafts.single.songName, isNull);
    expect(repository.createdDrafts.single.source, PlayRecordSource.playshare);
    expect(find.textContaining('OCRに失敗したため未確定レコードとして保存しました'), findsOneWidget);
    // OCR 失敗時は確認・編集画面へ遷移しない。
    expect(find.byType(OcrResultScreen), findsNothing);
  });
}
