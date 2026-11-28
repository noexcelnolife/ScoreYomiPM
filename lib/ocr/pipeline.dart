// ST-1 / ST-4 / ST-5 / ST-6: OCR パイプライン
//
// 入力画像の分類・前処理 → フィールドOCR → 領域別OCR → 曲名辞書照合（ST-5/ST-6）
// を統合するパイプライン。

import 'dart:io';
import 'dart:typed_data';

import '../models/ocr_models.dart';
import 'field_extractor.dart';
import 'input_preprocessing.dart';
import 'lively/lively_ocr_route.dart';
import 'ocr_engine.dart';
import 'region_ocr.dart';
import 'roll_corrector.dart';
import 'song_entry.dart';
import 'song_repository.dart';
import 'ui_anchor.dart';
import 'song_title_element_matcher.dart';
import 'song_title_matcher.dart';
import 'bundled_seed_repository.dart';
import 'merged_song_repository.dart';
import 'blob_store_song_repository_loader.dart';

/// OCR パイプラインのステージ。
enum OcrPipelineStage { preProcess, fieldOcr, songMatching }

/// OCR パイプラインの実行コンテキスト。
class OcrPipelineContext {
  /// 入力画像ファイル（ST-1.5 補正適用時は補正後ファイルへ差し替わる）。
  ///
  /// WHY 可変: ST-1.5 ロール補正（幾何補正 Phase 1・01a207fc）で正立化した
  /// 一時ファイルへ差し替えたうえで後段ステージへ渡すため。補正なし経路は
  /// 生成時の値のまま（現行挙動不変）。
  File imageFile;

  /// 入力画像のエンコード済みバイト列（PNG/JPEG）。OCR エンジン（Uint8List
  /// 入力）に渡す。run() で imageFile から 1 回だけ readAsBytes する（IO
  /// 側の 1 箇所に寄せる。P3: OcrEngine の baryt入力化）。
  Uint8List? imageBytes;

  /// ST-1 分類結果。fieldOcr でレイアウト種別（hc_v1 / ac_v1）と使用する
  /// アンカーパック版を決定するため保持する。
  InputImageClass? imageClass;

  /// 前処理済み画像ファイル（PNG 再エンコード、temp ファイル）。
  File? preprocessedImageFile;

  /// フルページ OCR 結果（生要素列）。
  OcrPageResult? pageResult;

  /// 前処理後の画像クロップ後の OCR 結果。
  OcrPageResult? processedPageResult;

  /// ST-4 の出力: [FieldExtractor] によるフィールド抽出結果。
  FieldExtractionResult? extractionResult;

  /// ST-4 の出力: [RegionOcrRunner] による領域別 OCR 結果。
  RegionOcrResult? regionOcrResult;

  /// ST-3.5 の出力: UI アンカー検出結果（null = 機能 OFF / 検出不成立）。
  ///
  /// WHY 観測性: アンカーの成立/不成立とヒット位置を計測レポートの根拠に
  /// する（設計 §2.5・失敗しても現行動作のため診断不能化を避ける）。
  AnchorRegistration? anchorRegistration;

  /// ST-5/ST-6 の出力: 曲名辞書照合結果。
  SongMatchResult? songMatchResult;

  /// 照合成功時に解決済みの [SongEntry]（FR-6 §2-5 Plan A）。
  ///
  /// WHY: 後段の曲別上限チェック等は bestMatch* の文字列ではなく、辞書を
  /// 引き直した実エントリの notesCounts を参照する（設計確認書
  /// docs/fr6_matched_song_context_injection_design_confirmation_2026-11-22.md
  /// §2・リード承認）。未解決（照合不成立・要素なし・引き直し失敗・例外）
  /// のときは null のまま。
  SongEntry? matchedSong;

  /// 使用した SongRepository（デバッグ・検証用）。
  SongRepository? songRepository;

