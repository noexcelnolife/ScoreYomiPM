import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../data/play_record.dart';
import '../data/play_record_repository.dart';
import '../models/ocr_models.dart';
import '../ocr/field_extractor.dart';
import '../ocr/song_entry.dart';
import '../ocr/song_title_matcher.dart';
import '../validation/play_record_validator.dart';
import '../validation/validation_issue.dart';
import 'difficulty_color.dart';
import 'difficulty_levels.dart';
import 'song_level_picker.dart';
import 'song_search_screen.dart';

/// 「要確認」とみなす信頼度の仮しきい値（PoC 用の暫定値）。
///
/// spec.md FR-3「確認・修正画面」のスタブとして、この値未満の信頼度の
/// 要素をハイライト表示する。
const double kLowConfidenceThreshold = 0.8;

/// 数値フィールド行の表示順（id = コントローラのキー）。
///
/// spec.md FR-3 の確認対象。本作（PM）には MISS 判定が存在しないため
/// MISS は対象外（spec.md 2026-11-21 ユーザー確認）。level は ST-4 Wave 2
/// クロップ再 OCR（RegionOcrRunner / extractWithRegions）由来で抽出される
/// 可能性があり、抽出済みなら値を表示・未抽出なら手入力で代替する。
const List<String> _numericRowIds = <String>[
  'score',
  'maxCombo',
  'level',
  'cool',
  'great',
  'good',
  'bad',
];

/// フィールド行 id → 日本語ラベル。
const Map<String, String> _fieldRowLabels = <String, String>{
  'score': 'スコア',
  'maxCombo': 'MAX COMBO',
  'level': 'レベル',
  'cool': 'COOL',
  'great': 'GREAT',
  'good': 'GOOD',
  'bad': 'BAD',
  'songName': '曲名',
};

/// OCR 結果の確認・修正画面（spec.md FR-3）。
///
/// 上段に ST-4 のフィールド抽出結果による「スコア確認・修正」セクション、
/// その下に検出された [OcrElement] の一覧（テキスト・信頼度・バウンディング
/// ボックス）を表示する。
///
/// - 抽出済みフィールドは値（編集可）と信頼度を表示する。isValid=false は
///   errorContainer 色で強調し validationMessage を併記する
/// - 未抽出フィールドは空の TextField で手入力を受け付ける（欠落 = FR-3 手入力対象）
/// - [OcrResultScreen.extractionResult] が null でも [existingRecordId] が
///   指定されていればフィールドセクションを出す（FR-4 手入力モード）
/// - FR-5: 未決定（autoDecided=false）の曲名候補がある場合は曲名欄の下に
///   候補チップを出し、タップで曲名欄へ値を設定する（1 タップ選択）
/// - FR-4: [playRecordRepository] が注入された場合のみ「スコアを保存」ボタンを
///   表示し、曲名の有無で確定/未確定レコードを create / update する
/// - v4 案2: [imageFile] が null の写真なし手入力モードを許容する。原画像
///   プレビューを出さず、保存後はフォームを空に戻して連続入力できる
class OcrResultScreen extends StatefulWidget {
  const OcrResultScreen({
    super.key,
    this.imageFile,
    this.pageResult,
    this.extractionResult,
    this.playRecordRepository,
    this.existingRecordId,
    this.songMatchResult,
    this.matchedSong,
    this.appBarTitle,
    this.initialMachine,
    this.onSongTitleSearch,
    this.onSongEntryResolve,
    this.onSongSearchWide,
  });

  /// OCR にかけた元画像（確認用プレビュー表示に使用する）。
  ///
  /// WHY(v4 案2): 写真なし手入力モードでは null。プレビュー領域自体を出さず、
  /// repository.create へも null を渡して「画像なし」レコードを作る。
  final File? imageFile;

  /// 表示対象の OCR 結果。
  ///
  /// WHY: FR-4 手入力モード（未確定レコードからの手入力）では null を許容し、
  /// 要素一覧を出さずにフィールド入力と保存だけの構成にする。
  final OcrPageResult? pageResult;

  /// ST-4 のフィールド抽出結果。
  final FieldExtractionResult? extractionResult;

  /// FR-4: レコードの保存先。注入された場合のみ保存ボタンを表示する（DIP）。
  final PlayRecordRepository? playRecordRepository;

  /// FR-4: 更新対象の既存レコード id。指定時は create ではなく update で保存し、
  /// 既存値をフィールドへ復元する。
  final String? existingRecordId;

  /// ST-6 の曲名マッチ結果。[bestMatchOriginal] を曲名欄の初期値にする。
  final SongMatchResult? songMatchResult;

  /// FR-6 段階 B: VR-1/VR-3 用の総ノーツ数ソース。
  ///
  /// HomeScreen が pipeline.run() の戻り値 context から分解して渡す
  /// （lib/ocr 変更ゼロ・SongMatchResult と同一の消費者パターン）。
  /// null（照合不成立・要素なし・引き直し失敗・例外の 4 パス）なら
  /// VR-1/VR-3 は欠損 skip になる（検証器側契約・設計 §5）。
  final SongEntry? matchedSong;

  /// FR-12: 手入力モードの AppBar タイトル上書き（null なら「スコア手入力」）。
  ///
  /// WHY: 記録詳細（FR-12）から開く場合は「スコア修正」と表示して文脈を
  /// 区別する。デフォルト維持により FR-4 の呼び出し側・テストは無影響。
  final String? appBarTitle;

  /// v5 機能 A: 種別選択シートで選ばれた機種の初期値。
  ///
  /// WHY: シートで「H☆C!!」を選んで入力へ進んだ場合、再選択の手間を省くため
  /// 機種 chip を選択済みで開く。null（未選択・既存経路）なら「未指定」のまま
  /// で、既存の呼び出し側は無変更で通る（追加オプショナル化）。
  final String? initialMachine;

  /// v2 UX #13: 曲名手入力時のライブ辞書検索コールバック。
  ///
  /// WHY: ユーザー実使用バグ「OCR で曲名が取れず全文字手入力すると、入力して
  /// も検索されない」。候補チップの表示源が OCR 時点の静的 [songMatchResult]
  /// のため手入力に再照合が走らない。HomeScreen が matcher キャッシュを構築し
  /// て注入する（DIP・lib/ocr 変更ゼロ）。null なら現行動作（OCR 時点の結果
  /// のみ）を維持する後方互換設計。
  final Future<SongMatchResult?> Function(String title)? onSongTitleSearch;

  /// v2 UX #15: 候補選択時に曲名から [SongEntry] を解決するコールバック。
  ///
  /// WHY: ユーザー裁定「手入力でも総ノーツ数をリンク」（2026-11-23）。候補
  /// （SongMatchCandidate）は SongEntry を持たないため、チップ選択だけでは
  /// VR 検証用の総ノーツ数が解決できない。HomeScreen がライブ検索と同一構成の
  /// マージ辞書で findByNormalizedKey を提供する（DIP・onSongTitleSearch と
  /// 同型パターン・lib/ocr 変更ゼロ）。null なら現行動作（リンクなし・VR-1/
  /// VR-3 は欠損 skip）を維持する後方互換設計。
  final Future<SongEntry?> Function(String normalizedTitle)? onSongEntryResolve;

  /// 曲名の全件検索コールバック（曲名検索画面の供給元）。
  ///
  /// WHY: ライブ検索の候補は最大 3 件で打ち切るため、目当ての曲が出ない場合の
  /// 逃げ道が要る（ユーザー要望 2026-11-25「候補 3 件では不足する」）。実体は
  /// `LiveSongTitleSearch.searchWide` で、HomeScreen / PlayRecordDetailScreen が
  /// 構築済みのインスタンスを注入する（DIP）。null なら検索入口を出さない
  /// 後方互換設計（既存の呼び出し側・テストは無変更で通る）。
  final Future<List<SongEntry>> Function(String query)? onSongSearchWide;

  /// この画面への [MaterialPageRoute] を生成する。
  ///
  /// WHY(v4 案2): 写真なし手入力では [imageFile] を省略する。
  static Route<void> route({
    File? imageFile,
    OcrPageResult? pageResult,
    FieldExtractionResult? extractionResult,
    PlayRecordRepository? playRecordRepository,
    String? existingRecordId,
    SongMatchResult? songMatchResult,
    SongEntry? matchedSong,
    String? appBarTitle,
    String? initialMachine,
    Future<SongMatchResult?> Function(String title)? onSongTitleSearch,
    Future<SongEntry?> Function(String normalizedTitle)? onSongEntryResolve,
    Future<List<SongEntry>> Function(String query)? onSongSearchWide,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => OcrResultScreen(
        imageFile: imageFile,
        pageResult: pageResult,
        extractionResult: extractionResult,
        playRecordRepository: playRecordRepository,
        existingRecordId: existingRecordId,
        songMatchResult: songMatchResult,
        matchedSong: matchedSong,
        appBarTitle: appBarTitle,
        initialMachine: initialMachine,
        onSongTitleSearch: onSongTitleSearch,
        onSongEntryResolve: onSongEntryResolve,
        onSongSearchWide: onSongSearchWide,
      ),
    );
  }

