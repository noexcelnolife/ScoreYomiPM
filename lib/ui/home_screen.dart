import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'sharing_intent_receiver.dart';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_info.dart';
import '../backup/backup_export_service.dart';
import '../backup/backup_import_service.dart';
import '../data/play_record.dart';
import '../data/play_record_bulk_writer.dart';
import '../data/memo_template_repository.dart';
import '../data/play_record_repository.dart';
import '../models/ocr_models.dart';
import '../ocr/field_extractor.dart';
import '../ocr/ocr_engine.dart';
import '../ocr/pipeline.dart';
import '../ocr/song_entry.dart';
import '../ocr/song_repository.dart';
import '../ocr/song_title_matcher.dart';
import '../platform/platform_capabilities.dart';
import '../songdb/song_database_service.dart';
import 'backup_screen.dart';
import 'capture_screen.dart';
import 'file_export_gateway.dart';
import 'ocr_result_screen.dart';
import 'play_records_screen.dart';
import 'song_db_section.dart';
import 'song_title_live_search.dart';
import 'species_selection_sheet.dart';

/// ホーム画面。
///
/// ギャラリーからプレーシェア画像を選択し、[OcrPipeline] で OCR を実行して
/// 結果確認画面 [OcrResultScreen] へ遷移する、PoC 動作確認用の最小フロー。
///
/// FR-4: OCR 失敗時（[OcrEngineException]）は画像だけの未確定レコードを
/// 自動保存し、AppBar の履歴アイコンから [PlayRecordsScreen]（FR-10 記録一覧）
/// を開ける。
///
/// WHY: OCR 実装は [HomeScreen.ocrEngine] としてコンストラクタ注入する（DIP）。
/// 具体実装（MlKitOcrEngine など）の生成はコンポジションルート（main.dart）
/// でのみ行い、UI からは抽象 [OcrEngine] だけを見せる。
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.ocrEngine,
    required this.songDatabaseService,
    required this.playRecordRepository,
    this.imagePicker,
    this.imagePickerFactory = ImagePicker.new,
    this.capabilities = const LocalCapabilities(),
    this.mainSongRepository,
    this.additionalSongRepository,
    this.sharingIntentReceiver,
    this.captureLauncher,
    this.memoTemplateRepository,
  });

  /// OCR 実行に使うエンジン。所有権は注入側（main.dart）にある。
  final OcrEngine ocrEngine;

  /// 収録曲辞書の取得・取り込みに使う DB 操作サービス（抽象のみを保持・DIP）。
  final SongDatabaseService songDatabaseService;

  /// FR-4: プレーシェア画像の保存先（未確定レコード自動保存・履歴で使用）。
  final PlayRecordRepository playRecordRepository;

  /// FR-4: テストで差し替える画像ピッカー（null ならファクトリで既定実装を生成）。
  final ImagePicker? imagePicker;

  /// この環境で可能な操作（撮影・共有インテント受信・辞書更新）。
  ///
  /// WHY(既定を全機能有効にするか): 既定は端末アプリの挙動であり、ブラウザ版は
  /// `main` から明示的に差し替える。既定を「何もできない」にすると、注入を忘れた
  /// 組み立てが静かに機能を失う。逆に既定を端末相当にしておけば、注入漏れは
  /// 「ブラウザで撮影ボタンが出る」という目に見える形で表面化する。
  final PlatformCapabilities capabilities;

  /// 未注入（null）時に既定実装を生成するファクトリ。既定は本物の ImagePicker。
  ///
  /// WHY: 2026-11-23 リリース検証で発見した不具合の是正。旧実装は
  /// `widget.imagePicker?.pickImage(...)` という null-aware 呼び出しのため、
  /// 本番（main.dart は imagePicker を DI しない）では pickImage 自体が
  /// 呼ばれず、シートが閉じるだけで取り込みが無音に失敗していた。フィールド
  /// doc の契約「null なら実装をその場で生成する」を実装に反映し、生成関数を
  /// 差し替え可能にして未注入経路をウィジェットテストで観測可能にする（DIP）。
  final ImagePicker Function() imagePickerFactory;

  /// OCR パイプラインへ渡すメイン DB リポジトリ（抽象のみを保持・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  /// null の場合はシード辞書のみで動作する（本番は main.dart から実体を渡す）。
  final SongRepository? mainSongRepository;

  /// OCR パイプラインへ渡すローカル追加 DB リポジトリ（抽象のみを保持・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  final SongRepository? additionalSongRepository;

  /// 共有インテント受信機（FR-1。省略時は共有インテント機能を無効化）。
  final SharingIntentReceiver? sharingIntentReceiver;

  /// FR-9 案A: 撮影ガイド枠付きアプリ内撮影画面の起動関数。
  ///
  /// WHY 注入可能にする: 実機では [CaptureScreen] を push するが、widget
  /// テストではカメラのプラットフォームチャネルが無いため、注入口から
  /// 「撮影成功 / fallback / 権限拒否 / ギャラリー / キャンセル」の分岐を
  /// 決定的に検証する（DIP）。null なら実装（Navigator push）を使う。
  final Future<CaptureOutcome?> Function()? captureLauncher;

  /// メモのテンプレート供給元（入力画面・詳細画面へ経由渡し・任意）。
  final MemoTemplateRepository? memoTemplateRepository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// ホーム画面の状態。
enum _HomePhase {
  /// 待機中（初期表示を含む）。
  idle,

  /// OCR 実行中。
  running,
}