  /// v3 種別選択フローで渡されたレイアウトヒント（null = 未指定・自動分類）。
  ///
  /// WHY: 種別選択フローの観測性と FR-3 画面での不一致警告（SnackBar）の判断
  /// 材料のため、run の戻り値（本 context）で UI 層へ届く。共有インテント経由
  /// は null のまま（裁定 A・現行挙動不変）。
  InputLayoutHint? layoutHint;

  /// hint 指定時、ST-1 分類から期待されるレイアウトと不一致なら true。
  ///
  /// WHY: 裁定 D（警告表示して処理継続・遮断しない）のための判定フラグ。
  /// hint 未指定時は常に false（自動分類経路は現行挙動完全不変）。期待レイ
  /// アウトの対応表は [_expectedLayoutOf] を参照。
  bool layoutMismatchFlag = false;

  /// ST-4 で使用したレイアウト種別（hint 優先の最終決定値）。
  ///
  /// WHY 観測性: 種別選択フローのデバッグとテスト（01a20785-89a5）で、hint が
  /// 実際にレイアウト決定へ効いたことを確認できるようにする。hint 未指定時は
  /// 分類由来。fieldOcr が寸法欠落でスキップされた場合は null のまま。
  LayoutKind? layoutKind;

  OcrPipelineContext({required this.imageFile, this.imageBytes});
}

/// OCR パイプライン。
///
/// ステージ:
///   1. preProcess - 入力分類・埋め込み写真検出・回転補正（ST-1）
///   2. fieldOcr   - 数値フィールド抽出（ST-4）
///   3. songMatching - 曲名辞書照合（ST-5/ST-6）
class OcrPipeline {
  /// OCR エンジン（抽象インターフェース）。
  ///
  /// WHY: spec.md §7.3 の抽象レイヤー（OcrEngine）に依存し、
  /// 将来の OCR 系統差し替えに耐える構成を保つため。
  /// パイプラインは具象 MlKitOcrEngine に依存しない（DIP・ST-5 は
  /// regionOcrResult 由来のみで engine を参照しない）。
  final OcrEngine engine;

  /// 注入可能なメイン DB リポジトリ（downloadedMain 相当・省略時 null）。
  ///
  /// WHY: spec.md §10 の配信 DB（App-UI 01a201da が管理）を OCR 層へ DIP で
  /// 注入するため。抽象 SongRepository を受けるので、テストでは fake を
  /// 注入でき、App-UI は具象 DownloadedMainRepository を注入する。
  final SongRepository? mainSongRepository;

  /// 注入可能なユーザー追加 DB リポジトリ（localAdditional 相当・省略時 null）。
  ///
  /// WHY: アーケード新曲の未反映をユーザー追加 DB で上書きする（spec §10）。
  /// メイン DB より優先される。
  final SongRepository? additionalSongRepository;

  /// 実装済みステージ。
  static const Set<OcrPipelineStage> _implementedStages = {
    OcrPipelineStage.preProcess,
    OcrPipelineStage.fieldOcr,
    OcrPipelineStage.songMatching,
  };

  /// アンカーパックの asset バージョン id（設計 §2.3）。
  static const String _anchorPackVersion = 'hc_v1';

  /// アンカーパックのローダ（省略時: assets/anchors/hc_v1 を読む）。
  ///
  /// WHY 既定で asset ロード: App-UI 側のパイプライン生成コード
  /// （home_screen.dart は App-UI スコープ）を変更せずに ST-3.5 を有効化
  /// するため。ロード失敗（asset 欠落/壊れ）は null = 機能 OFF で現行動作。
  /// テストは合成パックやカスタムローダを注入して契約を固定できる（DIP）。
  final Future<AnchorPack?> Function() anchorPackLoader;