  @override
  State<OcrResultScreen> createState() => _OcrResultScreenState();
}

class _OcrResultScreenState extends State<OcrResultScreen> {
  /// フィールド行 id（[_numericRowIds] と 'songName'）別の編集用コントローラ。
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// 保存処理の実行中フラグ（ボタン連打・多重保存を防ぐ）。
  bool _isSaving = false;

  /// FR-6: 整合性検証の対象となるコントローラ key
  /// （level・songName は VR-2′/VR-3′/VR-4 の対象外）。
  static const List<String> _validatedControllerKeys = <String>[
    'score',
    'cool',
    'great',
    'good',
    'bad',
    'maxCombo',
  ];

  /// P-6: 破棄確認の基準値（初期値 / 復元値）。initState と非同期復元の完了
  /// 時点で確定し、戻る操作時の dirty 判定に使う。
  Map<String, String> _dirtyBaseline = const <String, String>{};

  @override
  void initState() {
    super.initState();
    // WHY(v5 機能 A): シートで選んだ機種はここで引き継ぐ（難易度はシートで
    // 選ばないため null =「不明」が既定）。編集復元経路では
    // _applyRestoredRecord が非同期到着後に上書きするので後勝ちで正しい。
    // WHY(2026-11-24 ユーザー指示): 機種の既定を「未指定」から H☆C!! へ変更。
    // 実運用では H☆C!! 以外を選ぶ場面がなく、既定のままだと未指定で保存する
    // 取りこぼしが起きる。共有インテント経路（initialMachine なし）も同じ
    // 既定に揃える。「未指定」は選択肢として残るので明示的に外せる。
    _machine = widget.initialMachine ?? _defaultMachineForNewRecord;
    final FieldExtractionResult? extraction = widget.extractionResult;
    // 抽出対象の数値フィールド: 抽出値を初期値にする（未抽出は空欄）。
    // WHY: 手入力モード（extraction == null）でも既存レコードの復元値を
    // 代入できるよう、コントローラは常に生成しておく。
    for (final NumericFieldKind kind in NumericFieldKind.values) {
      final ExtractedField? field = extraction?.field(kind);
      _controllers[kind.name] = TextEditingController(
        text: field?.value.toString() ?? '',
      );
    }
    // FR-6: 検証対象フィールドにリスナーを付け、ユーザーが値を直した瞬間に
    // 再検証してメッセージを消す（ライブ再計算。設計 §4）。
    for (final String key in _validatedControllerKeys) {
      _controllers[key]?.addListener(_handleValidationChange);
    }
    // WHY(v2 UX 改修3): レベルは FR-6 検証対象外だが、未抽出＋未入力の黄色強調
    // を入力時にライブ解除するため同じリスナーを張る（dispose で対解除）。
    _controllers[NumericFieldKind.level.name]!.addListener(
      _handleValidationChange,
    );
    // WHY: 曲名は ST-4 Wave 1 の抽出対象外のため空欄で開く。ただし FR-3 の
    // 曲名マッチ（ST-6）が成功している場合は bestMatchOriginal（元表記）を
    // 初期値にする。既存レコードであっても抽出結果が存在する場合（再 OCR
    // 経路）は新鮮な照合結果をフォームへ反映する — 復元優先の元根拠
    // （修正モード・extraction null 経路）にのみ復元値の優先を残す。
    // matchedSong が未解決（null）のときは空欄のまま開く。
    String? songNamePrefill;
    final SongMatchResult? match = widget.songMatchResult;
    if ((widget.existingRecordId == null || extraction != null) &&
        (match?.bestMatchOriginal?.isNotEmpty ?? false)) {
      songNamePrefill = match!.bestMatchOriginal;
    }
    _controllers['songName'] = TextEditingController(text: songNamePrefill);
    // WHY(v2 UX 改修3): 曲名は ST-4 抽出対象外のため常に「未抽出」扱い。黄色
    // 強調を入力時にライブ解除するため同じリスナーを張る（dispose で対解除）。
    _controllers['songName']!.addListener(_handleValidationChange);
    // WHY(v2 UX #13): 曲名手入力のたびにライブ辞書検索を走らせる（ユーザー
    // 実使用バグ「手入力しても検索されない」の修正・dispose で対解除）。
    _controllers['songName']!.addListener(_handleSongTitleChange);
    // WHY(v2 UX #13): prefill 値（OCR 時点の照合結果そのもの）は「検索済み」
    // としておく。フォーカス取得時の selection 変更でも TextEditingController
    // のリスナーは発火するため、初期値を検索済みにしておかないと初フォーカス
    // で無意味な再検索が走る（テキスト変更時のみ再検索する）。
    _lastSearchedTitle = _controllers['songName']?.text.trim();
    // FR-4: 既存レコードの復元（手入力・修正モード）。読み込みは非同期のため、
    // 到着した時点でコントローラへ反映する。
    //
    // WHY: 再 OCR 経路（extractionResult 非 null + existingRecordId 非 null）では
    // 復元を実行しない。再 OCR の目的は「新鮮な OCR 値の提示」であり、復元値
    // （値を持たない未確定レコードなら全 null → 空文字）が抽出値を wipe すると
    // 目的が不達成になる（smoke test 不便①・リード裁定）。保存済み値はレコード
    // 側に残っており、フォームは提案であり確定（保存）までレコードは不変。
    // また未抽出フィールドの復元も行わない — 部分抽出時も抽出値を優先し、
    // 抽出値と復元値のマージはしない（KISS・フォームは提案）。
    final PlayRecordRepository? repository = widget.playRecordRepository;
    final String? existingId = widget.existingRecordId;
    if (existingId != null &&
        repository != null &&
        widget.extractionResult == null) {
      repository.findById(existingId).then(_applyRestoredRecord);
    }
    // P-6: 破棄確認の基準値をここで確定する（非同期復元がある場合は復元完了時
    // に上書きする）。以後のユーザー編集は dirty 判定の対象。
    _dirtyBaseline = _currentFieldValues();
  }

  /// 既存レコードの値をフィールドへ復元する（[initState] の非同期後処理）。
  void _applyRestoredRecord(PlayRecord? record) {
    if (!mounted || record == null) {
      return;
    }
    _controllers['score']?.text = record.score?.toString() ?? '';
    _controllers['cool']?.text = record.cool?.toString() ?? '';
    _controllers['great']?.text = record.great?.toString() ?? '';
    _controllers['good']?.text = record.good?.toString() ?? '';
    _controllers['bad']?.text = record.bad?.toString() ?? '';
    _controllers['maxCombo']?.text = record.maxCombo?.toString() ?? '';
    _controllers['level']?.text = record.level?.toString() ?? '';
    _controllers['songName']?.text = record.songName ?? '';
    if (record.clearMedal != null) {
      try {
        _selectedMedal = ClearMedalCategory.values.firstWhere(
          (c) => c.name == record.clearMedal,
        );
      } catch (_) {
        _selectedMedal = null;
      }
    }
    // WHY(v5 機能 A): 編集復元は保存済み値が最優先。difficulty は fromJson で
    // 既に enum 化済み（未知名は null）なのでそのまま復元、machine は自由文字列
    // のまま素通しする。initialMachine prefill より後のこの代入が最終値になる。
    _difficulty = record.difficulty;
    _machine = record.machine;
    // P-6: 復元値が dirty 判定の基準値になる（復元完了後に上書き）。
    _dirtyBaseline = _currentFieldValues();
    setState(() {});
  }

  /// FR-6: コントローラの変更で再検証する（ライブ再計算）。
  void _handleValidationChange() {
    setState(() {});
  }

  /// v2 UX #13: ライブ辞書検索の最新結果（曲名欄非空時にチップ表示源になる）。
  SongMatchResult? _liveMatchResult;

  /// v2 UX #13: 最後にライブ検索した trim 後の曲名（同文の再検索抑止用）。
  String? _lastSearchedTitle;

  /// v2 UX #13: ライブ検索の世代カウンタ。
  ///
  /// WHY: 高速連続入力で検索応答の完了順が入れ替わっても、最後の入力の結果
  /// だけを採用するため（古い応答で上書きしない）。
  int _songSearchGeneration = 0;

  /// v2 UX #15: 候補選択で解決した曲エントリ（VR 検証の総ノーツ数源）。
  ///
  /// WHY: [OcrResultScreen.matchedSong] は OCR 自動確定経路のみ。手入力経路の
  /// チップ選択ではエントリが解決できず VR が欠損 skip になるのがユーザー指摘
  /// の「リンク」欠落。選択を最優先し OCR 自動確定値をフォールバックにする
  /// （最新の選択が正・#15 裁定 4）。レコードへの songId 永続化はしない
  /// （本リンクは画面内 VR 検証への適用が目的・FR-7 は保存後照合のまま）。
  SongEntry? _selectedMatchedSong;

  /// メダル選択状態（未設定なら null）。
  ///
  /// WHY: ChoiceChip で一度選択したメダルを「未設定」に戻す手段がないと
  /// 誤選択が確定してしまう。先頭の「未設定」チップで解除経路を確保する。
  ClearMedalCategory? _selectedMedal;

  /// v5 機能 A: 難易度の選択状態（「不明」= null）。
  GameDifficulty? _difficulty;

