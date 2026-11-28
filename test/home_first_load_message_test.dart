// 初回読み込み中のメッセージのテスト。
//
// 検証対象:
// (1) ブラウザ版 OCR は初回だけエンジン一式（約 69MB）を取得するため待ち時間が
//     長い。その間だけ「初回のみ読み取りエンジンを読み込んでいます」を出す。
// (2) 読み込みが終わったら（＝実行中でも初回でなくなったら）その行は消える。
//
// WHY(フェイクで isPreparing を override するか): UI は `kIsWeb` や具象型ではなく
// 「エンジンが名乗る性質」で判定する契約にした。その契約が実際に
// メッセージの出し分けに効いていることを、環境非依存のテストで固定する。

// WHY: この環境の Flutter では package:flutter/material.dart が非推奨で
// material_ui が正規導入（既存テストの import 規約に合わせる）。
import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/platform/platform_capabilities.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'root_bundle_warmup.dart';

const String _firstLoadMessage = '初回のみ読み取りエンジンを読み込んでいます';

/// 「まだ初回読み込みが終わっていない」と名乗るエンジン。
///
/// [recognize] はテスト側が完了させるまで返らない。その止まっている間に
/// メッセージが出ていることを確かめる。
class _FirstLoadOcrEngine extends FakeOcrEngine {
  _FirstLoadOcrEngine({
    required super.onRecognize,
    required super.onRecognizeRegion,
    required this.isPreparing,
  });

  @override
  final bool isPreparing;
}

/// pickImage の戻り値を固定するフェイク（画像の中身は問わない）。
class _FixedPicker extends ImagePicker {
  _FixedPicker(this._picked);

  final XFile _picked;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => _picked;
}

/// メモリ上の PNG。
///
/// WHY(実ファイルを使わないか): `XFile.readAsBytes()` が実ディスク I/O だと
/// ウィジェットテストの FakeAsync 下では完了せず、OCR の実行中状態に
/// 到達できない。`XFile.fromData` なら I/O 無しで解決する。
XFile _imageFile() {
  final img.Image image = img.Image(width: 1200, height: 900);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  return XFile.fromData(
    img.encodePng(image),
    name: 'first_load.png',
    mimeType: 'image/png',
  );
}

void main() {
  setUpAll(warmRootBundleAssets);

  testWidgets('初回読み込み中はメッセージを出し、終わったら消す', (WidgetTester tester) async {
    final Completer<OcrPageResult> pending = Completer<OcrPageResult>();
    final _FirstLoadOcrEngine engine = _FirstLoadOcrEngine(
      onRecognize: (_) => pending.future,
      onRecognizeRegion: (
        _,
        _, {
        required OcrScript script,
        double pixelScale = 1.0,
        bool contrastRetry = false,
      }) async => const OcrPageResult.empty(),
      isPreparing: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: engine,
          capabilities: const LocalCapabilities(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          imagePicker: _FixedPicker(_imageFile()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();

    // HC リザルト写真のギャラリー行（Lively 側と同名なので key で指す）。
    final Finder galleryRow = find.byKey(
      const ValueKey<String>('species-row-result-gallery'),
    );
    await tester.ensureVisible(galleryRow);
    await tester.tap(galleryRow);
    // WHY(pumpAndSettle を使わないか): 実行中は進捗スピナーが回り続けるため
    // pumpAndSettle はタイムアウトする。pop のアニメーションぶんだけ進める。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(_firstLoadMessage), findsOneWidget);

    pending.complete(const OcrPageResult.empty());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(_firstLoadMessage), findsNothing);
  });

  testWidgets('初回読み込みが終わっているエンジンではメッセージを出さない', (WidgetTester tester) async {
    final Completer<OcrPageResult> pending = Completer<OcrPageResult>();
    final _FirstLoadOcrEngine engine = _FirstLoadOcrEngine(
      onRecognize: (_) => pending.future,
      onRecognizeRegion: (
        _,
        _, {
        required OcrScript script,
        double pixelScale = 1.0,
        bool contrastRetry = false,
      }) async => const OcrPageResult.empty(),
      isPreparing: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: engine,
          capabilities: const LocalCapabilities(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          imagePicker: _FixedPicker(_imageFile()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();

    final Finder galleryRow = find.byKey(
      const ValueKey<String>('species-row-result-gallery'),
    );
    await tester.ensureVisible(galleryRow);
    await tester.tap(galleryRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(_firstLoadMessage), findsNothing);
    expect(find.text('OCRを実行中…'), findsOneWidget);

    pending.complete(const OcrPageResult.empty());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });
}

/// 曲データベースは表示にしか使わないため、空を返すだけで足りる。
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
  }) async => const SongImportResult(success: false);

  @override
  Future<SongDatabaseStatus> loadStatus() async => const SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );
}
