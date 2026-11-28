// v3 種別選択フロー（01a20785-a302・リード引き取り実装）のテスト。
//
// 検証対象:
// (1) 「画像を取り込む」タップ → 種別シート 3 行（HC プレーシェア / HC リザルト写真 / Lively）
// (2) プレーシェア行 → ギャラリー pick → OCR 成功 → 確認画面遷移
// (3) プレーシェア行 + 4:3 画像 → 不一致 SnackBar が表示される（hint=hcV1 が渡る証明）
// (4) リザルト写真ギャラリー行 + 横長画像 → 不一致 SnackBar が表示される（hint=acV1 が渡る証明）
// (5) リザルト写真ギャラリー行 + 4:3 画像 → 一致 → 不一致 SnackBar 無し
// (6) カメラ行（Androidのみ表示・01a20785-bb40 実装）: (6a) Android で pickImage(camera)
//     発火＋hint=acV1 で OCR 遷移 (6b) Windows では非表示 (6c) pickImage 例外 →
//     SnackBar「カメラを利用できません」・OCR 未実行 (6d) 撮影ガイド文言表示
//     (6e)(6f) 未注入（本番相当・imagePicker=null）でもファクトリ生成ピッカーで
//     ギャラリー/カメラ pick が発火する（2026-11-23 リリース検証で発見した
//     「未注入だと pickImage 自体が呼ばれず無音で取り込みが死ぬ」不具合の回帰防止）
// (7) Lively 行 → ギャラリー pick → hint=livelyV1 で OCR が走る（2026-11-24
//     統合ストラテジー実装で有効化。不一致 SnackBar は出さない＝分類不能）
// (8) 共有インテント経由 → hint なし（不一致 SnackBar 無し・裁定 A・現行不変）
//
// WHY hint を SnackBar の有無で観測する: HomeScreen は OcrPipeline を内部構築
// するため hint を直接スパイできない。代わりに実 pipeline の不一致フラグ
// （ST-1 分類直後判定・コミット 0491817）を観測面に使う。分類は画像のアスペ
// クト比で決まるため、横長（1.5）と 4:3（1.333）のテスト画像 × 2 種別行の
// 4 組合わせで不一致 SnackBar の出現/非出現を固定すれば、渡された hint 値が
// hcV1 / acV1 のどちらであるかを完全に確定できる。
// WHY: debugDefaultTargetPlatformOverride は foundation にあるが material_ui
// からは再エクスポートされないため個別 import（Windows 非表示テスト用）。
import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/capture_screen.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/sharing_intent_receiver.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';
import 'root_bundle_warmup.dart';

// WHY: この環境の Flutter では package:flutter/material.dart が非推奨で
// material_ui が正規導入（既存テストの import 規約に合わせる）。

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

/// pickImage の戻り値だけを制御できるフェイク（home_screen_test.dart と同形）。
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

/// bb40 カメラ入口の検証用: ソース記録と例外注入ができるフェイク。
///
/// WHY: カメラ行の検証には「pickImage が ImageSource.camera で呼ばれたか」
/// の観測と「例外時に SnackBar へフォールバックする」注入が必要で、
/// [_FakeImagePicker] では両方とも表現できない。
class _CameraProbeImagePicker extends ImagePicker {
  _CameraProbeImagePicker(this._result, {this.error});

  final XFile? _result;

  /// 非 null の場合、pickImage 呼び出し時にこのエラーを投げる（例外経路用）。
  final Object? error;

  /// 最後に pickImage へ渡されたソース（camera 呼び出し検証に使う）。
  ImageSource? lastSource;

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
    if (error != null) {
      throw error!;
    }
    return _result;
  }
}

/// 共有インテント受付のスタブ（home_screen_share_intent_test.dart と同形・
/// 本テストは冷起動経路のみ使用）。
class _StubSharingIntentReceiver extends SharingIntentReceiver {
  _StubSharingIntentReceiver({this.initialPath});

  /// 冷起動で getInitialImagePath が返すパス（null = 初期インテントなし）。
  final String? initialPath;

  @override
  Future<String?> getInitialImagePath() async => initialPath;

  @override
  Stream<String> get imagePathStream => const Stream<String>.empty();

  @override
  void cancel() {}
}