  /// v5 機能 A: 機種の選択状態（「未指定」= null）。
  ///
  /// WHY: メダルと同じ「chip で選んだ値を draft へ素通しするだけの画面状態」。
  /// シートからの initialMachine prefill と編集復元はこの値の開始点を変える
  /// だけで、保存パス（_buildDraft）は共通化する。
  String? _machine;

  /// 新規入力時の機種初期値（ユーザー指示 2026-11-24「H☆C!! をデフォルトに」）。
  ///
  /// WHY データ層に定数を置かないか: 保存スキーマ・enum・JSON は無変更に保ち、
  /// 「入力の初期値」という UI 都合だけを UI 側で表現するため。機種一覧の
  /// 先頭が現行世代（H☆C!!）であることは [availableGameVersions] が保証する。
  String? get _defaultMachineForNewRecord =>
      availableGameVersions.isEmpty ? null : availableGameVersions.first;

  /// v2 UX #13: 曲名欄の変更でライブ辞書検索をやり直す。
  ///
  /// WHY: ユーザー実使用バグ「手入力しても検索されない」の修正。照合は同期計算
  /// （Levenshtein・2100 エントリでも 1ms 級）だがコールバック契約は Future の
  /// ため await し、完了後の `!mounted` ガードで破棄後 setState を防ぐ。
  void _handleSongTitleChange() {
    final String query = _controllers['songName']?.text.trim() ?? '';
    // WHY(v2 UX #15・裁定 5): 選択リンクは選択された曲名と一致している間のみ
    // 有効。書き換えたらリンクが古い曲を指すため解除する。検索コールバックの
    // 有無に依らず無効化する（リンクの整合性は検索機能と独立の契約）。
    final SongEntry? selected = _selectedMatchedSong;
    if (selected != null && query != selected.title) {
      setState(() {
        _selectedMatchedSong = null;
      });
    }
    final Future<SongMatchResult?> Function(String)? search =
        widget.onSongTitleSearch;
    if (search == null) {
      return;
    }
    if (query.isEmpty) {
      _lastSearchedTitle = '';
      return;
    }
    if (query == _lastSearchedTitle) {
      return;
    }
    _lastSearchedTitle = query;
    final int generation = ++_songSearchGeneration;
    search(query).then((SongMatchResult? result) {
      if (!mounted || generation != _songSearchGeneration) {
        return;
      }
      setState(() {
        _liveMatchResult = result;
      });
    });
  }

  /// 曲名検索画面を開き、選ばれた曲を曲名欄と総ノーツ数のリンクへ反映する。
  ///
  /// WHY リンク（[_selectedMatchedSong]）まで差し替えるか: 総ノーツ数（VR-1 の
  /// 上限）の源はこのフィールドで、曲名の文字列だけ変えると別の曲のノーツ数で
  /// 検証してしまう。なお [_applyCandidate] の代入で [_handleSongTitleChange] が
  /// 同期で走るが、あのリスナーがリンクを外すのは「入力文字列がリンク中の曲名と
  /// 違うとき」だけなので、この後に設定すれば残る（逆順でも外れないことは
  /// テストで確認済み・順序には依存しない）。
  Future<void> _openSongSearch() async {
    final Future<List<SongEntry>> Function(String)? search =
        widget.onSongSearchWide;
    if (search == null) {
      return;
    }
    final SongEntry? entry = await Navigator.of(context).push<SongEntry>(
      SongSearchScreen.route(
        search: search,
        initialQuery: _controllers['songName']?.text.trim() ?? '',
        initialSong: _selectedMatchedSong,
      ),
    );
    if (!mounted || entry == null) {
      return;
    }
    _applyCandidate(entry.title);
    setState(() {
      _selectedMatchedSong = entry;
    });
    await _promptSongLevel(entry);
  }

  /// 曲名DBの登録内容から難易度とレベルを選ばせ、入力欄へ反映する。
  ///
  /// WHY(ユーザー指示 2026-11-25): 「曲名が確定したら、ポップアップ等で曲名DBに
  /// 登録されている難易度とレベルを選択肢で選ばせる」。表示できる登録が無い曲
  /// （levels が空）ではダイアログを出さない。
  ///
  /// WHY 自動決定（[SongMatchResult.autoDecided]）や OCR 直後のプリフィルでは
  /// 出さないか: 曲名が自動で埋まった時点で毎回モーダルが出ると編集操作を妨げる。
  /// 契機はユーザーが明示的に曲を選んだ操作（候補チップのタップ・曲名検索画面
  /// からの選択）に限る。
  ///
  /// WHY「自動入力しない」で何も変えないか: OCR の読み取り値や手入力値をそのまま
  /// 使いたい場合があるため、難易度・レベルとも**変更もクリアもしない**。
  Future<void> _promptSongLevel(SongEntry song) async {
    if (orderedLevels(song.levels).isEmpty) {
      return;
    }
    final SongLevelChoice? choice = await showSongLevelPicker(context, song);
    if (!mounted || choice == null) {
      return;
    }
    setState(() {
      _difficulty = choice.difficulty;
      // 難易度とレベルは保存時に同じレコードへ入るため、片方だけ反映しない。
      _controllers['level']?.text = choice.level.toString();
    });
  }

  /// 現在の全コントローラ値を snapshot する（P-6 dirty 判定用）。
  Map<String, String> _currentFieldValues() {
    return <String, String>{
      for (final MapEntry<String, TextEditingController> entry
          in _controllers.entries)
        entry.key: entry.value.text,
    };
  }

  /// P-6: 復元値（または初期値）からユーザーが値を変えたかどうか。
  ///
  /// WHY: 変更なしの戻りは通常の閲覧動作のため、ダイアログを出さない
  /// （リード裁定 2026-11-23）。空白差分のみの変更は未編集扱いにする
  /// （トリム差分比較）。
  bool _isDirty() {
    for (final MapEntry<String, TextEditingController> entry
        in _controllers.entries) {
      final String current = entry.value.text.trim();
      final String baseline = (_dirtyBaseline[entry.key] ?? '').trim();
      if (current != baseline) {
        return true;
      }
    }
    return false;
  }