  /// ST-1.5 ロール補正器（省略時: 既定実装 [RollCorrector] を生成）。
  ///
  /// WHY 非nullable フィールド + 既定生成: 2026-11-23 発見の
  /// imagePicker 未注入不具合（a0d6a03・null 受信側で ?. が silently no-op）
  /// の教訓を踏襲する。DI 未注入の本番経路が静かに無効化される事故を
  /// null 許容フィールドでは構造的に防げないため、既定実装を必ず持たせる。
  final RollCorrector rollCorrector;

  /// アンカーパックの遅延ロード結果（1 インスタンスにつき 1 回）。
  Future<AnchorPack?>? _anchorPackFuture;

  OcrPipeline({
    required this.engine,
    this.mainSongRepository,
    this.additionalSongRepository,
    Future<AnchorPack?> Function()? anchorPackLoader,
    RollCorrector? rollCorrector,
  }) : anchorPackLoader = anchorPackLoader ?? _defaultAnchorPackLoader,
       rollCorrector = rollCorrector ?? RollCorrector();

  /// 既定ローダ: assets/anchors/hc_v1/ を読む（失敗時 null = 機能 OFF）。
  static Future<AnchorPack?> _defaultAnchorPackLoader() =>
      AnchorPack.loadFromAssets(_anchorPackVersion);

  /// アンカーパックを遅延ロードする（1 インスタンスにつき 1 回）。
  Future<AnchorPack?> _loadAnchorPack() {
    return _anchorPackFuture ??= anchorPackLoader();
  }

  /// 原画像をバイト列として読む。
  ///
  /// WHY(包むか): パイプラインの失敗契約は [OcrEngineException] で、呼び出し側
  /// はそれを「OCR 失敗」として扱い原画像を未確定レコードに退避する。素の
  /// [FileSystemException] を漏らすと「想定外のエラー」に落ちて画像が失われる。
  /// 読めない原因（権限・削除済み・容量）は OCR 失敗と同じ扱いにする。
  static Future<Uint8List> _readSourceBytes(File source) async {
    try {
      return await source.readAsBytes();
    } on FileSystemException catch (error) {
      throw OcrEngineException('原画像を読み込めませんでした: ${error.message}');
    }
  }

  /// 画像ファイルをパイプラインに流し、[OcrPipelineContext] を返す。
  ///
  /// [layoutHint] は v3 種別選択フロー（docs/v3_input_source_flow_design_
  /// 2026-11-23.md §2・2026-11-23 ユーザー裁定済み）でユーザーが選択した
  /// 対象種別を伝える。null のときは ST-1 自動分類のみでレイアウトを決定する
  /// （共有インテント経由 = 現行挙動完全不変・裁定 A）。hint と分類の不一致は
  /// [OcrPipelineContext.layoutMismatchFlag] に記録される（裁定 D・警告して
  /// 処理継続・遮断しない）。
  Future<OcrPipelineContext> run(
    File imageFile, {
    InputLayoutHint? layoutHint,
  }) async {
    final context = OcrPipelineContext(imageFile: imageFile);
    context.layoutHint = layoutHint;
    // WHY(IO 層で 1 回だけ読むか): [OcrEngine] の入力契約をバイト列にした
    // （P3）ため、ファイル読み出しの責務はパイプライン側へ移った。各段が
    // それぞれ読み直すと、補正でファイルが差し替わったときに段ごとに別の
    // 画素を見る危険がある。読み出しは入口 1 箇所に寄せる。
    context.imageBytes = await _readSourceBytes(imageFile);

    // ST-1.5 ロール補正（幾何補正 Phase 1・01a207fc）。acV1 ヒント経路
    // （実機写真）のみ適用し、それ以外は現行挙動完全不変とする。
    //
    // WHY acV1 限定: Phase 0 実測（integration_test/
    // ocr_geometric_degradation_test.dart）でロール ±3° が score 3/6 に劣化
    // する一方、デジタル取り込み経路は無傾きのため補正不要。hint 無し経路
    // （共有インテント）は既存 30 画像ベンチとバイト等価を維持し回帰ゼロに
    // する（設計 §3）。
    final correctedTemp = _applyRollCorrection(context);
    if (correctedTemp != null) {
      // 補正でファイルが差し替わった場合、バイト列も更新する（acV1 のみ）。
      context.imageBytes = await _readSourceBytes(correctedTemp);
    }
    try {
      for (final stage in _implementedStages) {
        switch (stage) {
          case OcrPipelineStage.preProcess:
            await _runPreProcess(context);
            break;
          case OcrPipelineStage.fieldOcr:
            await _runFieldOcr(context);
            break;
          case OcrPipelineStage.songMatching:
            await _runSongMatching(context);
            break;
        }
      }
    } finally {
      _deleteRollCorrectedTemp(correctedTemp, originalPath: imageFile.path);
    }

    return context;
  }

