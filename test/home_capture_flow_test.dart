// FR-9 案A（撮影ガイド枠・2026-11-24 ユーザー指示）: ホームのカメラ入口から
// アプリ内撮影画面の結果を受けて OCR へ合流する経路のテスト。
//
// 契約（リード裁定 2026-11-24）:
// - captured: 撮影画像を acV1（リザルト写真）で既存 OCR 経路へ流す。
// - gallery / permissionDenied: ギャラリー選択へ誘導する。
// - fallback: 従来の image_picker カメラ経路へ降りる（v3 基線の防御層）。
// - null（ユーザーが撮影画面を閉じた）: 何もしない。
//
// WHY ここで検証する: 撮影画面自体の分岐は capture_screen_test.dart が
// 担う。本ファイルは「撮影結果 → OCR 合流」の配線（HomeScreen）を固定する。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/capture_screen.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
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

/// pickImage の発火と戻り値を観測するフェイク。
class _PickerProbe extends ImagePicker {
  _PickerProbe(this._picked);

  final XFile? _picked;
  ImageSource? lastSource;
  int pickCount = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    lastSource = source;
    pickCount++;
    return _picked;
  }
}

/// AC リザルト画面想定の 4:3 画像（acV1 分類と一致させる）。
XFile _arcadeImage() {
  final img.Image image = img.Image(width: 1200, height: 900);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  final File file = File(
    '${Directory.systemTemp.path}/capture_flow_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  file.writeAsBytesSync(img.encodePng(image));
  return XFile(file.path);
}

Future<_PickerProbe> _pumpHome(
  WidgetTester tester, {
  required Future<CaptureOutcome?> Function() captureLauncher,
  required XFile picked,
}) async {
  final _PickerProbe probe = _PickerProbe(picked);
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        ocrEngine: FakeOcrEngine(
          onRecognize: (_) async => const OcrPageResult.empty(),
        ),
        songDatabaseService: _FakeSongDatabaseService(),
        playRecordRepository: FakePlayRecordRepository(),
        imagePicker: probe,
        captureLauncher: captureLauncher,
      ),
    ),
  );
  await tester.pump();
  return probe;
}

/// 画像取り込みシートを開き「HC リザルト写真」行のカメラをタップする。
Future<void> _tapResultCamera(WidgetTester tester) async {
  await tester.tap(find.text('画像を取り込む'));
  await tester.pumpAndSettle();
  // WHY key で指すか: 2026-11-26 に Lively 側にも「カメラで撮影」行を足したため、
  // 表示文字列では 2 件に当たる（HC 側は species-row-result-camera）。
  final Finder cameraRow = find.byKey(
    const ValueKey<String>('species-row-result-camera'),
  );
  // WHY ensureVisible: シートは高さ上限でスクロールするため、下端の行は
  // 可視化してからタップする（既存テスト共通パターン）。
  await tester.ensureVisible(cameraRow);
  await tester.tap(cameraRow);
  // WHY(pumpAndSettle を使わないか): 行をタップするとシートが閉じ、続けて OCR が
  // 始まって進捗スピナー（無限アニメーション）が出る。スピナーは回り続けるため
  // pumpAndSettle は必ずタイムアウトする。pop アニメーションぶんだけ固定で進め、
  // OCR の実非同期は _waitForOcrResultScreen 側で待つ。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// OCR 結果画面への遷移を実非同期で待つ（rootBundle 読込は FakeAsync 下で
/// 進まないため runAsync で待つ。既存テスト共通パターン）。
Future<void> _waitForOcrResultScreen(WidgetTester tester) async {
  for (int i = 0; i < 60; i++) {
    if (find.byType(OcrResultScreen).evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  fail('OCR 結果画面に遷移しない');
}

void main() {
  setUpAll(warmRootBundleAssets);
  group('FR-9 案A: 撮影画面 → OCR 合流', () {
    testWidgets('撮影成功の画像で OCR 結果画面へ遷移する（acV1・不一致なし）', (
      WidgetTester tester,
    ) async {
      final XFile image = _arcadeImage();
      final _PickerProbe picker = await _pumpHome(
        tester,
        captureLauncher: () async => CaptureOutcome.captured(image.path),
        picked: image,
      );
      await _tapResultCamera(tester);

      expect(picker.pickCount, 0, reason: '撮影成功時はピッカーを使わない');
      await _waitForOcrResultScreen(tester);
      expect(find.byType(OcrResultScreen), findsOneWidget);
      // 4:3 画像 = acV1 分類一致のため不一致 SnackBar は出ない。
      expect(find.textContaining('種別'), findsNothing);
    });

    testWidgets('撮影画面の fallback は既存 image_picker カメラ経路へ降りる', (
      WidgetTester tester,
    ) async {
      final XFile image = _arcadeImage();
      final _PickerProbe picker = await _pumpHome(
        tester,
        captureLauncher: () async => const CaptureOutcome.fallback(),
        picked: image,
      );
      await _tapResultCamera(tester);

      expect(picker.lastSource, ImageSource.camera);
    });

    testWidgets('撮影画面のギャラリー選択はギャラリー経路へ', (WidgetTester tester) async {
      final XFile image = _arcadeImage();
      final _PickerProbe picker = await _pumpHome(
        tester,
        captureLauncher: () async => const CaptureOutcome.gallery(),
        picked: image,
      );
      await _tapResultCamera(tester);

      expect(picker.lastSource, ImageSource.gallery);
    });

    testWidgets('権限拒否はギャラリー選択へ誘導する', (WidgetTester tester) async {
      final XFile image = _arcadeImage();
      final _PickerProbe picker = await _pumpHome(
        tester,
        captureLauncher: () async => const CaptureOutcome.permissionDenied(),
        picked: image,
      );
      await _tapResultCamera(tester);

      expect(picker.lastSource, ImageSource.gallery);
    });

    testWidgets('撮影画面を閉じた（null）場合は何もしない', (WidgetTester tester) async {
      final XFile image = _arcadeImage();
      final _PickerProbe picker = await _pumpHome(
        tester,
        captureLauncher: () async => null,
        picked: image,
      );
      await _tapResultCamera(tester);

      expect(picker.pickCount, 0);
      expect(find.byType(OcrResultScreen), findsNothing);
    });
  });
}