  /// P-6: 戻る操作の破棄確認ラッパー。canPop:false で一度戻るを止め、
  /// dirty 判定のうえ未変更なら即 pop・変更ありなら確認ダイアログを経由する。
  Widget _popScope({required Widget child}) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) {
        if (didPop) {
          return;
        }
        _handleBackNavigation();
      },
      child: child,
    );
  }

  /// 戻る操作の処理（P-6）。未変更なら即 pop、変更ありなら破棄確認。
  Future<void> _handleBackNavigation() async {
    if (!_isDirty()) {
      // WHY(P-6 フォローアップ・リード裁定 2026-11-23): canPop false の構成
      //（root 直置きのテスト等）では pop しない — root の pop は画面全体を
      // 消して既存テストの前提を崩す。push 構成（実運用）では canPop true で
      // 通常の戻りになる。
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('変更を破棄しますか？'),
          content: const Text('保存していない変更は失われます。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('破棄する'),
            ),
          ],
        );
      },
    );
    if ((discard ?? false) && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// FR-6: 現在の入力値に対して整合性検証を実行する。
  ///
  /// WHY(v2A): メダル入力ソース（FR-3 手入力）を着地。_selectedMedal を
  /// clearMedal に渡し VR-4 の双方向チェックを活性化する。メダル未設定の
  /// まま保存時は null を渡し、VR-4 は不発とする（テスト 4）。
  List<ValidationIssue> _validateCurrentValues() {
    return validatePlayValues(
      score: _parseControllerInt('score'),
      cool: _parseControllerInt('cool'),
      great: _parseControllerInt('great'),
      good: _parseControllerInt('good'),
      bad: _parseControllerInt('bad'),
      maxCombo: _parseControllerInt('maxCombo'),
      clearMedal: _selectedMedal,
      // FR-6 段階 B: totalNotes は SongEntry v2 getter を UI 側で解体して
      // plain int? で渡す（検証器は lib/ocr 型を持たない DIP 契約・設計 §1）。
      // WHY(v2 UX #15・裁定 4): 候補選択で解決した曲エントリを最優先する
      // （最新の選択が正）。未選択のときは従来どおり OCR 自動確定値に
      // フォールバックする（非回帰・テスト 3）。
      totalNotes: (_selectedMatchedSong ?? widget.matchedSong)?.totalNotes,
    );
  }

  /// コントローラの表示文字列を整数へ変換する（空欄・非数値は null）。
  ///
  /// WHY: OCR 抽出値のように桁区切り「1,200」をそのまま打った場合も整数として
  /// 検証できるよう、カンマを除去してから解釈する。
  int? _parseControllerInt(String id) {
    final String? text = _controllers[id]?.text;
    if (text == null) {
      return null;
    }
    final String digits = text.replaceAll(',', '').trim();
    return int.tryParse(digits);
  }

  @override
  void dispose() {
    // FR-6: initState で付けた検証リスナーを外してから破棄する。
    for (final String key in _validatedControllerKeys) {
      _controllers[key]?.removeListener(_handleValidationChange);
    }
    // WHY(v2 UX 改修3): 黄色強調のライブ解除のために initState で付けた
    // レベル・曲名のリスナーも対で外す。
    _controllers[NumericFieldKind.level.name]?.removeListener(
      _handleValidationChange,
    );
    _controllers['songName']?.removeListener(_handleValidationChange);
    // WHY(v2 UX #13): ライブ辞書検索のリスナーも対で外す。
    _controllers['songName']?.removeListener(_handleSongTitleChange);
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FR-5: 未決定の曲名候補がある場合、手入力モード・通常モードのどちらでも
    // 候補チップを有効にするため、両分岐より手前で算出する。
    // WHY(v2 UX #13): チップ表示源の切替。曲名欄が空なら OCR 時点の結果
    // （従来どおり・通常フロー完全非回帰）、非空ならライブ辞書検索の結果。
    // ライブ結果がまだ無い間（初期 prefill 直後・辞書ロード失敗）は OCR 時点
    // の結果へフォールバックし、prefill 時点の候補表示を保つ。未提供なら
    // 従来どおり widget.songMatchResult のみ（後方互換）。
    final String songQuery = _controllers['songName']?.text.trim() ?? '';
    final SongMatchResult? chipSource;
    if (widget.onSongTitleSearch == null || songQuery.isEmpty) {
      chipSource = widget.songMatchResult;
    } else {
      chipSource = _liveMatchResult ?? widget.songMatchResult;
    }
    final bool hasUndecidedCandidates =
        chipSource != null &&
        !chipSource.autoDecided &&
        chipSource.topCandidates.isNotEmpty;
    // FR-6: 現在の入力値（抽出値＋手修正値）に対する整合性検証。両モードの
    // フィールドセクションで同じ結果を表示する。
    final List<ValidationIssue> validationIssues = _validateCurrentValues();
    if (widget.pageResult == null) {
      return _popScope(
        child: _buildManualModeScaffold(
          songMatchResult: chipSource,
          hasUndecidedCandidates: hasUndecidedCandidates,
          validationIssues: validationIssues,
        ),
      );
    }

    final List<OcrElement> elements = widget.pageResult!.elements;
    final int lowConfidenceCount = elements
        .where(
          (OcrElement element) =>
              !element.hasUnknownConfidence &&
              element.confidence < kLowConfidenceThreshold,
        )
        .length;
    final int unknownConfidenceCount = elements
        .where((OcrElement element) => element.hasUnknownConfidence)
        .length;
    // WHY: 抽出結果が無くても、未確定レコードの修正モード（existingRecordId
    // 指定）ならフィールドセクションを出す。
    // FR-5: 未決定の曲名候補がある場合も表示対象に加える。候補選択は曲名欄を
    // 経由して保存につながるため、フィールドセクションが表示の前提になる。
    final bool showFieldSection =
        widget.extractionResult != null ||
        widget.existingRecordId != null ||
        hasUndecidedCandidates;

    return _popScope(
      child: _buildNormalModeScaffold(
        elements: elements,
        showFieldSection: showFieldSection,
        songMatchResult: chipSource,
        hasUndecidedCandidates: hasUndecidedCandidates,
        lowConfidenceCount: lowConfidenceCount,
        unknownConfidenceCount: unknownConfidenceCount,
        validationIssues: validationIssues,
      ),
    );
  }

  /// 手入力モード（pageResult なし）の Scaffold を構築する。
  ///
  /// WHY: 手入力モード（pageResult なし）は要素一覧を持たない。フィールド
  /// 入力と画像プレビューだけの構成にし、サマリー系ウィジェットに null を
  /// 持ち込まないよう通常モードと完全に分岐する。
  /// （関数≤50 規約対応: build から Scaffold 構築を抽出。振る舞いは不変）
  Widget _buildManualModeScaffold({
    required SongMatchResult? songMatchResult,
    required bool hasUndecidedCandidates,
    required List<ValidationIssue> validationIssues,
  }) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.appBarTitle ?? 'スコア手入力')),
      body: ListView(
        children: <Widget>[
          _ImagePreview(imageFile: widget.imageFile),
          _FieldSection(
            extractionResult: widget.extractionResult,
            controllers: _controllers,
            playRecordRepository: widget.playRecordRepository,
            isSaving: _isSaving,
            onSave: _save,
            songMatchResult: songMatchResult,
            showCandidates: hasUndecidedCandidates,
            onCandidateSelected: _applyCandidate,
            onCandidateResolved: _resolveCandidateEntry,
            onSongSearch: widget.onSongSearchWide == null
                ? null
                : _openSongSearch,
            validationIssues: validationIssues,
            selectedMedal: _selectedMedal,
            onMedalChanged: _onMedalChanged,
            difficulty: _difficulty,
            onDifficultyChanged: _onDifficultyChanged,
            machine: _machine,
            onMachineChanged: _onMachineChanged,
          ),
        ],
      ),
    );
  }

  /// 通常モード（pageResult あり）の Scaffold を構築する。
  ///
  /// 要素一覧が空でフィールドセクションも出せないときは空状態を表示する。
  /// （関数≤50 規約対応: build から Scaffold 構築を抽出。振る舞いは不変）
  Widget _buildNormalModeScaffold({
    required List<OcrElement> elements,
    required bool showFieldSection,
    required SongMatchResult? songMatchResult,
    required bool hasUndecidedCandidates,
    required int lowConfidenceCount,
    required int unknownConfidenceCount,
    required List<ValidationIssue> validationIssues,
  }) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR結果確認')),
      body: elements.isEmpty && !showFieldSection
          // WHY 空結果でも画像を先頭に出すか（2026-11-26 のユーザー指示
          // 「いずれでも、読み込んだ画像を一番上に配置」）: 何も読めなかった
          // 場合こそ「どの画像を読んだのか」を確認したい。空結果でも並びの
          // 先頭が画像である状態を崩さない。
          ? ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: <Widget>[
                _ImagePreview(imageFile: widget.imageFile),
                _EmptyResult(),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: elements.length + (showFieldSection ? 3 : 2),
              itemBuilder: (BuildContext context, int index) => _buildItem(
                context,
                elements,
                index,
                showFieldSection: showFieldSection,
                songMatchResult: songMatchResult,
                hasUndecidedCandidates: hasUndecidedCandidates,
                lowConfidenceCount: lowConfidenceCount,
                unknownConfidenceCount: unknownConfidenceCount,
                validationIssues: validationIssues,
              ),
            ),
    );
  }

  /// リストの 1 項目を構築する。
  ///
  /// 並びは 画像プレビュー → （フィールドセクション）→ サマリー → 要素一覧。
  ///
  /// WHY 画像が先頭か（2026-11-26 のユーザー指示「スコア入力画面、編集画面、
  /// 確認画面のいずれでも、読み込んだ画像を一番上に配置してください。記録詳細画面の
  /// イメージです」）: 読み取り値の確認は画像と突き合わせる作業なので、画像が一番上に
  /// あるほうが視線の往復が短い。記録詳細画面（画像 → 操作 → 項目の順）と並びを
  /// そろえ、同じ記録を別画面で見たときに同じ位置に画像がある状態にする。
  /// フィールドセクションの直上に出していた「要素 0 件」の通知は、画像の直下
  /// （フィールドセクションの直前）に置いたままにする。
  Widget _buildItem(
    BuildContext context,
    List<OcrElement> elements,
    int index, {
    required bool showFieldSection,
    required SongMatchResult? songMatchResult,
    required bool hasUndecidedCandidates,
    required int lowConfidenceCount,
    required int unknownConfidenceCount,
    required List<ValidationIssue> validationIssues,
  }) {
    if (index == 0) {
      return _ImagePreview(imageFile: widget.imageFile);
    }
    if (showFieldSection && index == 1) {
      final Widget fieldSection = _FieldSection(
        extractionResult: widget.extractionResult,
        controllers: _controllers,
        playRecordRepository: widget.playRecordRepository,
        isSaving: _isSaving,
        onSave: _save,
        songMatchResult: songMatchResult,
        showCandidates: hasUndecidedCandidates,
        onCandidateSelected: _applyCandidate,
        onCandidateResolved: _resolveCandidateEntry,
        onSongSearch: widget.onSongSearchWide == null ? null : _openSongSearch,
        validationIssues: validationIssues,
        selectedMedal: _selectedMedal,
        onMedalChanged: _onMedalChanged,
        difficulty: _difficulty,
        onDifficultyChanged: _onDifficultyChanged,
        machine: _machine,
        onMachineChanged: _onMachineChanged,
      );
      // WHY: 読めない画像（0 要素）でもフィールドセクションに着地するため
      // 「読めなかった」ことが伝わらない（smoke test 不便③・修正②）。
      // 直上に通知 1 行を出し、FR-3 手入力への導線を明示する。要素がある
      // 通常結果では出さない。要素なしでもフィールドセクションを出せない
      // _EmptyResult 分岐は「テキストは検出されました/されませんでした」の
      // メッセージを持つため対象外。
      if (elements.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[_ZeroElementsNotice(), fieldSection],
        );
      }
      return fieldSection;
    }
    final int adjusted = showFieldSection ? index - 2 : index - 1;
    if (adjusted == 0) {
      return _ResultSummaryHeader(
        elementCount: elements.length,
        lowConfidenceCount: lowConfidenceCount,
        unknownConfidenceCount: unknownConfidenceCount,
      );
    }
    return _OcrElementTile(
      index: adjusted - 1,
      element: elements[adjusted - 1],
    );
  }

  /// 保存ボタンの処理: existingRecordId の有無で create / update を分岐する。
  ///
  /// WHY: 全項目空のまま保存すると画像だけの pending が誤操作で量産され得る
  /// (smoke test レポート P-7)。ただし画像だけの pending 自体は FR-4 の正当な
  /// 実体（OcrEngineException 自動保存がまさにこの形）なので全面禁止はできず、
  /// 全項目空のときだけ確認ダイアログの 1 折りを挟む（リード裁定 2026-11-23）。
  /// 部分空（曲名だけ空で値あり等）は FR-4 設計済みの正動作なので対象外。
  Future<void> _save() async {
    final PlayRecordRepository? repository = widget.playRecordRepository;
    if (repository == null || _isSaving) {
      return;
    }
    if (_isAllFieldsEmpty()) {
      final bool confirmed = await _confirmEmptySave();
      if (!confirmed || !mounted) {
        return;
      }
    }
    setState(() => _isSaving = true);
    final PlayRecordDraft draft = _buildDraft();
    try {
      final String? existingId = widget.existingRecordId;
      if (existingId == null) {
        await repository.create(draft, widget.imageFile);
      } else {
        await repository.update(existingId, draft);
      }
      if (!mounted) {
        return;
      }
      // WHY(P-6 フォローアップ・リード裁定 2026-11-23): 保存に成功した値が
      // 新しい基準値。基準を更新しないと、直後の maybePop が PopScope
      // (canPop:false) に阻害された際に「未保存の変更あり」と誤判定し、保存
      // 直後に破棄確認が出る（キャンセル→再保存で重複レコードの恐れ）。
      _dirtyBaseline = _currentFieldValues();
      if (_isPhotolessNewEntry()) {
        // WHY(v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.4): 写真
        // なし手入力では連続入力が主用途。フォームを空に戻して同じ画面で次の
        // 記録に入れる（保存済みの画面は閉じない）。baseline を空へ再設定する
        // ため PopScope の破棄確認も誤発動しない。
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('スコアを保存しました。続けて入力できます。')));
        _resetFormForNextEntry();
        return;
      }
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('スコアを保存しました。')));
      // WHY: maybePop — 画面が直接 root に置かれた場合（テスト等）も安全に。
      Navigator.of(context).maybePop();
    } on Exception catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('保存に失敗しました: $error')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// 写真なしの新規手入力モードかどうか（v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.4）。
  ///
  /// WHY: 通常 OCR（pageResult あり）と FR-4 画像あり修正（existingRecordId
  /// あり）は従来どおり保存後に画面を閉じる。両方 null の経路は v4 案2 の
  /// 写真なし新規入口のみで、連続入力のために挙動を分ける。
  bool _isPhotolessNewEntry() =>
      widget.pageResult == null && widget.existingRecordId == null;

  /// 写真なし手入力の連続入力用にフォームを空の状態へ戻す（v4 案2）。
  ///
  /// WHY: 曲名・数値・メダル・難易度・機種・曲名検索状態を初期化し、baseline も
  /// 空に戻す。これにより PopScope の破棄確認が誤発動せず、次の記録をそのまま入力できる。
  void _resetFormForNextEntry() {
    for (final TextEditingController controller in _controllers.values) {
      controller.clear();
    }
    setState(() {
      _selectedMedal = null;
      // WHY(v5 機能 A): 難易度は毎回選び直す前提で null へ戻す。機種だけは
      // シート初期値（initialMachine）を維持する—続けて同一機種の記録を
      // 入力する実利用を想定（裁定: 機種は 2 択で「毎回変える」情報ではない）。
      _difficulty = null;
      _machine = widget.initialMachine ?? _defaultMachineForNewRecord;
      _lastSearchedTitle = '';
      _liveMatchResult = null;
      _dirtyBaseline = _currentFieldValues();
    });
  }

  /// 曲名と全数値欄がすべて空（トリム後）かどうか。
  ///
  /// WHY: 空保存ガード（P-7）の判定。既存の曲名空判定と同系の controllers
  /// 空チェックで判定を統一する（数値欄は文字列のまま渡す規約に合わせ、
  /// 正規化前の trim 空で「未入力」とみなす）。
  bool _isAllFieldsEmpty() {
    return _controllers.values.every(
      (TextEditingController controller) => controller.text.trim().isEmpty,
    );
  }

  /// 全項目空の保存を確認するダイアログ。確認 (true) で続行、それ以外は中断。
  ///
  /// WHY: 画像だけの pending は FR-4 の正当な実体のため保存自体は許可し、
  /// 誤操作の抑止は「確認の 1 折り」で足りる（リード裁定 2026-11-23）。
  Future<bool> _confirmEmptySave() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('全ての項目が未入力です'),
          content: const Text('画像だけを未確定レコードとして保存しますか？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('画像だけ保存する'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// 現在のコントローラ値から保存用ドラフトを組み立てる。
  ///
  /// WHY: 数値欄は文字列のまま渡し、正規化（数値化・範囲判定）は
  /// [PlayRecordDraft.toPlayRecord] の normalizeIntValue に一任する。
  /// 曲名はトリム後の空文字なら未確定（pending）とする
  /// （[PlayRecord.deriveStatus] と同じ規則）。
  PlayRecordDraft _buildDraft() {
    final String songName = _controllers['songName']?.text.trim() ?? '';
    final bool hasSongName = songName.isNotEmpty;
    return PlayRecordDraft(
      songName: songName,
      status: hasSongName
          ? PlayRecordStatus.confirmed
          : PlayRecordStatus.pending,
      source: PlayRecordSource.playshare,
      score: _controllers['score']?.text,
      cool: _controllers['cool']?.text,
      great: _controllers['great']?.text,
      bad: _controllers['bad']?.text,
      good: _controllers['good']?.text,
      maxCombo: _controllers['maxCombo']?.text,
      level: _controllers['level']?.text,
      clearMedal: _selectedMedal,
      difficulty: _difficulty,
      machine: _machine,
    );
  }

  /// FR-5: 候補チップのタップで曲名欄へ値を設定する。
  ///
  /// WHY: 値の設定はユーザー手入力と同一経路（コントローラへの代入）に限定
  /// する。これにより保存時のトリムと deriveStatus による確定/未確定判定が
  /// 手入力と完全一致する。候補選択は「値の設定のみ」を行い、保存や画面遷移
  /// は既存の保存ボタン 1 本に集約する（設計 §2.2）。
  void _applyCandidate(String value) {
    _controllers['songName']?.text = value;
  }

  /// v2 UX #15: 候補選択時に normalizedTitle から [SongEntry] を解決して保持する。
  ///
  /// WHY: ユーザー裁定「手入力でも総ノーツ数をリンク」（2026-11-23）。解決結果
  /// は [_selectedMatchedSong] へ入り [_validateCurrentValues] の総ノーツ数源に
  /// なる。解決失敗（null・辞書に存在しない等）は従来どおりリンクなし（VR は
  /// 欠損 skip）。await 後は `!mounted` ガードに加え、**await 中にユーザーが
  /// 曲名を書き換えていないか現行テキストと照合する** — 選択リンクは選択された
  /// 曲名と一致している間のみ有効（[_handleSongTitleChange] の無効化と同一原則。
  /// 古い応答でリンクを復活させない）。
  Future<void> _resolveCandidateEntry(SongMatchCandidate candidate) async {
    final Future<SongEntry?> Function(String)? resolve =
        widget.onSongEntryResolve;
    if (resolve == null) {
      return;
    }
    final SongEntry? entry = await resolve(candidate.normalizedTitle);
    if (!mounted) {
      return;
    }
    if (entry == null) {
      setState(() {
        _selectedMatchedSong = null;
      });
      return;
    }
    final String query = _controllers['songName']?.text.trim() ?? '';
    final bool confirmed = query == entry.title;
    setState(() {
      _selectedMatchedSong = confirmed ? entry : null;
    });
    if (confirmed) {
      await _promptSongLevel(entry);
    }
  }

  /// メダル選択状態を更新する。
  ///
  /// WHY: ChoiceChip の「未設定」チップで解除経路を確保するため、
  /// onMedalChanged は null を受け取り得る。誤選択を元に戻せるよう設計（リード裁定 2026-11-23）。
  void _onMedalChanged(ClearMedalCategory? medal) {
    setState(() {
      _selectedMedal = medal;
    });
  }

  /// v5 機能 A: 難易度の選択状態を更新する。
  ///
  /// WHY: メダルと同じく「不明（null）チップで解除可能」にする。
  /// 誤タップで保存先を壊さないための画面状態のみの変更で、
  /// 実値化は保存時（_buildDraft）に確定する。
  void _onDifficultyChanged(GameDifficulty? difficulty) {
    setState(() {
      _difficulty = difficulty;
    });
  }

  /// v5 機能 A: 機種の選択状態を更新する。
  void _onMachineChanged(String? machine) {
    setState(() {
      _machine = machine;
    });
  }
}