/// 4x3 白ピクセルの PNG（アーケード実機相当・アスペクト比 1.333）。
///
/// WHY: 不一致フラグの観測には「ST-1 分類が arcadeResultFrame になる画像」が
/// 必要（横長でアスペクト <1.45 → arcadeResultFrame・docs の実測分類規則）。
/// プレーシェア代表の 3x2（1.5）と対にして hint 値の真偽表を完成させる。
Uint8List _arcadeLikePngBytes() {
  final img.Image image = img.Image(width: 4, height: 3);
  img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

/// 4:3 画像を選択結果として渡すための XFile。
///
/// WHY(毎回書き出すか): パイプラインは実ファイルを読むため、バイト列だけでは
/// 流せない。各テストが自分専用のファイルを持つことで、後片付けの順序に
/// 依存しない。
XFile _arcadeLikeXFile() {
  return XFile(
    createTempImageFileFromBytes(
      _arcadeLikePngBytes(),
      'scoreyomipm-arcade-${DateTime.now().microsecondsSinceEpoch}.png',
    ).path,
  );
}

/// HomeScreen を種別シート検証用に構築する。
///
/// WHY: 寸法未指定の空結果（[OcrPageResult.empty]）は領域再 OCR・抽出を
/// スキップする成功結果。本テストの検証対象はシートと hint 経路のみで、
/// 抽出内容は作り込まない（home_screen_test.dart の改修1テストと同方針）。
Future<void> _pumpHome(
  WidgetTester tester,
  XFile pickedImage, {
  ImagePicker? imagePicker,
  ImagePicker Function()? imagePickerFactory,
}) async {
  // WHY: ファクトリ指定時は imagePicker を渡さず本番相当（未注入）経路を試す。
  // どちらも未指定なら従来どおり既定フェイクを注入する（既存テスト互換）。
  final ImagePicker? effectivePicker = imagePickerFactory != null
      ? null
      : (imagePicker ?? _FakeImagePicker(pickedImage));
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        // WHY: 空結果を返す fake。recognizeRegion は寸法欠落で呼ばれないため
        // 既定（UnimplementedError）のままでよい。
        ocrEngine: FakeOcrEngine(
          onRecognize: (_) async => const OcrPageResult.empty(),
        ),
        songDatabaseService: _FakeSongDatabaseService(),
        playRecordRepository: FakePlayRecordRepository(),
        imagePicker: effectivePicker,
        imagePickerFactory: imagePickerFactory ?? ImagePicker.new,
        // FR-9 案A（2026-11-24）導入後、カメラ入口はまずアプリ内撮影画面へ
        // 入る。本ファイルは従来の「image_picker カメラ経路＝フォールバック層」
        // の non-reg を検証するため、常に fallback を返して撮影画面を素通り
        // させる（撮影画面自身の分岐は home_capture_flow_test.dart が担う）。
        captureLauncher: () async => const CaptureOutcome.fallback(),
      ),
    ),
  );
  await tester.pump();
}