  /// ST-1.5 ロール補正を適用する（acV1 ヒント時のみ）。
  ///
  /// 戻り値は補正で作られた一時ファイル（補正なし・失敗時は null）。
  /// 成功時は [OcrPipelineContext.imageFile] を補正後ファイルへ差し替える。
  File? _applyRollCorrection(OcrPipelineContext context) {
    if (context.layoutHint != InputLayoutHint.acV1) {
      return null;
    }
    try {
      final corrected = rollCorrector.maybeUpright(context.imageFile);
      if (corrected == null) {
        return null;
      }
      context.imageFile = corrected;
      return corrected;
    } catch (_) {
      // WHY fail-safe: 補正に失敗しても OCR 本体を現行動作（元ファイル）で
      // 完走させる（設計 §3・遮断しない）。
      return null;
    }
  }

  /// 補正一時ファイルを削除する。
  ///
  /// WHY 同一パス保護: 補正器が入力ファイルと同じパスを返した（または戻り値
  /// が null の）場合に呼び出し元の入力ファイルを誤削除しない。
  void _deleteRollCorrectedTemp(File? temp, {required String originalPath}) {
    if (temp == null || temp.path == originalPath) {
      return;
    }
    if (temp.existsSync()) {
      temp.deleteSync();
    }
  }

  /// ステージが実装済みか。
  bool isStageImplemented(OcrPipelineStage stage) =>
      _implementedStages.contains(stage);

  // -----------------------------------------------------------------------
  // Stage 1: preProcess (ST-1)
  // -----------------------------------------------------------------------

  Future<void> _runPreProcess(OcrPipelineContext context) async {
    final preprocessor = InputPreprocessor();
    final cls = preprocessor.classify(context.imageFile);
    context.imageClass = cls;

    // WHY 分類直後に整合判定: 不一致フラグは「ST-1 分類から期待されるレイ
    // アウト」と「hint」の不一致であり、分類が確定したこの時点で判定するの
    // が責務上自然（ST-1 = 分類とその検証）。裁定 D により例外を出さず処理
    // 継続（フラグを立てるのみ・遮断しない）。
    if (context.layoutHint != null) {
      // WHY livelyV1 だけ判定しない: 分類は Lively（PC 画面の写真）を
      // 判別できないため、必ず不一致になって診断が常時点灯する。判定を
      // 出せない以上、フラグを立てないほうが情報として正しい。
      final expected = _expectedLayoutOf(cls);
      context.layoutMismatchFlag =
          context.layoutHint == InputLayoutHint.livelyV1
          ? false
          : _layoutKindOfHint(context.layoutHint!) != expected;
    }

    // ST-1.5 以降（01a207fc）: acV1 ヒント（カメラ経路）では分類駆動の刈り
    // 出し前処理をスキップし、ヒントを信頼して元ファイルのまま acV1 領域で
    // 抽出する。
    //
    // WHY 必須: ロール補正後のキャンバスは回転分の黒パディングを含むため、
    // 分類が rotatedPortrait と誤判定して刈り出し前処理が走り、OCR 入力を
    // 破壊する（2026-11-23 回復測定で実証: rotatedPortrait 誤判定の 3 ランが
    // 全滅、arcadeResultFrame 判定ランは完全回復）。分類と不一致フラグ自体は
    // 維持する（診断情報として有用・裁定 D）。hint 無しの共有経路は現行どお
    // り分類に任せる（回帰なし）。
    // WHY livelyV1 もスキップ: Lively はパネルの位置・倍率が写真ごとに違い、
    // 切り出しは行ラベルを頼りに `LivelyOcrRoute` 側で行う。ここでも刈り出すと
    // 二重に切り出されてラベルが消え、経路が全滅する。
    if (context.layoutHint == InputLayoutHint.acV1 ||
        context.layoutHint == InputLayoutHint.livelyV1) {
      return;
    }

    switch (cls) {
      case InputImageClass.landscapePlayShare:
      case InputImageClass.arcadeResultFrame:
        // プレーシェア・アーケード実機結果画面とも前処理不要（元ファイルをそのまま使用）
        break;
      case InputImageClass.portraitWithEmbedded:
      case InputImageClass.rotatedPortrait:
        final result = await preprocessor.preprocess(context.imageFile);
        context.preprocessedImageFile = result.preprocessedFile;
        // 前処理後のファイルを OCR 入力用バイト列として差し替える（IO 側の 1 箇所に寄せる）。
        context.imageBytes = await result.preprocessedFile.readAsBytes();
        break;
    }
  }