/// FR-3 の「スコア確認・修正」セクション。
///
/// WHY: FR-3 時点は「保存は ST-8 の将来スコープ」としていたが、FR-4 で
/// 未確定レコード保存が本画面へ接続された。保存ボタンはリポジトリが注入された
/// 場合のみ表示し、注入なし（従来の表示だけの使い方）でも成立するよう DIP を保つ。
class _FieldSection extends StatelessWidget {
  const _FieldSection({
    required this.extractionResult,
    required this.controllers,
    this.playRecordRepository,
    required this.isSaving,
    required this.onSave,
    this.songMatchResult,
    this.showCandidates = false,
    this.onCandidateSelected,
    this.onCandidateResolved,
    this.onSongSearch,
    required this.validationIssues,
    this.selectedMedal,
    this.onMedalChanged,
    this.difficulty,
    this.onDifficultyChanged,
    this.machine,
    this.onMachineChanged,
  });

  final FieldExtractionResult? extractionResult;

  /// フィールド行 id → 編集用コントローラ。
  final Map<String, TextEditingController> controllers;

  /// FR-4: 保存先リポジトリ。null の場合は保存ボタンを表示しない。
  final PlayRecordRepository? playRecordRepository;

  /// 保存処理の実行中か（true でボタンを無効化）。
  final bool isSaving;