/// [_selectImageAndRunOcr] の実行結果。
///
/// 成功時は [pageResult]、失敗時は [errorMessage] が非 null になる。
/// [extractionResult] は ST-4 のフィールド抽出結果で、失敗時や
/// パイプラインが抽出を実行しなかった場合は null（結果画面は
/// 要素一覧表示へフォールバックする）。
class _OcrRunOutcome {
  const _OcrRunOutcome.success(
    this.pageResult,
    this.extractionResult, {
    this.songMatchResult,
    this.matchedSong,
    this.layoutMismatchFlag = false,
  }) : errorMessage = null;

  const _OcrRunOutcome.failure(this.errorMessage)
    : pageResult = null,
      extractionResult = null,
      songMatchResult = null,
      matchedSong = null,
      // WHY: 失敗経路では context を失い不一致フラグを取得できないため false
      //（警告は成功経路のみ・失敗時はエラーメッセージ表示が優先）。
      layoutMismatchFlag = false;

  /// OCR 成功時のページ結果。
  final OcrPageResult? pageResult;

  /// OCR 成功時のフィールド抽出結果（未抽出なら null）。
  final FieldExtractionResult? extractionResult;

  /// OCR 成功時の曲名マッチ結果（FR-3 の曲名欄事前入力に使用）。
  final SongMatchResult? songMatchResult;

  /// FR-6 段階 B: 総ノーツ数ソース（VR-1/VR-3 用）。
  ///
  /// WHY: pipeline.run() の戻り値 context に matchedSong が既に含まれるため、
  /// songMatchResult と同じ分解位置で読み取るだけ。lib/ocr 変更は不要
  /// （設計 docs/fr6_stage_b_vr1_vr3_design_confirmation_2026-11-22.md §1）。
  final SongEntry? matchedSong;

  /// v3: 種別選択フローの不一致フラグ（選択種別の hint と ST-1 分類の期待
  /// レイアウトが不一致のとき true）。
  ///
  /// WHY: FR-3 遷移前に SnackBar 警告のみで処理を継続させる（裁定 D・
  /// docs/v3_input_source_flow_design_2026-11-23.md §2）ための判断材料。
  /// フラグは pipeline 内 ST-1 分類直後に判定済み（コミット 0491817）。OCR
  /// 例外時（failure 経路）は context を失うため false のまま（警告は成功
  /// 経路のみ・失敗時はエラーメッセージ表示が優先）。
  final bool layoutMismatchFlag;

  /// 失敗時にユーザーへ表示するメッセージ。
  final String? errorMessage;
}

class _HomeScreenState extends State<HomeScreen> {
  /// 最近の記録セクションに表示する件数（v4 案1・設計 §2.5）。
  static const int _recentRecordCount = 3;

  _HomePhase _phase = _HomePhase.idle;
  File? _selectedImage;
  String? _errorMessage;

  /// 最近の記録（未取得・取得失敗時は null = セクション非表示）。
  List<PlayRecord>? _recentRecords;

  /// 写真なし手入力モードで確認・修正画面を開く（v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.1）。
  ///
  /// WHY: 実機写真の OCR が現状苦手なため、写真を使わず数値を直接入力して
  /// 確定保存できる入口を実利用の動線として用意する。手入力モード自体は
  /// FR-4 で実装済みの OcrResultScreen（pageResult/extraction/existingRecord
  /// なし）を再利用する。
  ///
  /// WHY [machine]（v5 機能 A・設計 §3）: 種別選択シートで選ばれた機種の初期値。
  /// 設計文書は route の既存仮引数として説明したが実コードに initialLevel 等は
  /// 存在せず、本引数と route の initialMachine は新規追加となる（観測済み事実）。
  Future<void> _openManualEntry(String? machine) async {
    await Navigator.of(context).push(
      OcrResultScreen.route(
        playRecordRepository: widget.playRecordRepository,
        appBarTitle: 'スコア手入力',
        initialMachine: machine,
        // WHY(01a21152): 手入力も曲名入力の入口なので、一次 OCR 経路と同じ
        // ライブサジェストを配線する（ユーザー要望「曲名DBをもとに曲名サジェスト」）。
        onSongTitleSearch: _searchSongTitle,
        onSongEntryResolve: _resolveSongEntry,
        // WHY: ライブ候補は 3 件で打ち切るため、目当ての曲が出ない場合に
        // 全件検索画面へ移れるようにする（ユーザー要望 2026-11-25）。
        onSongSearchWide: _liveSongSearch.searchWide,
        memoTemplateRepository: widget.memoTemplateRepository,
      ),
    );
    // WHY(案1と同じ理由): 保存された記録を最近の記録セクションへ反映する。
    if (!mounted) {
      return;
    }
    _refreshRecentRecords();
  }

  /// 記録一覧（FR-10・FR-4 で実装した履歴導線の発展）を開く。
  Future<void> _openPlayRecords() async {
    await Navigator.of(context).push(
      PlayRecordsScreen.route(
        playRecordRepository: widget.playRecordRepository,
        ocrEngine: widget.ocrEngine,
        mainSongRepository: widget.mainSongRepository,
        additionalSongRepository: widget.additionalSongRepository,
        memoTemplateRepository: widget.memoTemplateRepository,
      ),
    );
    // WHY(v4 案1): 一覧・詳細から戻ったら記録が変わっている可能性があるため
    // 最近の記録セクションを更新する。
    if (!mounted) {
      return;
    }
    _refreshRecentRecords();
  }