  /// hint をレイアウト種別へ対応付ける（v3 種別フロー・01a20785-89a5）。
  static LayoutKind _layoutKindOfHint(InputLayoutHint hint) => switch (hint) {
    InputLayoutHint.hcV1 => LayoutKind.hcV1,
    InputLayoutHint.acV1 => LayoutKind.acV1,
    InputLayoutHint.livelyV1 => LayoutKind.livelyV1,
  };

  /// Lively（PC 画面の写真）を統合ストラテジーで読み取る。
  ///
  /// WHY 専用メソッド: Lively はアンカー（AC/HC の論理座標）を持たず、行ラベル
  /// の実測位置から切る。アンカー検出・領域 OCR・窓抽出を通すと列位置が
  /// ずれて全滅するため、ここで専用経路へ渡して結果だけを context に載せる。
  /// 以降の ST-5/ST-6（曲名照合）と FR-3 は H&C と完全に共通。
  Future<void> _runLivelyOcr(
    OcrPipelineContext context,
    OcrPageResult pageResult,
  ) async {
    final outcome = await LivelyOcrRoute(engine: engine)
        .run(imageBytes: context.imageBytes!, pageResult: pageResult);
    context.regionOcrResult = outcome.regionOcr;
    context.extractionResult = outcome.extraction;
  }

  /// ST-1 分類クラスから期待されるレイアウト種別（対応表・01a20785-89a5）。
  ///
  /// WHY portraitWithEmbedded / rotatedPortrait が hcV1: 前処理で埋め込み横
  /// 写真へ刈り出されるため、実 OCR 対象は hc 構図（プレーシェア）前提。
  /// arcadeResultFrame のみ acV1（ac_v1 アンカーパック・領域仕様の対象）。
  static LayoutKind _expectedLayoutOf(InputImageClass cls) =>
      cls == InputImageClass.arcadeResultFrame
      ? LayoutKind.acV1
      : LayoutKind.hcV1;

  // -----------------------------------------------------------------------
  // Stage 2: fieldOcr (ST-4)
  // -----------------------------------------------------------------------