  /// 保存ボタン押下時のコールバック。
  final VoidCallback? onSave;

  /// FR-5: 曲名マッチ結果（候補チップの表示元）。
  final SongMatchResult? songMatchResult;

  /// FR-5: 候補チップを表示するか（未決定候補がある場合のみ true）。
  final bool showCandidates;

  /// FR-5: 候補タップ時のコールバック（null ならチップを無効化）。
  final ValueChanged<String>? onCandidateSelected;

  /// 曲名の全件検索画面を開くコールバック（null なら入口を出さない）。
  final VoidCallback? onSongSearch;

  /// v2 UX #15: 候補タップ時に候補全体を渡すコールバック（SongEntry 解決用）。
  ///
  /// WHY: 候補（SongMatchCandidate）は SongEntry を持たないため、チップ選択
  /// だけでは VR 検証用の総ノーツ数が解決できない（ユーザー裁定「手入力でも
  /// 総ノーツ数をリンク」2026-11-23）。null 許容で、チップの有効条件は既存の
  /// [onCandidateSelected] のみ（契約変更なし）。
  final ValueChanged<SongMatchCandidate>? onCandidateResolved;

  /// FR-6: 現在の入力値に対する整合性検証結果（空なら表示なし）。
  final List<ValidationIssue> validationIssues;

  /// 現在選択されているクリアメダル（未設定なら null）。
  final ClearMedalCategory? selectedMedal;

  /// メダル選択変更時のコールバック。
  final ValueChanged<ClearMedalCategory?>? onMedalChanged;

  /// v5 機能 A: 現在選択されている難易度（不明なら null）。
  final GameDifficulty? difficulty;

  /// v5 機能 A: 難易度選択変更時のコールバック。
  final ValueChanged<GameDifficulty?>? onDifficultyChanged;

  /// v5 機能 A: 現在選択されている機種（未指定なら null）。
  final String? machine;

  /// v5 機能 A: 機種選択変更時のコールバック。
  final ValueChanged<String?>? onMachineChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('スコア確認・修正', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              // 並び順（01a20b34・ユーザー指示 2026-11-24）:
              // クリアメダル → 難易度 → レベル → 曲名 → スコア → COOL →
              // GREAT → GOOD → BAD → MAX COMBO → 機種。
              // WHY: 旧順（スコア・MAX COMBO・レベル…）はリザルト画面と全く
              // 異なり直感的でない、というユーザー指摘に合わせ、ゲーム内の
              // リザルト画面と同じ並びにする。表示順のみの変更で、key・ラベル・
              // 保存パス・検証ロジックは不変。
              _medalRow(theme),
              // v5 機能 A: 難易度・機種の選択行。解除用チップ（null）を先頭に
              // 置く規約は維持する。
              _metadataChipRow(
                theme: theme,
                label: '難易度',
                children: _difficultyChips(theme.brightness),
              ),
              _numericRow('level'),
              _SongNameFieldRow(
                controller: controllers['songName']!,
                onSearch: onSongSearch,
              ),
              // FR-5: 未決定の曲名候補を 1 タップ選択できるよう曲名欄の直下に
              // 並べる（設計 §2.1）。距離は表示せず元表記（originalTitle）の
              // み示す（設計 §2.3）。autoDecided=true のときはこの領域自体を
              // 出さない（設計 §2.4）。
              if (showCandidates && songMatchResult != null) ...<Widget>[
                const SizedBox(height: 8),
                Text('曲名候補（タップで入力）', style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    ..._candidateChips(),
                    // WHY 同じ行に置くか: ライブ候補は最大 3 件で打ち切るため、
                    // 目当ての曲が出ていないときに全件検索へ移る導線を候補の隣に置く。
                    if (onSongSearch != null)
                      TextButton.icon(
                        key: const ValueKey<String>('song-search-more-button'),
                        onPressed: onSongSearch,
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('もっと探す'),
                      ),
                  ],
                ),
              ],
              _numericRow('score'),
              _numericRow('cool'),
              _numericRow('great'),
              _numericRow('good'),
              _numericRow('bad'),
              _numericRow('maxCombo'),
              _metadataChipRow(
                theme: theme,
                label: '機種',
                children: _machineChips(),
              ),
              if (playRecordRepository != null) ...<Widget>[
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey<String>('save-record-button'),
                  onPressed: isSaving ? null : onSave,
                  child: Text(isSaving ? '保存中…' : 'スコアを保存'),
                ),
              ],
              // WHY 末尾の余白（01a20b34）: 並べ替えで保存ボタンがフォームの
              // 最終要素になった。余白がないとスクロール末尾でボタンが画面
              // 下端に密着して押しづらいため、32dp 空けて当たり判定と視認性を
              // 確保する。
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  /// 1 行分の数値フィールド行を組み立てる。
  ///
  /// WHY(01a20b34): 表示順を「クリアメダル → 難易度 → レベル → 曲名 →
  /// スコア → … → MAX COMBO → 機種」に並べ替えるため、行を 1 件ずつ
  /// 生成できるようにした（[_numericRowIds] は抽出・検証の対象集合として
  /// 引き続き使用し、表示順は build 側で明示する）。
  Widget _numericRow(String id) {
    // WHY: 表示順は build 側で明示するが、行として組み立ててよいのは数値
    // フィールド定義（[_numericRowIds]）にある id だけ。ここを取り違えると
    // ラベル/コントローラ参照が null になるため、開発時に即座に落とす。
    assert(_numericRowIds.contains(id), 'unknown numeric row id: $id');
    return _NumericFieldRow(
      id: id,
      label: _fieldRowLabels[id]!,
      controller: controllers[id]!,
      field: _extractedField(id),
      issues: _issuesFor(id),
    );
  }

  /// FR-3 / v2A: クリアメダル選択行。
  ///
  /// WHY(01a20b34): ユーザー指定の先頭項目になったため、行の組み立てを
  /// メソッドへ切り出して build の並び順を読みやすくする。ChoiceChip は
  /// 解除経路（未設定チップ「—」）を先頭に配置し、誤選択を元に戻せる
  /// よう設計する（リード裁定 2026-11-23）。
  Widget _medalRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('クリアメダル', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: _medalChips()),
        ],
      ),
    );
  }

  /// クリアメダル chips（未設定チップを先頭・enum 順）。
  List<Widget> _medalChips() {
    return <Widget>[
      ChoiceChip(
        key: const ValueKey<String>('medal-unset'),
        label: const Text('—'),
        selected: selectedMedal == null,
        onSelected: (_) => onMedalChanged?.call(null),
      ),
      ...ClearMedalCategory.values.map(
        (ClearMedalCategory category) => ChoiceChip(
          key: ValueKey<String>('medal-${category.name}'),
          label: Text(_medalLabel(category)),
          selected: selectedMedal == category,
          onSelected: (_) => onMedalChanged?.call(category),
        ),
      ),
    ];
  }

  /// v5 機能 A: 難易度 chips（「不明」= null 解除を先頭、4 種のみ）。
  ///
  /// WHY: UPPER はユーザー裁定で enum 外。GameDifficulty.values が 4 種なので
  /// ここは列挙そのまま＝裁定準拠。ラベルは大文字表記（LIGHT…）で enum 名と
  /// 同一語（name.toUpperCase()）を使い、格納値とのズレを防ぐ。
  ///
  /// 難易度カラーリング（01a20a53）: 各チップに難易度色の色ドットを avatar で
  /// 常時表示し、ユーザーが「色 ⇔ 難易度名」の対応を学習できるようにする。
  /// WHY selectedColor にも同色: 選択時はチェックマークが avatar 位置に重なり
  /// 色ドットが隠れるため、チップ背景の同色ティントで色見本を維持する。
  /// ティントは alpha 0.22（文字が地色に沈まない濃さ）。
  /// 色値は difficulty_color.dart が単一真実源。
  List<Widget> _difficultyChips(Brightness brightness) {
    return <Widget>[
      ChoiceChip(
        key: const ValueKey<String>('difficulty-chip-none'),
        label: const Text('不明'),
        selected: difficulty == null,
        onSelected: (_) => onDifficultyChanged?.call(null),
      ),
      ...GameDifficulty.values.map((GameDifficulty d) {
        final Color? color = difficultyColor(d, brightness: brightness);
        return ChoiceChip(
          key: ValueKey<String>('difficulty-chip-${d.name}'),
          avatar: color == null
              ? null
              : CircleAvatar(backgroundColor: color, radius: 6),
          label: Text(d.name.toUpperCase()),
          selected: difficulty == d,
          selectedColor: color?.withValues(alpha: 0.22),
          onSelected: (_) => onDifficultyChanged?.call(d),
        );
      }),
    ];
  }

  /// v5 機能 A: 機種 chips（「未指定」= null 解除を先頭、availableGameVersions 分）。
  ///
  /// WHY: ValueKey は index ベース（`machine-chip-<index>`）。機種名を key に
  /// 含めるとリネーム（商標対応を含む）でテスト key が壊れるため、リスト位置の
  /// 安定性だけに依存する（設計 §2「実装側の選択に委ねる」の採用方針）。
  /// リスト末尾追記なら既存 index の意味は不変＝テスト不変。
  List<Widget> _machineChips() {
    return <Widget>[
      ChoiceChip(
        key: const ValueKey<String>('machine-chip-none'),
        label: const Text('未指定'),
        selected: machine == null,
        onSelected: (_) => onMachineChanged?.call(null),
      ),
      ...List<Widget>.generate(
        availableGameVersions.length,
        (int index) => ChoiceChip(
          key: ValueKey<String>('machine-chip-$index'),
          label: Text(availableGameVersions[index]),
          selected: machine == availableGameVersions[index],
          onSelected: (_) =>
              onMachineChanged?.call(availableGameVersions[index]),
        ),
      ),
    ];
  }

  /// メタデータ選択行（ラベル + chips Wrap）の共通レイアウト。
  Widget _metadataChipRow({
    required ThemeData theme,
    required String label,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: children),
        ],
      ),
    );
  }

  /// 行 id が抽出対象の数値フィールドならその抽出結果を返す。
  ///
  /// level は Wave 2（リージョン再 OCR / extractWithRegions）で抽出される
  /// 可能性があり、抽出値が null ではない場合はそれを返す。未抽出なら null。
  ExtractedField? _extractedField(String id) {
    for (final NumericFieldKind kind in NumericFieldKind.values) {
      if (kind.name == id) {
        return extractionResult?.field(kind);
      }
    }
    return null;
  }

  /// FR-6: 指定フィールドが対象に含まれる検証 issue をすべて返す（リスト順）。
  ///
  /// WHY: 段階 A は先頭 1 件の共有表示で十分だったが、段階 B では同一行に
  /// VR-2′ と VR-1 が同時発火し得るため、先頭一致では後続ルールのメッセージが
  /// 隠れる（設計 §2 の 4 判定行メッセージ表示を満たすため全件併記に拡張）。
  List<ValidationIssue> _issuesFor(String id) {
    final List<ValidationIssue> matched = <ValidationIssue>[];
    for (final ValidationIssue issue in validationIssues) {
      if (issue.fieldIds.contains(id)) {
        matched.add(issue);
      }
    }
    return matched;
  }

  /// FR-5: 候補チップのリスト（topCandidates は距離昇順で最大 3 件）。
  ///
  /// WHY: ループ変数をクロージャにそのまま捕まえないよう候補を一旦ローカルに
  /// 受ける。onCandidateSelected が null のときはチップを無効化する。
  List<Widget> _candidateChips() {
    final SongMatchResult? match = songMatchResult;
    if (match == null) {
      return const <Widget>[];
    }
    final List<Widget> chips = <Widget>[];
    for (int i = 0; i < match.topCandidates.length; i++) {
      final SongMatchCandidate candidate = match.topCandidates[i];
      chips.add(
        ActionChip(
          key: ValueKey<String>('candidate-chip-$i'),
          label: Text(candidate.originalTitle),
          onPressed: onCandidateSelected == null
              ? null
              : () {
                  onCandidateSelected!(candidate.originalTitle);
                  // WHY(v2 UX #15): 候補全体を渡して SongEntry を解決する
                  // （非同期・解決結果は _selectedMatchedSong へ）。テキスト
                  // 設定後に呼ぶためリスナー経由の再検索と順序が競合しない。
                  onCandidateResolved?.call(candidate);
                },
        ),
      );
    }
    return chips;
  }

  /// ClearMedalCategory → 表示ラベル。ユーザーにとって直感的な日本語表記。
  ///
  /// WHY: enum の name は英小文字（fullComboFamily 等）で UI に不向きなため、
  /// 日本語ラベルへのマッピングをここで一元化する。
  static String _medalLabel(ClearMedalCategory category) {
    switch (category) {
      case ClearMedalCategory.fullComboFamily:
        return 'フルコンボ';
      case ClearMedalCategory.clear:
        return 'クリア';
      case ClearMedalCategory.assistClear:
        return 'アシストクリア';
      case ClearMedalCategory.easyClear:
        return 'イージークリア';
      case ClearMedalCategory.failed:
        return '失敗';
    }
  }
}