/// 「画像を取り込む」→ シートで指定行をタップして OCR 完了まで待つ。
///
/// WHY: パイプライン内のアンカーパック読み込みと seed ロードは rootBundle
/// （実 I/O）で FakeAsync 下では進まないため、runAsync で実非同期の完了を
/// 待ってから pump する（home_screen_test.dart #13 テストと同一パターン）。
Future<void> _importViaSheet(
  WidgetTester tester, {
  required String rowText,
  String? rowKey,
  bool expandResultActions = false,
}) async {
  await tester.tap(find.text('画像を取り込む'));
  await tester.pumpAndSettle();
  if (expandResultActions) {
    // WHY: リザルト写真行の 2 アクションは親行の直下に常時表示する（設計 §1）。
    // 先に親行が出ていることを確認してから子アクションをタップする。
    expect(find.text('HC リザルト写真'), findsOneWidget);
  }
  // WHY rowKey: 2026-11-26 に機種 chips へ「Lively」を足したため、表示文字列
  // 「Lively」は機種 chip と種別行の 2 箇所に出る。行を特定する用途では key を使う。
  final Finder target = rowKey != null
      ? find.byKey(ValueKey<String>(rowKey))
      : find.text(rowText);
  // WHY: シートは高さ上限でスクロールするため、下端の行は可視化してからタップする。
  await tester.ensureVisible(target);
  await tester.tap(target);
  // WHY(pumpAndSettle を使わないか): 行をタップするとシートが閉じ、続けて OCR が
  // 始まって進捗スピナー（無限アニメーション）が出る。スピナーは回り続けるため
  // pumpAndSettle は必ずタイムアウトする。pop アニメーションぶんだけ固定で進め、
  // OCR の実非同期は _waitForOcrResultScreen 側で待つ。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// OCR run の完了（確認画面遷移）を実非同期込みで待つ。
Future<void> _waitForOcrResultScreen(WidgetTester tester) async {
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
}

void main() {
  setUpAll(warmRootBundleAssets);
  testWidgets('「画像を取り込む」タップで種別シートが開き 4 行表示される', (WidgetTester tester) async {
    await _pumpHome(tester, XFile(createTestImageFile().path));

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();

    expect(find.text('HC プレーシェア'), findsOneWidget);
    expect(find.text('HC リザルト写真'), findsOneWidget);
    // WHY key で見るか: 2026-11-26 に機種 chips へ「Lively」を足したため、
    // 表示文字列「Lively」は機種 chip と種別行の 2 箇所に出る。
    expect(
      find.byKey(const ValueKey<String>('species-row-lively')),
      findsOneWidget,
    );
    // WHY 手入力も数えるか: 2026-11-26 の指示で手入力の行を最下段へ移したため、
    // 種別行は 4 本（プレーシェア / リザルト写真 / Lively / 手入力）になる。
    expect(
      find.byKey(const ValueKey<String>('species-row-manual-entry')),
      findsOneWidget,
    );
    // WHY findsNothing: 2026-11-24 に Lively 行を有効化したため（統合
    // ストラテジーで H&C と同じ経路に載せた）、「準備中」表示は消えている。
    expect(find.text('準備中'), findsNothing);
  });

  testWidgets('プレーシェア行 → ギャラリー pick → OCR 成功 → 確認画面遷移', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester, XFile(createTestImageFile().path));

    await _importViaSheet(tester, rowText: 'HC プレーシェア');
    await _waitForOcrResultScreen(tester);

    expect(find.byType(OcrResultScreen), findsOneWidget);
    // WHY: 横長画像 × hint=hcV1 は分類（landscapePlayShare → 期待 hcV1）と
    // 一致するため、不一致 SnackBar は出ない。
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });

  testWidgets('プレーシェア行 + 4:3 画像 → 不一致 SnackBar が表示される', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester, _arcadeLikeXFile());

    await _importViaSheet(tester, rowText: 'HC プレーシェア');
    await _waitForOcrResultScreen(tester);

    // WHY: hint=hcV1 × 分類 arcadeResultFrame（期待 acV1）の不一致。SnackBar
    // は警告表示のみで処理は継続される（裁定 D・遷移は止まらない）。
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsOneWidget);
  });

  testWidgets('リザルト写真ギャラリー行 + 横長画像 → 不一致 SnackBar が表示される', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester, XFile(createTestImageFile().path));

    await _importViaSheet(
      tester,
      rowText: 'ギャラリーから選択',
      rowKey: 'species-row-result-gallery',
      expandResultActions: true,
    );
    await _waitForOcrResultScreen(tester);

    // WHY: hint=acV1 × 分類 landscapePlayShare（期待 hcV1）の不一致。
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsOneWidget);
  });

  testWidgets('リザルト写真ギャラリー行 + 4:3 画像 → 一致のため不一致 SnackBar 無し', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester, _arcadeLikeXFile());

    await _importViaSheet(
      tester,
      rowText: 'ギャラリーから選択',
      rowKey: 'species-row-result-gallery',
      expandResultActions: true,
    );
    await _waitForOcrResultScreen(tester);

    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });

  // ---- bb40: カメラ撮影入口（リザルト写真種別・FR-9 案A 基線） ------------
  //
  // WHY red-first 不履行の記録: bb40 は lib 先行実装となったため red-first の
  // 順序を守れなかった。代わりに、a302 状態（カメラ行 disabled・「準備中」表示）
  // に対しては本テスト群が失敗することを実ファイルで確認済み（タップ無反応で
  // lastSource が null・ガイド文言が存在しない）。

  testWidgets('カメラ行タップ → pickImage(camera) 発火・hint=acV1 で OCR が走る', (
    WidgetTester tester,
  ) async {
    // WHY: 4:3 画像は ST-1 分類で arcadeResultFrame になり hint=acV1 と一致。
    // 不一致 SnackBar が無いことで「acV1 が渡った」ことを観測できる（冒頭の
    // 観測方針コメント参照）。
    final XFile arcadeImage = _arcadeLikeXFile();
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(arcadeImage);
    await _pumpHome(tester, arcadeImage, imagePicker: picker);

    await _importViaSheet(
      tester,
      rowText: 'カメラで撮影',
      rowKey: 'species-row-result-camera',
    );
    await _waitForOcrResultScreen(tester);

    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(picker.lastSource, ImageSource.camera);
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });

  testWidgets('Windows ではカメラ行が非表示（platform gate）', (WidgetTester tester) async {
    // WHY: FR-9 §8 は Android のみ表示。テストでは
    // debugDefaultTargetPlatformOverride で制御する（dart:io の
    // Platform.isAndroid はホスト OS を見るためテストで制御不能）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _pumpHome(tester, XFile(createTestImageFile().path));

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();

    // シート自体は開いている（ギャラリー行はある）が、カメラ行だけが無い。
    expect(find.text('HC リザルト写真'), findsOneWidget);
    expect(find.text('カメラで撮影'), findsNothing);
    expect(find.text('リザルト画面全体が収まるように撮影してください'), findsNothing);
  });

  testWidgets('pickImage 例外 → SnackBar 表示・OCR 未実行（状態破損なし）', (
    WidgetTester tester,
  ) async {
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(
      null,
      error: Exception('camera unavailable'),
    );
    await _pumpHome(
      tester,
      XFile(createTestImageFile().path),
      imagePicker: picker,
    );

    await _importViaSheet(
      tester,
      rowText: 'カメラで撮影',
      rowKey: 'species-row-result-camera',
    );

    // WHY: pickImage 失敗は FR-9 §4 のとおり SnackBar へフォールバックし、
    // クラッシュも OCR 誤実行もしない。取り込み入口が残存することで
    // アプリ状態の破損がないことも併せて担保する。
    expect(find.text('カメラを利用できません'), findsOneWidget);
    expect(find.byType(OcrResultScreen), findsNothing);
    expect(find.text('画像を取り込む'), findsOneWidget);
  });

  testWidgets('撮影ガイド文言がカメラアクション近傍に表示される', (WidgetTester tester) async {
    await _pumpHome(tester, XFile(createTestImageFile().path));

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();

    // WHY key で数えるか: 2026-11-26 に Lively 側にもカメラ行を足したため、
    // 「カメラで撮影」の表示文字列は 2 箇所に出る。ここは HC 側だけを見る。
    expect(
      find.byKey(const ValueKey<String>('species-row-result-camera')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('species-row-lively-camera')),
      findsOneWidget,
    );
    expect(find.text('リザルト画面全体が収まるように撮影してください'), findsOneWidget);
  });

  // ---- 2026-11-23 リリース検証で発見した未注入バグの回帰防止 ---------------
  //
  // WHY: 本番（main.dart）は imagePicker を DI しない。旧実装は null-aware
  // 呼び出し `widget.imagePicker?.pickImage(...)` のため、未注入時は pickImage
  // 自体が呼ばれず、シートが閉じるだけで取り込みが無音に失敗していた。
  // フィールド doc の契約「null なら実装をその場で生成する」をファクトリ経由で
  // 実現させ、注入なしのウィジェットテストで発火まで固定する。

  testWidgets('未注入（本番相当）でもファクトリ生成ピッカーでギャラリー pick が走る', (
    WidgetTester tester,
  ) async {
    // WHY: 保存経路が原画像を読むため、実在するファイルを渡す（ダミーの
    // パスだと読み込みで失敗し、ピッカーが呼ばれたこと以外を観測できない）。
    final XFile picked = XFile(createTestImageFile().path);
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(picked);
    // WHY: imagePicker を渡さないことで main.dart と同じ未注入状態を作る。
    await _pumpHome(
      tester,
      picked,
      imagePickerFactory: () => picker,
    );

    await _importViaSheet(tester, rowText: 'HC プレーシェア');
    await _waitForOcrResultScreen(tester);

    expect(picker.lastSource, ImageSource.gallery);
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });

  testWidgets('未注入（本番相当）でもファクトリ生成ピッカーでカメラ pick が走る', (
    WidgetTester tester,
  ) async {
    // WHY: 4:3 画像 × hint=acV1 は分類と一致するため不一致 SnackBar 無し
    // （acV1 が渡ったことの観測。冒頭の観測方針コメント参照）。
    final XFile arcadeImage = _arcadeLikeXFile();
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(arcadeImage);
    await _pumpHome(
      tester,
      arcadeImage,
      imagePickerFactory: () => picker,
    );

    await _importViaSheet(
      tester,
      rowText: 'カメラで撮影',
      rowKey: 'species-row-result-camera',
    );
    await _waitForOcrResultScreen(tester);

    expect(picker.lastSource, ImageSource.camera);
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });

  testWidgets('Lively 行タップ → ギャラリー pick 発火・hint=livelyV1 で OCR が走る', (
    WidgetTester tester,
  ) async {
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(
      XFile(createTestImageFile().path),
    );
    await _pumpHome(
      tester,
      XFile(createTestImageFile().path),
      imagePicker: picker,
    );

    await _importViaSheet(
      tester,
      rowText: 'Lively',
      rowKey: 'species-row-lively-gallery',
    );
    await _waitForOcrResultScreen(tester);

    // WHY: 2026-11-24 のユーザー指示で「準備中」から有効化した。Lively は
    // 写真（ギャラリー）だけを入口にし、hint=livelyV1 で専用経路（統合
    // ストラテジー）へ流す。hint は分類不能のため不一致 SnackBar を出さない。
    expect(picker.lastSource, ImageSource.gallery);
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsNothing);

    // WHY: 2026-11-26 のユーザー指示「Lively のスコア画面写真から読み取るを
    // 選んで OCR を始めた場合は編集画面でも Lively を自動で選択していてほしい」。
    // Lively 行は行の選択自体が機種を決めるため、シートの chip が既定（H☆C!!）の
    // ままでも、編集画面へは Lively が渡る。chip が選択状態になること自体は
    // v5_difficulty_machine_test.dart の「route(initialMachine) で開くと機種 chip が
    // 選択された状態」で検証済みなので、ここでは受け渡しだけを見る。
    // （このテストの OCR は要素 0 件で着地するため、画面上に chip は出ない）
    expect(
      tester
          .widget<OcrResultScreen>(find.byType(OcrResultScreen))
          .initialMachine,
      livelyMachineName,
    );
  });

  // 2026-11-26 のユーザー指示「HC のカメラで撮影のようにその場で枠線付きの
  // カメラを起動することはできますか」。撮影画面が使えない環境（テスト・権限なし）
  // では従来の image_picker カメラへ降りるので、HC 側と同じ経路で観測できる。
  //
  // WHY hint を直接観測しないか: livelyV1 は不一致フラグを常に false にする
  // （分類器が判定を出せないため）ので、HC 側のように SnackBar の有無で hint を
  // 観測できない。ここでは入口の機種が編集画面まで届くことまでを固定し、
  // hint=livelyV1 の経路自体は test/pipeline_lively_test.dart が検証している。
  testWidgets('Lively カメラ行 → pickImage(camera) 発火・機種 Lively で OCR が走る', (
    WidgetTester tester,
  ) async {
    final _CameraProbeImagePicker picker = _CameraProbeImagePicker(
      XFile(createTestImageFile().path),
    );
    await _pumpHome(
      tester,
      XFile(createTestImageFile().path),
      imagePicker: picker,
    );

    await _importViaSheet(
      tester,
      rowText: 'カメラで撮影',
      rowKey: 'species-row-lively-camera',
    );
    await _waitForOcrResultScreen(tester);

    expect(picker.lastSource, ImageSource.camera);
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(
      tester
          .widget<OcrResultScreen>(find.byType(OcrResultScreen))
          .initialMachine,
      livelyMachineName,
    );
  });

  testWidgets('共有インテント経由は hint なしで OCR が走る（不一致 SnackBar 無し）', (
    WidgetTester tester,
  ) async {
    createTestImageFile();
    final _StubSharingIntentReceiver receiver = _StubSharingIntentReceiver(
      initialPath: createTestImageFile().path,
    );

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
    await tester.pump();

    await _waitForOcrResultScreen(tester);

    // WHY: 共有インテント経由は種別シートを通らず hint なし（裁定 A）。
    // 分類 landscapePlayShare（3x2 画像）→ 期待 hcV1・flag false。
    expect(find.byType(OcrResultScreen), findsOneWidget);
    expect(find.textContaining('一致していない可能性'), findsNothing);
  });
}