  Future<void> _runFieldOcr(OcrPipelineContext context) async {
    final ocrImageFile = context.preprocessedImageFile ?? context.imageFile;

    // フルページ OCR（Uint8List 入力）。
    final pageResult = await engine.recognize(context.imageBytes!);
    context.pageResult = pageResult;

    // WHY: 領域クロップ・抽出には正規化座標変換用の画像寸法が必須。寸法を設定
    // しない fake engine（テスト用）や実装ミスでもパイプラインが止まらないよう、
    // 寸法欠落時は領域別 OCR・抽出をスキップして extractionResult を null のまま
    // にする（FR-3 の null フォールバックが対応）。
    if (pageResult.imageWidth == null || pageResult.imageHeight == null) {
      return;
    }

    // レイアウト種別の決定（v3 種別フロー・01a20785-89a5）。
    // hint 指定時は hint 優先。WHY: ST-1 前処理（回転補正・埋め込み抽出）と
    // レイアウト選択は直交するため、hint があっても分類（前処理の根拠）は潰さ
    // ないが、領域仕様とアンカーパックは hint 側のレイアウトで選ぶ（ユーザー
    // 選択の尊重・設計 §2）。hint 未指定時は従来どおり分類から決定（共有
    // インテント経由 = 現行挙動完全不変・裁定 A）。
    // ac_v1（アーケード実機）は hc_v1（プレーシェア）と列幾何が異なるため、
    // 別アンカーパック・別列窓を使用する
    // （docs/arcade_photo_geometry_analysis_2026-11-23.md §4）。
    final layoutKind = context.layoutHint != null
        ? _layoutKindOfHint(context.layoutHint!)
        : _expectedLayoutOf(
            // WHY: preProcess は常に実行済みのためここは通常 null にならない。
            // null 許容の防御として既定側（hc 側）へ倒す。
            context.imageClass ?? InputImageClass.landscapePlayShare,
          );
    context.layoutKind = layoutKind;

    // WHY ここで分岐: Lively はアンカー登録（AC/HC のパネル論理座標）を使わず、
    // 行ラベルの実測位置から P 単位で切る。以降のアンカー検出・領域 OCR・
    // 窓抽出は Lively の列幾何に合わないため、専用経路に渡して戻る。
    if (layoutKind == LayoutKind.livelyV1) {
      await _runLivelyOcr(context, pageResult);
      return;
    }

    final isAcV1 = layoutKind == LayoutKind.acV1;

    // ST-3.5: UI アンカー検出（領域 OCR の前に 1 回・設計 §2.5）。
    // WHY 同一ファイル: pageResult と同じ ocrImageFile に対して detect する
    // ため座標系が一致する（0070184 教訓・前処理クロップ空間と pageResult
    // 座標の不一致で領域 OCR が全滅した経験）。デコード失敗/パック欠落は
    // anchors = null で現行動作に落ちる（機能 OFF）。
    // hc_v1 は DIP ローダ（テスト差し替え可）、ac_v1 は直接アセットロード。
    final anchorPack = isAcV1
        ? await AnchorPack.loadFromAssets('ac_v1')
        : await _loadAnchorPack();
    final anchors = anchorPack == null
        ? null
        : AnchorRegistration.detect(ocrImageFile, anchorPack);
    context.anchorRegistration = anchors;

    // 領域別 OCR（Uint8List 入力）。
    final regionRunner = RegionOcrRunner(engine: engine);
    final regionResult = await regionRunner.run(
      pageResult,
      context.imageBytes!,
      anchors: anchors,
      layoutKind: layoutKind,
    );
    context.regionOcrResult = regionResult;

    // フィールド抽出（領域別 OCR 結果をマージ）
    final merged = FieldExtractor(layoutKind: layoutKind)
        .extractWithRegions(pageResult, regionResult.results);
    context.extractionResult = merged;
  }

  // -----------------------------------------------------------------------
  // Stage 3: songMatching (ST-5/ST-6)
  // -----------------------------------------------------------------------