/// 数値フィールド 1 件分の入力行。
///
/// 抽出済みなら値（編集可）と信頼度を表示し、isValid=false は errorContainer 色で
/// 強調して validationMessage を併記する。未抽出は空欄で手入力を受け付ける。
/// FR-6: 整合性検証の issue がある行も同じ色で強調し、メッセージを併記する。
///
/// WHY: extractWithRegions（ST-4 パイプライン接続 / Wave 2 リージョン再 OCR）
/// 由来のフィールド（level 等）の boundingBox はクロップ座標系だが、FR-3 は
/// 値・生値・信頼度のみを使用するため座標系は表示に影響しない（元画像
/// 座標への再投影はデバッグ表示が必要になった時点で行う）。
class _NumericFieldRow extends StatelessWidget {
  const _NumericFieldRow({
    required this.id,
    required this.label,
    required this.controller,
    required this.field,
    required this.issues,
  });

  /// フィールド行 id（テスト用の key にも使用する）。
  final String id;

  /// 表示ラベル。
  final String label;

  final TextEditingController controller;

  /// 抽出結果。未抽出（または Wave 1 抽出対象外）なら null。
  final ExtractedField? field;

  /// FR-6: この行が対象に含まれる整合性検証の issue 群（該当なければ空）。
  final List<ValidationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ExtractedField? extracted = field;
    final bool invalid = extracted != null && !extracted.isValid;
    // FR-6: 整合性検証の issue も FR-3 と同じ errorContainer 色で強調する
    //（設計 §4: 矛盾箇所を低信頼度扱いと同じ「要確認」にする）。
    final bool highlighted = invalid || issues.isNotEmpty;
    // WHY(v2 UX 改修3): 未抽出（ExtractedField なし）かつ未入力の欄は「まだ
    // 確認していない」状態を示す。入力するとライブ解除する（リスナーは
    // initState で全数値欄に張ってあるため、親の setState で再評価される）。
    // 検証違反（errorContainer）は最上位の緊急度のため黄色より優先する。
    // 黄色は暗い背景の上でも 35% 透過で差が視認できる明度差（ライトテーマ:
    // 淡黄 ≈ (255,242,187)、ダークテーマ: 黄褐 ≈ (108,100,41)、背景
    // (29,27,32) との差）であり、ダークテーマでも識別可能と確認済み。
    final bool unextractedAndEmpty =
        extracted == null && controller.text.trim().isEmpty;
    final Color? backgroundColor = highlighted
        ? theme.colorScheme.errorContainer
        : (unextractedAndEmpty ? Colors.yellow.withValues(alpha: 0.35) : null);

    return Container(
      key: ValueKey<String>('field-row-$id'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        // WHY: isValid=false の抽出値と FR-6 の検証違反は確認対象として
        // 目立たせる。v2 UX 改修3 で未抽出＋未入力欄にも黄色系の背景を付す。
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: ValueKey<String>('field-input-$id'),
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label),
          ),
          _buildStatus(theme),
        ],
      ),
    );
  }

  /// フィールドの補助情報（未抽出 / 信頼度 / validationMessage / FR-6 検証）。
  Widget _buildStatus(ThemeData theme) {
    final ExtractedField? extracted = field;
    if (extracted == null) {
      // WHY: 実測で抽出されない項目（Wave 2 未接続時の level 等）は手入力が基本の運用になる。
      // Wave 2（ST-5 リージョン再 OCR）完了後は level が抽出値を持つ可能性があり、
      // 未抽出時は手入力を促す表示にする（VR-1 は自動計算ではなく整合性検証のため
      // ここで自動値を入れない）。
      // FR-6: 未抽出でも手入力値に対する検証違反は表示する。
      if (issues.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _buildIssueTexts(theme),
        );
      }
      return Text('未抽出（手入力）', style: theme.textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _confidenceText(extracted.confidence),
          style: theme.textTheme.bodySmall,
        ),
        if (!extracted.isValid)
          Text(
            extracted.validationMessage ?? '値が範囲外です',
            style: _issueStyle(theme),
          ),
        // FR-6: 整合性検証のメッセージ。OCR の validationMessage とは発生源が
        // 異なるため併記する。
        ..._buildIssueTexts(theme),
      ],
    );
  }

  /// FR-6: 検証メッセージの Text 群（FR-3 の validationMessage と同じ強調）。
  ///
  /// 段階 B から 1 行に複数 issue（例: VR-2′ と VR-1）が併記され得る。
  List<Widget> _buildIssueTexts(ThemeData theme) {
    return <Widget>[
      for (final ValidationIssue issue in issues)
        Text(issue.message, style: _issueStyle(theme)),
    ];
  }

  /// WHY: validationMessage と FR-6 検証メッセージで同じ強調スタイルを共有する。
  TextStyle? _issueStyle(ThemeData theme) {
    return theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
      fontWeight: FontWeight.bold,
    );
  }
}