  /// 最近の記録を再読込する（v4 案1・設計 §2.5）。
  ///
  /// WHY: 取得失敗時はセクション非表示のまま graceful に劣化させる
  ///（エラーカードは取り込み系の失敗専用のため）。例外を握り潰す意図を
  /// コメントで明示する（empty_catches 対応）。
  Future<void> _refreshRecentRecords() async {
    try {
      final List<PlayRecord> all = await widget.playRecordRepository.listAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _recentRecords = all;
      });
    } catch (_) {
      // WHY: 取得失敗時はセクション非表示で継続する（設計 §2.5）。
    }
  }

  /// v2 UX #13/#15: ライブ曲名検索（シード＋配布辞書＋追加辞書のマージと
  /// そのキャッシュ）を 1 オブジェクトに集約したもの。
  ///
  /// WHY: 曲名入力の全入口（一次 OCR・手入力・記録詳細の修正/再OCR）で同じ
  /// 辞書検索を使うため [LiveSongTitleSearch] に切り出した（01a21152）。
  /// 辞書の構築は初回検索時に 1 度だけで、OCR run の開始時に [invalidate] する。
  ///
  /// WHY(#13 フォローアップ・検収裁定 2026-11-23): pipeline 側は毎 run で
  /// MergedSongRepository を再構築する（DB 更新が次 run から反映される原則・
  /// pipeline.dart の WHY）。ライブ検索もこれに揃え、_runOcr が pipeline.run()
  /// を呼ぶ直前にキャッシュを捨てる。アプリ生存中の 1 回構築のままだと DB 更新後に
  /// OCR 経路（新辞書）とライブ検索経路（旧キャッシュ）で候補が分裂する。
  late final LiveSongTitleSearch _liveSongSearch = LiveSongTitleSearch(
    mainSongRepository: widget.mainSongRepository,
    additionalSongRepository: widget.additionalSongRepository,
  );

  /// 辞書セクションのタイトル行（マージ辞書の総曲数）を再取得させるための世代番号。
  ///
  /// WHY: 件数は [LiveSongTitleSearch] のキャッシュ越しに取るため、辞書が
  /// 差し替わったら invalidate したうえで子に「取り直せ」と伝える必要がある。
  int _songDbRevision = 0;

  /// 辞書が差し替わったときの後始末（子の SongDbSection から呼ばれる）。
  Future<void> _handleSongDbChanged() async {
    if (!mounted) return;
    await (widget.mainSongRepository as ReloadableSongRepository?)?.reload();
    await (widget.additionalSongRepository as ReloadableSongRepository?)?.reload();
    // WHY: 古い辞書のままのキャッシュを捨て、タイトル行の件数を読み直させる。
    _liveSongSearch.invalidate();
    setState(() {
      _songDbRevision++;
    });
  }

  /// v2 UX #13: 曲名手入力のライブ辞書検索（OcrResultScreen へ注入）。
  ///
  /// WHY: 辞書ロード失敗時は null を返してライブ検索を無効化する（チップは
  /// OCR 時点の静的結果へフォールバック・OCR 経路の songMatchResult = null
  /// と同じ graceful な挙動）。
  Future<SongMatchResult?> _searchSongTitle(String title) {
    return _liveSongSearch.search(title);
  }

  /// 初期化：共有インテント（冷起動・温起動）を受け付ける。
  ///
  /// 冷起動: アプリ未起動時に共有された画像 → getInitialMedia() で取得 → OCR 実行
  /// 温起動: メモリ上アプリへの共有 → imagePathStream 購読 → OCR 実行
  ///
  /// WHY: receive_sharing_intent の two-tier API を両方カバー。sharingIntentReceiver
  /// が null の場合は機能を無効化（後方互換）。
  @override
  void initState() {
    super.initState();
    // WHY(v4 案1): receiver が null の場合も早期 return で抜けるため、
    // 最近の記録の初回読込は早期 return より前に行う。
    _refreshRecentRecords();
    final SharingIntentReceiver? receiver = widget.sharingIntentReceiver;
    if (receiver == null) return;

    // WHY(能力で購読を囲むか): ブラウザには共有インテントの受け口が無く、
    // 購読を張るとプラグイン未実装の例外でホーム画面の構築ごと失敗する。
    // 受信できる環境でだけ冷起動チェックと購読を行う。
    if (!widget.capabilities.canReceiveShareIntent) return;

    // 冷起動：起動直後に初期インテントをチェック
    receiver.getInitialImagePath().then((String? path) {
      if (!mounted) return;
      if (path != null) {
        _handleSharedImage(File(path));
      }
    });

    // 温起動：ストリーム購読
    _sharingSubscription = receiver.imagePathStream.listen((String path) {
      if (!mounted) return;
      _handleSharedImage(File(path));
    });
  }

  /// 共有インテントストリーム購読（dispose で解放）。
  StreamSubscription<String>? _sharingSubscription;

  @override
  void dispose() {
    _sharingSubscription?.cancel();
    widget.sharingIntentReceiver?.cancel();
    super.dispose();
  }

  /// v2 UX #15: 候補選択時の曲エントリ解決（OcrResultScreen へ注入）。
  ///
  /// WHY: 候補（SongMatchCandidate）は SongEntry を持たないため、チップ選択
  /// だけでは VR 検証用の総ノーツ数が解決できない（ユーザー裁定「手入力でも
  /// 総ノーツ数をリンク」2026-11-23）。ライブ検索と同一のマージ済み辞書で
  /// findByNormalizedKey を解決する。辞書ロード失敗時は null（リンクなし・
  /// 従来の VR 欠損 skip）を返す。
  Future<SongEntry?> _resolveSongEntry(String normalizedTitle) {
    return _liveSongSearch.resolve(normalizedTitle);
  }

  /// OCR を実行し、成否を [_OcrRunOutcome] として返す。
  ///
  /// WHY: OCR 失敗（[OcrEngineException]）は UI に見える形で扱いたいが、
  /// 例外をそのまま伝播させると実行中状態から抜けられないため、ここで
  /// 成否レコードへ変換する。
  ///
  /// v3（01a20785-a302）: [layoutHint] は種別選択シートでユーザーが選択した
  /// 対象種別。null のときは ST-1 自動分類のみでレイアウトを決定する（共有
  /// インテント経由 = 現行挙動完全不変・裁定 A）。
  Future<_OcrRunOutcome> _runOcr(
    File imageFile, {
    InputLayoutHint? layoutHint,
  }) async {
    // WHY(#13 フォローアップ・検収裁定 2026-11-23): pipeline 側は毎 run で
    // MergedSongRepository を再構築するため、ライブ検索の辞書キャッシュも
    // pipeline.run() 呼び出し直前で捨てて各 OCR run 開始時点の辞書で
    // 再構築させる。これがないと DB 更新後に OCR 経路とライブ検索経路で辞書が
    // 分裂する。コストは run あたり 1 回の seed ロードで pipeline と同等。
    _liveSongSearch.invalidate();
    final OcrPipeline pipeline = OcrPipeline(
      engine: widget.ocrEngine,
      mainSongRepository: widget.mainSongRepository,
      additionalSongRepository: widget.additionalSongRepository,
    );
    try {
      final OcrPipelineContext context = await pipeline.run(
        imageFile,
        layoutHint: layoutHint,
      );
      final OcrPageResult? pageResult = context.pageResult;
      if (pageResult == null) {
        return const _OcrRunOutcome.failure('OCR結果を取得できませんでした。');
      }
      return _OcrRunOutcome.success(
        pageResult,
        context.extractionResult,
        songMatchResult: context.songMatchResult,
        // FR-6 段階 B: SongMatchResult と同一の context 分解位置で渡す（設計 §1）。
        matchedSong: context.matchedSong,
        // v3: 不一致フラグは pipeline 内 ST-1 分類直後に判定済み（0491817）。
        // 失敗経路では例外で context を失うため false のまま。
        layoutMismatchFlag: context.layoutMismatchFlag,
      );
    } on OcrEngineException catch (error) {
      // FR-4: OCR 実行系の失敗のみ、画像を失わないよう未確定レコードとして
      // 自動保存する（設計書 §4 フロー 2）。想定外のエラーは従来どおり
      // メッセージ表示のみとする。
      await _savePendingOnFailure(await imageFile.readAsBytes());
      return _OcrRunOutcome.failure('OCRの実行に失敗しました: ${error.message}');
    } catch (error) {
      // WHY: PoC では想定外の例外も握りつぶさず、エラーカードへ出して
      // 動作確認できるようにする。
      return _OcrRunOutcome.failure('想定外のエラーが発生しました: $error');
    }
  }

  /// OCR 失敗時にプレーシェア画像だけの未確定レコードを自動保存する。
  ///
  /// WHY: プレーシェア画像は一度きりの情報源で、失敗時に破棄すると手入力の
  /// 機会を失う。自動保存自体の失敗はログのみに留め、元の OCR 失敗メッセージ
  /// 表示を優先させる（二重のエラー演出をしない）。
  Future<void> _savePendingOnFailure(Uint8List imageBytes) async {
    try {
      await widget.playRecordRepository.create(
        PlayRecordDraft(
          songName: null,
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
        imageBytes,
      );
    } catch (error) {
      developer.log('未確定レコードの自動保存に失敗: $error');
      return;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('OCRに失敗したため未確定レコードとして保存しました')),
    );
  }

  /// 共有インテントで受け取った画像に対して OCR を実行し、結果画面へ遷移する。
  ///
  /// 冷起動・温起動のいずれの共有イベントもこの経路を通る。#13-F のキャッシュ
  /// 契約を壊さず、既存の OcrResultScreen 遷移を再利用する。
  ///
  /// WHY: _selectImageAndRunOcr と共通の後処理（setState・_runOrc・ページ遷移・
  /// プレビュー解除）を一つのメソッドに抽出し、両フローで共有する。
  ///
  /// v3（01a20785-a302）: [layoutHint] は種別選択シート経由の呼び出しでのみ
  /// 非 null。共有インテント経由（_handleSharedImage）は null を渡す（裁定 A）。
  /// v5 機能 A: [initialMachine] も種別選択シート経由のみ非 null（裁定 A 踏襲）。
  Future<void> _runOcrAndNavigate(
    File imageFile, {
    InputLayoutHint? layoutHint,
    String? initialMachine,
  }) async {
    setState(() {
      _selectedImage = imageFile;
      _phase = _HomePhase.running;
      _errorMessage = null;
    });
    final _OcrRunOutcome outcome = await _runOcr(
      imageFile,
      layoutHint: layoutHint,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = _HomePhase.idle;
      _errorMessage = outcome.errorMessage;
    });
    // v3（裁定 D・01a20785-a302）: 選択種別と画像形式の不一致は SnackBar で
    // 警告するのみ。OCR の処理と画面遷移は継続させる（遮断しない）。フラグは
    // 成功経路でのみ context から取得できる（失敗経路は false・エラー表示優先）。
    if (outcome.layoutMismatchFlag) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('選択した種別と画像の形式が一致していない可能性があります')),
      );
    }
    final OcrPageResult? pageResult = outcome.pageResult;
    if (pageResult != null) {
      await Navigator.of(context).push(
        OcrResultScreen.route(
          // WHY(ここで読まないか): 原画像の読み込みは実 I/O。遷移の直前に
          // await すると、画面が出るまでディスク待ちになる。読むのは遷移先
          // （プレビュー表示と保存の直前）に任せ、関数だけ渡す。
          loadImageBytes: imageFile.readAsBytes,
          pageResult: pageResult,
          extractionResult: outcome.extractionResult,
          songMatchResult: outcome.songMatchResult,
          matchedSong: outcome.matchedSong,
          playRecordRepository: widget.playRecordRepository,
          initialMachine: initialMachine,
          onSongTitleSearch: _searchSongTitle,
          onSongEntryResolve: _resolveSongEntry,
          onSongSearchWide: _liveSongSearch.searchWide,
          memoTemplateRepository: widget.memoTemplateRepository,
        ),
      );
      if (!mounted) {
        return;
      }
      // WHY(v2 UX 改修1): プレーシェア画像は 1 回の取り込みで消化される情報源。
      // 編集を終えて home に戻ったらプレビューをクリアし、次の取り込みを阻害
      // しない。OCR 失敗などで遷移していない場合（pageResult == null）は
      // エラーカードと合わせて取り込み直しの文脈として画像を保持する。
      setState(() {
        _selectedImage = null;
      });
      // WHY(v4 案1): 確認・修正画面で保存/未確定保存が行われた可能性がある
      // ため、ホーム復帰時に最近の記録を更新する。
      _refreshRecentRecords();
    }
  }

  /// v3: 入力ソース種別選択シートを開き、選択種別の入口アクションを実行する。
  ///
  /// WHY(docs/v3_input_source_flow_design_2026-11-23.md §1・2026-11-23 裁定済み):
  /// ユーザー指示「画像選択もしくは写真撮影開始の前に、対象のゲーム機・リザルト
  /// 表示方法の種類を選択するフローが必要」の実装。選択種別は [InputLayoutHint]
  /// としてパイプラインへ渡す。分類との不一致は SnackBar 警告のみで処理継続
  /// （裁定 D）。共有インテント経由（FR-1）は本シートを通らず hint なしのまま
  /// （裁定 A・現行挙動不変）。
  ///
  /// WHY 行構成の詳細（カメラ行の無効・Lively 準備中・2 アクション常時表示）は
  /// SpeciesSelectionSheet 側の doc コメントに記録（SRP）。
  Future<void> _openSpeciesSelectionSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // WHY: シート本体は SpeciesSelectionSheet（lib/ui/species_selection_
      // sheet.dart）へ抽出（SRP・関数長規約）。入口アクションはコールバックで
      // 委譲し、layoutHint の注入はこの側で行う。
      builder: (BuildContext sheetContext) {
        return SpeciesSelectionSheet(
          // WHY(v5 機能 A・設計 §3): シートが選んだ機種を各入口アクションの
          // 引数として受け取り、OCR 画面 / 手入力画面の初期値へ流す。
          // 共有インテント経由（_handleSharedImage）はシートを通らないため
          // 機種 null のまま（裁定 A 踏襲）。
          onPickPlayShare: (String? machine) => _selectImageAndRunOcr(
            layoutHint: InputLayoutHint.hcV1,
            machine: machine,
          ),
          onPickResultGallery: (String? machine) => _selectImageAndRunOcr(
            layoutHint: InputLayoutHint.acV1,
            machine: machine,
          ),
          onPickResultCamera: (String? machine) =>
              _pickImageAndRunOcrCamera(machine: machine),
          // WHY livelyV1 をここで注入するか: Lively は画像だけでは HC と
          // 区別できない（アスペクト比・構図が重なる）。入口で種別を確定し、
          // パイプライン側で専用経路（統合ストラテジー）へ振り分ける。
          onPickLivelyGallery: (String? machine) => _selectImageAndRunOcr(
            layoutHint: InputLayoutHint.livelyV1,
            machine: machine,
          ),
          // WHY カメラも livelyV1 で流すか（2026-11-26 のユーザー指示「HC の
          // カメラで撮影のようにその場で枠線付きのカメラを起動することはできますか」）:
          // 撮影した画像も「PC 画面を写した写真」であり、ガイド枠で狙いを付けた
          // あとの切り出しは LivelyOcrRoute が行う。入口で種別が確定しているので、
          // カメラ経由でも専用経路に振り分けられる。
          onPickLivelyCamera: (String? machine) => _pickImageAndRunOcrCamera(
            layoutHint: InputLayoutHint.livelyV1,
            machine: machine,
          ),
          onManualEntry: (String? machine) => _openManualEntry(machine),
        );
      },
    );
  }

  /// 実際に使用する画像ピッカー（注入を優先し、未注入ならファクトリで生成）。
  ///
  /// WHY: null-aware 呼び出し（`?.pickImage`）は未注入時にメソッド自体を
  /// 呼ばないため「生成して使う」契約を実現できなかった。生成と使用を
  /// この getter に一本化し、全呼び出し箇所で同じ経路を通す。
  ImagePicker get _imagePicker =>
      widget.imagePicker ?? widget.imagePickerFactory();

  /// 画像ピッカーで選択した画像に対して OCR を実行し、結果画面へ遷移する。
  ///
  /// WHY: UI ボタンから呼び出されるエントリポイント。_runOcrAndNavigate の薄いラッパ。
  Future<void> _selectImageAndRunOcr({
    InputLayoutHint? layoutHint,
    String? machine,
  }) async {
    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (picked == null) {
      // ユーザーが選択をキャンセルした場合は何もしない。
      return;
    }
    final File imageFile = File(picked.path);
    // WHY(v5 機能 A): シートで選ばれた機種だけを OCR 画面の初期値へ渡す。
    await _runOcrAndNavigate(
      imageFile,
      layoutHint: layoutHint,
      initialMachine: machine,
    );
  }

  /// カメラで撮影して OCR を実行し、結果画面へ遷移する。
  ///
  /// FR-9 カメラ撮影入口: Windows 等では非表示（platform gate）なので、
  /// ここでは Android 環境でのみ呼ばれる想定。
  /// pickImage 例外（例：カメラ未接続など）は try/catch で捕捉し、
  /// SnackBar でユーザーに通知した後、アプリ状態を破損させない。
  ///
  /// FR-9 案A（2026-11-24 ユーザー指示「撮影ガイド枠を実装してください」）:
  /// まずアプリ内のガイド枠付き撮影画面を提示し、撮影結果を既存 OCR 経路へ
  /// 合流させる。撮影画面が初期化できない場合（fallback）だけ、従来の
  /// image_picker カメラ経路へ降りる（v3 基線 845997d/4909a58 を防御層として
  /// 維持するリード契約）。
  ///
  /// WHY [layoutHint] を引数化したか（2026-11-26 のユーザー指示で Lively の
  /// カメラ入口を追加）: 撮影画像をどの種別として読むかは入口で決まる。以前は
  /// アーケードのリザルト写真しか撮影入口が無かったため acV1 固定だった。
  /// 既定を acV1 にして、HC 側の呼び出しはそのままの意味を保つ。
  Future<void> _pickImageAndRunOcrCamera({
    String? machine,
    InputLayoutHint layoutHint = InputLayoutHint.acV1,
  }) async {
    final CaptureOutcome? outcome = await _launchCaptureScreen();
    if (!mounted) {
      return;
    }
    switch (outcome?.kind) {
      case CaptureOutcomeKind.captured:
        final String? path = outcome?.path;
        if (path == null) {
          return;
        }
        await _runOcrAndNavigate(
          File(path),
          layoutHint: layoutHint,
          initialMachine: machine,
        );
        return;
      case CaptureOutcomeKind.gallery:
        await _selectImageAndRunOcr(layoutHint: layoutHint, machine: machine);
        return;
      case CaptureOutcomeKind.permissionDenied:
        // SnackBar（権限がありません→ギャラリー案内）は撮影画面が出済み。
        // ここではギャラリー選択へ誘導する（FR-9 §4 整合）。
        await _selectImageAndRunOcr(layoutHint: layoutHint, machine: machine);
        return;
      case CaptureOutcomeKind.fallback:
        break; // 下の従来経路へフォールバック
      case null:
        return; // ユーザーが撮影画面を閉じた
    }
    try {
      final XFile? picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
      );
      if (picked == null) {
        // ユーザーが撮影をキャンセルした場合は何もしない。
        return;
      }
      final File imageFile = File(picked.path);
      await _runOcrAndNavigate(
        imageFile,
        layoutHint: layoutHint,
        initialMachine: machine,
      );
    } catch (e) {
      // FR-9 §4: pickImage 例外の堅牢化
      // クラッシュなし・状態破損なしで SnackBar 表示のみとする。
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('カメラを利用できません')));
    }
  }

  /// 撮影ガイド画面を開く（注入があれば優先・DIP）。
  Future<CaptureOutcome?> _launchCaptureScreen() {
    final Future<CaptureOutcome?> Function()? launcher = widget.captureLauncher;
    if (launcher != null) {
      return launcher();
    }
    return Navigator.of(context).push<CaptureOutcome>(
      MaterialPageRoute<CaptureOutcome>(builder: (_) => const CaptureScreen()),
    );
  }

  /// 共有インテントで受け取った画像に対して OCR を実行し、結果画面へ遷移する。
  ///
  /// 冷起動・温起動のいずれの共有イベントもこの経路を通る。#13-F のキャッシュ
  /// 契約を壊さず、既存の OcrResultScreen 遷移を再利用する。
  ///
  /// WHY: _selectImageAndRunOcr と共通の後処理（setState・_runOcr・ページ遷移・
  /// プレビュー解除）を一つのメソッドに抽出し、両フローで共有する。
  ///
  /// v3（裁定 A・01a20785-a302）: 共有インテント経由は種別選択シートを通らず、
  /// hint なし（自動分類）のまま。テスト home_screen_species_sheet_test.dart が
  /// この不変条件を固定する。
  Future<void> _handleSharedImage(File imageFile) async {
    await _runOcrAndNavigate(imageFile);
  }

  /// バックアップ画面を開く（タスク 01a20c14）。
  ///
  /// WHY(都度生成): どちらのサービスも状態を持たず、リポジトリを参照するだけ。
  /// ホームの状態として保持すると widget 差し替え（テスト）で追随が要るので、
  /// 遷移のたびに組み立てる。
  ///
  /// WHY(実行時判定): ホームが保持する型は PlayRecordRepository であり、
  /// PlayRecordBulkWriter を実装している保証が型に無い（実体の
  /// FilePlayRecordRepository は両方を実装するが、テスト用 fake は片方だけの
  /// ことがある）。実装していない場合は importService を渡さず、
  /// バックアップ画面側が「復元を利用できません」と表示する。
  Future<void> _openBackup(BackupAction action) async {
    final PlayRecordRepository repository = widget.playRecordRepository;
    // WHY(as で明示する): 型の絞り込みは、判定する型が宣言型の部分型である
    // ときしか効かない。PlayRecordBulkWriter と PlayRecordRepository は
    // 無関係な interface なので is 判定だけでは writer に渡せない（実測:
    // argument_type_not_assignable）。is の内側なので失敗しない。
    final BackupImportService? importService;
    if (repository is PlayRecordBulkWriter) {
      importService = BackupImportService(
        listRecords: repository.listAll,
        writer: repository as PlayRecordBulkWriter,
        // メモのテンプレートは記録とは別のファイルなので、専用の repository を
        // 渡さない限り ZIP に同梱されない（null なら従来どおり記録のみ）。
        memoTemplateRepository: widget.memoTemplateRepository,
      );
    } else {
      importService = null;
    }
    final bool? changed = await Navigator.of(context).push<bool>(
      BackupScreen.route(
        exportService: BackupExportService(
          repository: repository,
          appVersion: kAppVersion,
          memoTemplateRepository: widget.memoTemplateRepository,
        ),
        fileGateway: const PlatformFileExportGateway(),
        importService: importService,
        // 復元の確認ダイアログに出す「既存の記録」件数。取得失敗時は
        // バックアップ画面側が行ごと省く（復元は止めない）。
        existingRecordCount: () async => (await repository.listAll()).length,
        initialAction: action,
      ),
    );
    if (!mounted) {
      return;
    }
    // 復元で 1 件以上入ったときだけ true が返る。ホームの最近の記録は
    // そのままだと古いままなので取り直す。
    if (changed ?? false) {
      await _refreshRecentRecords();
    }
  }

  /// エクスポート・インポートの導線（タスク 01a20c14）。
  ///
  /// WHY(閉じた状態): 曲辞書と同じく「たまに使う管理系の操作」なので、
  /// ホームの主要動線（記録する）を押し下げないよう既定は折りたたむ。
  Widget _buildBackupSection() {
    return ExpansionTile(
      key: const ValueKey<String>('home-backup-section'),
      title: const Text('エクスポート・インポート'),
      children: <Widget>[
        ListTile(
          key: const ValueKey<String>('home-backup-export-zip'),
          title: const Text('ZIP でバックアップ'),
          subtitle: const Text('記録と画像をまとめて 1 つのファイルに保存します'),
          onTap: () => _openBackup(BackupAction.exportZip),
        ),
        ListTile(
          key: const ValueKey<String>('home-backup-export-csv'),
          title: const Text('CSV で出力'),
          subtitle: const Text('表計算ソフトで開ける形式で保存します（画像なし）'),
          onTap: () => _openBackup(BackupAction.exportCsv),
        ),
        ListTile(
          key: const ValueKey<String>('home-backup-restore'),
          title: const Text('バックアップから復元'),
          subtitle: const Text('ZIP ファイルから記録と画像を戻します'),
          onTap: () => _openBackup(BackupAction.restore),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('スコアヨミPM'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('pending-records-button'),
            tooltip: '記録一覧',
            icon: const Icon(Icons.history),
            onPressed: _openPlayRecords,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // WHY(v4 案1・設計 §2.2): 実利用では「記録する」が主役の操作
                // のため CTA を最上位に置き、曲辞書を最下位（折りたたみ）へ
                // 下げる。
                _buildActionSection(theme),
                _buildImageSection(theme),
                _buildRecentRecordsSection(theme),
                _buildSongDbSection(),
                // WHY(曲辞書の直後): リード指示 2026-11-24。v4 案1 では曲辞書を
                // 最下位に置いていたが、管理系の操作どうしを並べる指示が優先。
                _buildBackupSection(),
                _buildErrorSection(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 最近の記録セクションを組み立てる（v4 案1・docs/v4_home実用化_design_2026-11-23.md §2.5）。
  ///
  /// WHY: 実利用では「前回までの記録」がホームから見えると再入動線になる。
  /// 未取得・0 件・取得失敗時は非表示にして空状態のノイズを避ける
  ///（設計 §2.5・リード裁定）。
  Widget _buildRecentRecordsSection(ThemeData theme) {
    final List<PlayRecord>? recent = _recentRecords;
    if (recent == null || recent.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<PlayRecord> sorted = <PlayRecord>[...recent]
      ..sort((PlayRecord a, PlayRecord b) => b.playedAt.compareTo(a.playedAt));
    final List<PlayRecord> topRecords = sorted
        .take(_recentRecordCount)
        .toList(growable: false);
    final int pendingCount = recent
        .where((PlayRecord record) => record.status == PlayRecordStatus.pending)
        .length;
    return Column(
      key: const ValueKey<String>('home-recent-records'),
      children: <Widget>[
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text('最近の記録')),
                    if (pendingCount > 0)
                      Container(
                        key: const ValueKey<String>('home-pending-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '未確定 $pendingCount件',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
              for (int index = 0; index < topRecords.length; index++)
                _recentRecordTile(topRecords[index], index),
            ],
          ),
        ),
      ],
    );
  }

  /// 最近の記録 1 行を組み立てる。タップで記録一覧（FR-10）を開く。
  Widget _recentRecordTile(PlayRecord record, int index) {
    final String? songName = record.songName;
    return ListTile(
      key: ValueKey<String>('home-recent-record-$index'),
      title: Text(songName ?? '（曲名未入力）'),
      subtitle: Text(_formatDay(record.playedAt)),
      trailing: Text(record.score?.toString() ?? '—'),
      onTap: _openPlayRecords,
    );
  }

  /// 実施日を画面表示用に整形する（intl 依存を避ける簡易形式）。
  String _formatDay(DateTime date) => '${date.year}/${date.month}/${date.day}';

  /// 収録曲辞書セクションを折りたたみ（閉じた状態）で表示する（v4 案1・設計 §2.4）。
  ///
  /// WHY: 実利用では毎回操作しないため既定は閉じて画面ノイズを減らす。
  /// 展開時のみ SongDbSection（ヘッダ無し）を表示する。
  Widget _buildSongDbSection() {
    // WHY(能力が無い環境では節ごと出さないか): 辞書の配信更新・追加取り込みは
    // 端末のファイルを差し替える操作で、ブラウザには該当する保存先が無い。
    // 押すと必ず失敗する入口を残すより、節そのものを出さない方が誤解が少ない。
    // 曲名のサジェストは同梱シードで動くため、この節を隠しても検索は成立する。
    if (!widget.capabilities.canUpdateSongDatabase) {
      return const SizedBox.shrink();
    }
    return ExpansionTile(
      title: const Text('収録曲辞書'),
      // WHY(案A): 折りたたみ中でも辞書の規模が分かるよう、サジェスト対象の
      // 総曲数（マージ辞書の length）をタイトル行に常時表示する。
      subtitle: SongDbTotalCountSubtitle(
        loadTotalCount: _liveSongSearch.totalSongCount,
        refreshToken: _songDbRevision,
      ),
      initiallyExpanded: false,
      children: <Widget>[
        SongDbSection(
          songDatabaseService: widget.songDatabaseService,
          showHeader: false,
          seedSongCount: _liveSongSearch.seedSongCount,
          totalSongCount: _liveSongSearch.totalSongCount,
          onDictionaryChanged: _handleSongDbChanged,
        ),
      ],
    );
  }

  /// 選択済み画像のプレビュー、または未選択時の案内を表示する。
  Widget _buildImageSection(ThemeData theme) {
    final File? selectedImage = _selectedImage;
    if (selectedImage != null) {
      return Column(
        children: <Widget>[
          Card(
            clipBehavior: Clip.antiAlias,
            child: Image.file(selectedImage, fit: BoxFit.contain),
          ),
          const SizedBox(height: 24),
        ],
      );
    }
    return _buildIdleIntro(theme);
  }

  /// 画像未選択時の案内表示。
  Widget _buildIdleIntro(ThemeData theme) {
    // WHY(画像を扱えない環境で文言を差し替えるか): 「リザルト画面を選択して
    // OCR で読み取る」は、その手段が無い環境では実行できない指示になる。
    // 代わりに、実際に使える導線（手入力・バックアップ復元）を案内する。
    if (!widget.capabilities.canCaptureImages) {
      return Column(
        children: <Widget>[
          Icon(Icons.edit_note, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'ブラウザ版は画像からの読み取りに対応していません。'
            '記録は手入力か、バックアップの復元で追加してください',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
        ],
      );
    }
    return Column(
      children: <Widget>[
        Icon(Icons.image_outlined, size: 72, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'リザルト画面を選択して\nOCRでスコアを自動読み取りします',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// OCR 実行中はローディング表示、それ以外は画像選択ボタンを表示する。
  ///
  /// FR-8: プレーシェア画像の失効をボタン直下に常設ガイドする
  ///（案1・ユーザー確定 2026-11-22・設計確認書 §1/§2）。OCR 実行中はボタンごと
  /// スピナーに置換されるため、ガイドも自然に消える（追加分岐なし）。
  Widget _buildActionSection(ThemeData theme) {
    if (_phase == _HomePhase.running) {
      return const Column(
        children: <Widget>[
          // WHY: 外側 Column が CrossAxisAlignment.stretch のため Center で包まないと
          // スピナーが横幅いっぱいに引き伸ばされ楕円に見える。36px 中央表示を維持する。
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 16),
          Center(child: Text('OCRを実行中…')),
        ],
      );
    }
    // WHY(画像を取り込めない環境でボタンを差し替えるか): 撮影・ギャラリー
    // 取り込みは OCR が前提で、その手段が無い環境では押しても必ず失敗する。
    // ただし手入力の入口は必要なので、ボタン自体は残し、行き先だけを
    // 種別選択シートではなく手入力画面へ変える（押せないボタンを残さない）。
    if (!widget.capabilities.canCaptureImages) {
      return Column(
        children: <Widget>[
          FilledButton.icon(
            onPressed: () => _openManualEntry(null),
            icon: const Icon(Icons.edit_note),
            label: const Text('記録を追加'),
          ),
        ],
      );
    }
    return Column(
      children: <Widget>[
        FilledButton.icon(
          // v3（01a20785-a302）: ボタンは種別選択シートを開く入口に変わる。
          // 種別ごとの入口（ギャラリー/カメラ）はシート側に集約
          //（docs/v3_input_source_flow_design_2026-11-23.md §1・裁定済み）。
          onPressed: _openSpeciesSelectionSheet,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('画像を取り込む'),
        ),
        const SizedBox(height: 12),
        // FR-8: 失効ガイド。文言はユーザー確定（2026-11-22 に設計確認書 §3 で確定、
        // 2026-11-26 に「約6日」→「一定期間」へ変更）。テストで完全一致固定している。
        // WHY 日数を書かないか: 失効までの日数はプレーシェア側の仕様で、こちらが
        // 断定すると変わった時に誤った情報を出し続けることになる。
        // 「取り込み」表現に統一し「撮影」には言及しない（FR-9 整合）。
        Text(
          'プレーシェアは一定期間で見られなくなるため、お早めに取り込みください',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.secondary,
          ),
        ),
      ],
    );
  }

  /// エラーメッセージがあればエラーカードを表示する。
  Widget _buildErrorSection(ThemeData theme) {
    final String? errorMessage = _errorMessage;
    if (errorMessage == null) {
      return const SizedBox.shrink();
    }
    return Column(
      children: <Widget>[
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              errorMessage,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ),
      ],
    );
  }
}