  /// ST-5/ST-6 曲名照合。
  ///
  /// [RegionOcrResult] から曲名バンド（songTitle）の OCR 要素を取得し、
  /// [SongTitleElementMatcher] で行クラスタリング＋行内連結した候補を
  /// [SongTitleMatcher] に照合させる（正規化＋レーベンシュタイン距離・
  /// 要素単位の最良距離採用により genre 行混入へ対抗）。
  /// 辞書は [MergedSongRepository]（bundledSeed アセット + コンストラクタ注入の
  /// [mainSongRepository] / [additionalSongRepository]）を使用。
  ///
  /// 曲名バンドの要素が検出できない場合や辞書ロードに失敗した場合は
  /// [songMatchResult] を null のままにする。要素はあるが全て空白のみの
  /// 場合は不一致の [SongMatchResult] を返す（FR-3 で手入力を促す）。
  Future<void> _runSongMatching(OcrPipelineContext context) async {
    final songResult = context.regionOcrResult?.results[RegionTarget.songTitle];
    if (songResult == null || songResult.elements.isEmpty) {
      context.songMatchResult = null;
      return;
    }

    // 曲名候補の生成は SongTitleElementMatcher 側（行クラスタリング等）で行う。

    try {
      // ST-6: MergedSongRepository を構築（bundledSeed アセットをシードとして使用）
      final seedRepo = BundledSeedRepository();
      await seedRepo.load();

      // 優先順位（高→低）: localAdditional → downloadedMain → bundledSeed。
      // WHY: bundledSeed は常に含める（オフライン時フォールバック、spec §10）。
      // isAvailable=false の注入ソース（DB 未ダウンロード・ファイル欠落等）は
      // MergedSongRepository 側で自動スキップされるため、パイプライン側の
      // 分岐は不要。マージ済みリポジトリは毎 run 再構築するため、注入側で
      // DB 更新後にリポジトリを張り替えれば次 run から反映される。
      final sources = <SongRepository>[];
      final additionalRepo = additionalSongRepository;
      if (additionalRepo != null) {
        sources.add(additionalRepo);
      }
      final mainRepo = mainSongRepository;
      if (mainRepo != null) {
        sources.add(mainRepo);
      }
      sources.add(seedRepo);

      final mergedRepo = MergedSongRepository(sources: sources, loaders: const <BlobStoreSongRepositoryLoader>[]);

      context.songRepository = mergedRepo;

      // ST-5 本実装: 要素単位照合（genre 行混入対策）。
      // WHY: 曲名バンドには genre 行（例 SOFT ROCK LONG）が同写りになり、
      // 全文 join ではジャンル接頭辞で距離が膨らんで自動決定が破綻する
      // （実測: join 全文 0/7 vs 行単位 5/7・QA-Docs 検証計画書）。
      final matcher = SongTitleMatcher(mergedRepo);
      final elementMatcher = SongTitleElementMatcher(matcher);
      final matchResult = elementMatcher.match(songResult.elements);
      context.songMatchResult = matchResult;
      context.matchedSong = _resolveMatchedSong(matchResult, mergedRepo);
    } catch (e) {
      // 辞書ロード失敗 → songMatchResult は null のまま（FR-3 で手入力を促す）
      context.songMatchResult = null;
      context.matchedSong = null;
    }
  }

  /// 照合結果から解決済みエントリを引き直す（FR-6 §2-5 Plan A）。
  ///
  /// WHY: hasMatch かつ bestMatchNormalized があるときのみリポジトリから
  /// 実エントリを取得する。距離ゲートを設けないのは、23bjim 型「正照合だが
  /// auto 未達」でも後段の上限表示（VR-1）を有効にするため（0cfd9f0 §2・
  /// リード承認）。未解決（不成立・キーなし・辞書不在）は null。例外時は
  /// catch で songMatchResult と一体で null 化。
  SongEntry? _resolveMatchedSong(
    SongMatchResult? result,
    SongRepository repository,
  ) {
    if (result == null || !result.hasMatch) {
      return null;
    }
    final normalizedKey = result.bestMatchNormalized;
    if (normalizedKey == null) {
      return null;
    }
    return repository.findByNormalizedKey(normalizedKey);
  }
}