/// 曲名フィールドの入力行。
///
/// WHY: 曲名は ST-4 Wave 1 の抽出対象外（fullText 冒頭はアンカーに使えない・
/// field_extractor.dart 参照）のため、常に手入力欄として表示する。
/// ST-5 曲名照合（収録曲 DB）で抽出値が入る想定。
class _SongNameFieldRow extends StatelessWidget {
  const _SongNameFieldRow({required this.controller, this.onSearch});

  final TextEditingController controller;

  /// 曲名の全件検索画面を開くコールバック（null なら虫めがねを出さない）。
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // WHY(v2 UX 改修3): 曲名は ST-4 抽出対象外のため常に「未抽出」扱い。
    // 未入力の間は数値欄と同じ黄色系の背景で「まだ確認していない」ことを示す
    //（入力でライブ解除）。数値欄の黄色と同一値は _NumericFieldRow 側の WHY
    // コメントにまとめてある（tying は本テストでも固定）。
    final bool unextractedAndEmpty = controller.text.trim().isEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        key: const ValueKey<String>('field-row-songName'),
        // WHY(左右 0): 数値欄（_NumericFieldRow）は左右 padding を持たないため、
        // ここだけ horizontal: 8 を付けると曲名欄だけ 8px 内側に縮み、数値欄と
        // 位置が揃わず右にずれて見える（01a2106d-b0c1）。上下 2 は数値欄と同じ
        // 行内余白、行間は外側の Padding(top: 8) が持つ。
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: unextractedAndEmpty
              ? Colors.yellow.withValues(alpha: 0.35)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('field-input-songName'),
              controller: controller,
              // WHY: ライブ候補は 3 件で打ち切るため、入力中にそのまま全件検索へ
              // 移れる入口を欄の中に置く（ユーザー要望 2026-11-25）。
              decoration: InputDecoration(
                labelText: '曲名',
                suffixIcon: onSearch == null
                    ? null
                    : IconButton(
                        key: const ValueKey<String>('song-name-search-button'),
                        icon: const Icon(Icons.search),
                        tooltip: '曲名を検索',
                        onPressed: onSearch,
                      ),
              ),
            ),
            Text('未抽出（手入力）', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// 検出件数と要確認件数をまとめたヘッダー。
class _ResultSummaryHeader extends StatelessWidget {
  const _ResultSummaryHeader({
    required this.elementCount,
    required this.lowConfidenceCount,
    required this.unknownConfidenceCount,
  });

  final int elementCount;
  final int lowConfidenceCount;
  final int unknownConfidenceCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('検出要素: $elementCount 件', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '要確認: $lowConfidenceCount 件'
                '（信頼度 ${(kLowConfidenceThreshold * 100).toStringAsFixed(0)}% 未満）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '信頼度不明: $unknownConfidenceCount 件',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.tertiary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// OCR にかけた元画像のプレビュー。
class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.imageFile});

  /// 原画像。写真なし手入力モードでは null（v4 案2）。
  final File? imageFile;

  @override
  Widget build(BuildContext context) {
    final File? image = imageFile;
    if (image == null) {
      // WHY(v4 案2): 原画像が存在しないためプレビュー領域自体を出さない。
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      // WHY Card ではなく ClipRRect(8) か（2026-11-26 のユーザー指示
      // 「記録詳細画面のイメージです」）: 同じ記録の画像を確認画面と詳細画面で
      // 見比べるため、角丸半径（8）・高さ（240）・拡大縮小の条件を記録詳細画面
      // （play_record_detail_screen.dart の _imagePreview）と揃える。
      // 記録詳細側も高さ 240・ClipRRect(8)・InteractiveViewer(1.0〜3.0) で、
      // 差は原画像の有無だけになる。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 240,
          width: double.infinity,
          // WHY(v2 UX 改修2): プレーシェア画像の細部（判定文字・レベル表記）を
          // 確認できるよう、枠内で拡大縮小・パンできる InteractiveViewer で包む。
          // minScale 1.0 = 原寸より縮小しない（縮小は視認性を下げるだけ）。
          // maxScale 3.0 = 判定文字の判読に足る倍率。表示枠（高さ 240）は
          // 変えず、枠内トランスフォーム（既定の hardEdge クリップ）に留める。
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 3.0,
            child: Image.file(
              image,
              fit: BoxFit.contain,
              // WHY: 画像が読めない環境（テスト・ファイル移動後など）でも
              // 画面が壊れないようにする（PoC の防御表示）。
              errorBuilder: (_, _, _) =>
                  const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        ),
      ),
    );
  }
}

/// テキストが 1 件も検出されなかった場合の表示。
class _EmptyResult extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'テキストは検出されませんでした',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}

/// [OcrElement] 1 件分のタイル。
///
/// 低信頼度項目は errorContainer 色、「信頼度不明」項目は tertiaryContainer 色
/// のカードで強調し、trailing にバッジを表示する。
class _OcrElementTile extends StatelessWidget {
  const _OcrElementTile({required this.index, required this.element});

  /// 0 始まりの要素番号（表示時は +1 する）。
  final int index;

  final OcrElement element;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;

    final bool unknownConfidence = element.hasUnknownConfidence;
    final bool lowConfidence =
        !unknownConfidence && element.confidence < kLowConfidenceThreshold;
    final bool needsReview = unknownConfidence || lowConfidence;

    final Color? tileColor = lowConfidence
        ? colorScheme.errorContainer
        : unknownConfidence
        ? colorScheme.tertiaryContainer
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        color: tileColor,
        child: ListTile(
          leading: _buildIndexLabel(theme),
          title: Text(element.text.isEmpty ? '（空テキスト）' : element.text),
          subtitle: _buildSubtitle(theme),
          trailing: needsReview
              ? _ReviewBadge(lowConfidence: lowConfidence)
              : null,
        ),
      ),
    );
  }

  /// 先頭の要素番号ラベル。
  Widget _buildIndexLabel(ThemeData theme) {
    return SizedBox(
      width: 28,
      child: Text(
        '${index + 1}',
        textAlign: TextAlign.center,
        style: theme.textTheme.titleSmall,
      ),
    );
  }

  /// 信頼度とバウンディングボックス座標の補助表示。
  Widget _buildSubtitle(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          _confidenceText(element.confidence),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          _boundingBoxLabel(element.boundingBox),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 「要確認」／「信頼度不明」バッジ。
class _ReviewBadge extends StatelessWidget {
  const _ReviewBadge({required this.lowConfidence});

  /// true なら低信頼度（要確認）、false なら信頼度不明を表示する。
  final bool lowConfidence;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color background = lowConfidence
        ? colorScheme.error
        : colorScheme.tertiary;
    final Color foreground = lowConfidence
        ? colorScheme.onError
        : colorScheme.onTertiary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(1000),
      ),
      child: Text(
        lowConfidence ? '要確認' : '信頼度不明',
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 0 要素着地時の通知 1 行（smoke test 修正②）。
///
/// WHY: 読めない画像では全項目空フォームに着地し「読めなかった」ことが
/// 伝わらず、ユーザーが FR-3 手入力を自力で発見する必要があった。
/// 自動読み取りの失敗を明示し、手入力への導線を 1 行で伝える。
class _ZeroElementsNotice extends StatelessWidget {
  const _ZeroElementsNotice();

  /// 通知文言（red テストで文言を固定する）。
  static const String message = '自動読み取りできませんでした。値を手動で入力してください';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.info_outline,
            size: 18,
            color: colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信頼度の表示ラベル（センチネル値は「不明」と表示する）。
String _confidenceText(double confidence) {
  if (confidence == OcrElement.confidenceUnknown) {
    return '信頼度: 不明';
  }
  return '信頼度: ${(confidence * 100).toStringAsFixed(1)}%';
}

/// [Rect] を確認画面向けの座標ラベルに整形する。
String _boundingBoxLabel(Rect boundingBox) {
  return '位置: x=${boundingBox.left.toStringAsFixed(0)}'
      ', y=${boundingBox.top.toStringAsFixed(0)}'
      ', w=${boundingBox.width.toStringAsFixed(0)}'
      ', h=${boundingBox.height.toStringAsFixed(0)}';
}
