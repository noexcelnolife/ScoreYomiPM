import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../best/self_best_resolver.dart';
import '../data/memo_template_repository.dart';
import '../data/play_record.dart';
import '../data/play_record_repository.dart';
import '../ocr/ocr_engine.dart';
import '../ocr/pipeline.dart';
import '../ocr/song_repository.dart';
import 'difficulty_color.dart';
import 'file_export_gateway.dart';
import 'image_export.dart';
import 'ocr_result_screen.dart';
import 'song_title_live_search.dart';

/// FR-11: 記録詳細画面（全フィールド＋原画像）。
///
/// FR-12 の修正・削除・再 OCR の入口もこの画面に集約する。
/// null 項目の表示規約は設計確認書 §3.2（曲名→（曲名未入力）、数値→「—」、
/// 難易度/メダルは v1 で常時 null のため常設行で「—」表示）。
class PlayRecordDetailScreen extends StatefulWidget {
  const PlayRecordDetailScreen({
    super.key,
    required this.playRecordRepository,
    required this.ocrEngine,
    required this.recordId,
    this.mainSongRepository,
    this.additionalSongRepository,
    this.fileExportGateway,
    this.memoTemplateRepository,
  });

  /// 記録の保存先。
  final PlayRecordRepository playRecordRepository;

  /// 再 OCR に使う OCR エンジン。
  final OcrEngine ocrEngine;

  /// 表示対象のレコード id。
  ///
  /// WHY: レコード実体ではなく id を受ける。修正・削除後の再読込
  /// （findById）をこの画面自身で完結させるため。
  final String recordId;

  /// 再 OCR 時の曲名マッチ用リポジトリ（任意注入・経由渡し）。
  final SongRepository? mainSongRepository;

  /// 再 OCR 時のローカル追加 DB リポジトリ（任意注入・経由渡し）。
  final SongRepository? additionalSongRepository;

  /// 原画像をアプリ外へ保存するときの入出力（任意注入）。
  ///
  /// WHY: 保存ダイアログはプラットフォームチャネルを使うため widget テストから
  /// 呼べない。未指定なら実端末向け実装を使い、テストでは fake を注入する。
  final FileExportGateway? fileExportGateway;

  /// メモのテンプレート供給元（修正画面へ経由渡し・任意）。
  ///
  /// WHY この画面が持つか: メモの編集は「修正」＝[OcrResultScreen] で行うため、
  /// ここで受け取ったものをそのまま渡す（渡さなければテンプレートボタンは出ない）。
  final MemoTemplateRepository? memoTemplateRepository;

  /// この画面への [MaterialPageRoute] を生成する。
  static Route<void> route({
    required PlayRecordRepository playRecordRepository,
    required OcrEngine ocrEngine,
    required String recordId,
    SongRepository? mainSongRepository,
    SongRepository? additionalSongRepository,
    FileExportGateway? fileExportGateway,
    MemoTemplateRepository? memoTemplateRepository,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => PlayRecordDetailScreen(
        playRecordRepository: playRecordRepository,
        ocrEngine: ocrEngine,
        recordId: recordId,
        mainSongRepository: mainSongRepository,
        additionalSongRepository: additionalSongRepository,
        fileExportGateway: fileExportGateway,
        memoTemplateRepository: memoTemplateRepository,
      ),
    );
  }

  @override
  State<PlayRecordDetailScreen> createState() => _PlayRecordDetailScreenState();
}

class _PlayRecordDetailScreenState extends State<PlayRecordDetailScreen> {
  /// 表示対象のレコード。読み込み完了まで null。
  PlayRecord? _record;

  /// 初回読み込み中フラグ。
  bool _isLoading = true;

  /// レコードが見つからない（開いた後に削除された等）場合のフラグ。
  bool _notFound = false;

  /// FR-7: 自己ベストとみなすレコード id の集合。
  ///
  /// WHY: 保存せず表示時に resolver で毎回算出する（設計 §3/§4・表示時導出）。
  /// 修正・削除後の再読込でも常に正しい best が反映される。
  Set<String> _selfBestIds = const <String>{};

  /// 曲名入力のライブサジェスト用の辞書検索（修正・再 OCR へ注入）。
  ///
  /// WHY(01a21152): ユーザー要望「スコア修正の時にも曲名DBをもとに曲名サジェスト
  /// してください」により、この画面から開く曲名入力でも辞書検索を配線する。
  /// 詳細画面の生存中は同じ辞書を使い回す（辞書構築は初回検索時の 1 回だけ）。
  late final LiveSongTitleSearch _songTitleSearch = LiveSongTitleSearch(
    mainSongRepository: widget.mainSongRepository,
    additionalSongRepository: widget.additionalSongRepository,
  );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// レコードを読み込み直す。
  ///
  /// WHY: 修正・削除・再 OCR のたびに呼び出して常に最新状態を表示する。
  /// レコードが消えていた場合（削除後の戻り等）は詳細を閉じる。
  /// FR-7: best 判定のため全レコードを同時に読み込む（既存 listAll・直接遷移と
  /// 再読込の正確性確保・設計 §6）。
  Future<void> _reload() async {
    final PlayRecord? record = await widget.playRecordRepository.findById(
      widget.recordId,
    );
    final List<PlayRecord> records = await widget.playRecordRepository
        .listAll();
    if (!mounted) {
      return;
    }
    if (record == null) {
      // WHY: 削除済みレコードを開けないため詳細を閉じる。
      // root に直接置かれた場合（テスト等）maybePop は no-op のため、
      // 「見つからない」状態表示へフォールバックする。
      await Navigator.of(context).maybePop();
      if (mounted) {
        setState(() {
          _notFound = true;
          _isLoading = false;
        });
      }
      return;
    }
    setState(() {
      _record = record;
      _selfBestIds = resolveSelfBestIds(records.map(_toCandidate).toList());
      _isLoading = false;
    });
  }

  /// FR-7: レコードを resolver の入力へ変換する。
  ///
  /// WHY: v1 の比較キーは songName（未確定 = null）・score null は resolver 側の
  /// 規約で排除される（設計 §1.2/§2.3）。難易度をまたぐ比較競合は v1 既知限界
  ///（difficulty 未記録）であり song_id + difficulty 着地時に解消。
  SelfBestCandidate _toCandidate(PlayRecord record) {
    return SelfBestCandidate(
      id: record.id,
      key: record.songName,
      score: record.score,
      playedAt: record.playedAt,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('記録詳細')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final PlayRecord? record = _record;
    if (_notFound || record == null) {
      return const Center(child: Text('レコードが見つかりません'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // WHY(v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.5): 写真なし
        // 手入力のレコードには原画像が存在しないため、プレビュー節ごと非表示
        // にする（誤解を招く「見つかりません」表示を避ける）。
        if (record.resultImagePath.isNotEmpty) ...<Widget>[
          _imagePreview(record),
          const SizedBox(height: 8),
          // WHY(位置): 原画像がある行にだけ出す操作なので、プレビューの直下に
          // 置く（プレビュー節ごと非表示になる条件と一致させる）。
          // 配置は右揃えではなく中央揃え（ユーザー指示 01a21087）。
          Center(child: _exportImageButton(record)),
        ],
        const SizedBox(height: 12),
        _actionButtons(context, record),
        const SizedBox(height: 12),
        _fieldsCard(context, record),
      ],
    );
  }

  /// 原画像プレビュー（縦横比維持・高さ上限 240・欠損時フォールバック）。
  Widget _imagePreview(PlayRecord record) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 240,
        width: double.infinity,
        // WHY(v2 UX #14・ユーザー裁定 2026-11-23): 履歴詳細画面でも原画像の
        // 細部（判定文字・レベル表記等）を確認できるよう、枠内で拡大縮小・パン
        // できる InteractiveViewer で包む。ユーザー裁定「詳細画面では拡大縮小・
        // 一覧では不要」により play_records_screen（一覧）は対象外で触らない。
        // #12（ocr_result_screen の _ImagePreview）と同一条件（minScale 1.0 /
        // maxScale 3.0・パン有効・既定の hardEdge クリップ）で拡大縮小の統一
        // 原則を踏襲する。表示枠（高さ 240）は変えず、変換は枠内に留める。
        // 共通ウィジェットへの抽出はしない（KISS: 使い先の枠サイズ・レイアウト
        // が異なるため、重複 10 行程度の直書きを許容する）。
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 3.0,
          child: Image.file(
            File(record.resultImagePath),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.broken_image_outlined),
                SizedBox(height: 8),
                Text('画像ファイルが見つかりません'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 原画像を「アプリ外に保存」するボタン（タスク 01a2106d）。
  ///
  /// WHY: アプリの内部領域にしか画像が無いと、ユーザーが他のアプリや
  /// クラウドへ結果画像を渡せない。端末の保存ダイアログ経由で書き出せるように
  /// する（コピーを 1 部作るだけで、元の画像は残す）。
  Widget _exportImageButton(PlayRecord record) {
    return OutlinedButton.icon(
      key: const ValueKey<String>('export-image-button'),
      onPressed: () => _exportImage(record),
      icon: const Icon(Icons.save_alt),
      label: const Text('アプリ外に保存'),
    );
  }

  /// 原画像を読み、保存ダイアログで書き出す。
  Future<void> _exportImage(PlayRecord record) async {
    final Uint8List? bytes = await _readImageBytes(record.resultImagePath);
    if (!mounted) {
      return;
    }
    if (bytes == null) {
      _showSnackBar('画像が見つかりません');
      return;
    }
    final String? savedPath = await _fileExportGateway.saveBytes(
      bytes: bytes,
      fileName: buildImageExportFileName(
        recordId: record.id,
        songName: record.songName,
        imagePath: record.resultImagePath,
        now: DateTime.now(),
      ),
      mimeType: mimeTypeForImagePath(record.resultImagePath),
    );
    if (!mounted || savedPath == null) {
      // WHY: 保存ダイアログのキャンセル（null）は利用者の意思なので
      // 何も通知しない（バックアップ画面のキャンセルと同じ扱い）。
      return;
    }
    _showSnackBar('保存しました');
  }

  /// 原画像のバイト列を読む。存在しない・読めない場合は null。
  ///
  /// WHY: 存在確認と読み込みは別の操作なので、確認直後にファイルが消えた
  /// 場合や権限エラーも同じ「見つかりません」表示に寄せる（利用者にとって
  /// 結果は同じで、どちらも保存できる画像が無い）。
  Future<Uint8List?> _readImageBytes(String path) async {
    final File file = File(path);
    try {
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// 画面下部に [message] を 1 行で出す。
  void _showSnackBar(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  FileExportGateway get _fileExportGateway =>
      widget.fileExportGateway ?? const PlatformFileExportGateway();

  /// アクション行: 修正 / 再OCR（未確定のみ） / 削除。
  ///
  /// WHY: 再 OCR は未確定レコードのみ表示する。確定済みへの再 OCR は
  /// 確定内容の誤上書きにつながるため（設計確認書 §3.2）。
  Widget _actionButtons(BuildContext context, PlayRecord record) {
    final bool isPending = record.status == PlayRecordStatus.pending;
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey<String>('edit-record-button'),
            onPressed: _openEdit,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('修正'),
          ),
        ),
        if (isPending) ...<Widget>[
          const SizedBox(width: 8),
          OutlinedButton(
            key: const ValueKey<String>('rerun-ocr-button'),
            onPressed: () => _rerunOcr(record),
            child: const Text('再OCR'),
          ),
        ],
        const SizedBox(width: 8),
        OutlinedButton(
          key: const ValueKey<String>('delete-record-button'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => _confirmDelete(),
          child: const Text('削除'),
        ),
      ],
    );
  }

  /// 全フィールドの一覧カード。null 項目の規約は設計確認書 §3.2。
  Widget _fieldsCard(BuildContext context, PlayRecord record) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 並び順（01a20b34・ユーザー指示 2026-11-24）:
            // クリアメダル → 難易度 → レベル → 曲名 → スコア → 判定内訳
            // （COOL/GREAT/GOOD/BAD）→ MAX COMBO → 機種 → メモ。
            // WHY: 入力画面と同じ並びに揃え、ゲーム内リザルト画面の順序に
            // 合わせる（旧順は難易度・機種がレベルより上にあり、入力画面の
            // 新順と食い違っていた）。日時（ヘッダ情報）は先頭、状態・記録元
            // （メタ情報）は末尾。メモは 2026-11-26 に追加した自由文で、
            // 値があるときだけ表示する。
            _fieldRow('日時', _formatPlayedAt(record.playedAt)),
            _fieldRow('メダル', _medalLabelText(record.clearMedal)),
            _fieldRow(
              '難易度',
              record.difficulty == null
                  ? '—'
                  : record.difficulty!.name.toUpperCase(),
              // 難易度カラーリング（01a20a53）: 一覧副題と同じ単一真実源・同じ
              // 明度で着色する。'—'（不明）は従来の既定色（値 Text）のまま。
              // 01a20b17: コピー対象になったため SelectableText 化する。色は
              // SelectableText の style に渡して維持する（TextSpan に分解不要）。
              valueWidget: record.difficulty == null
                  ? null
                  : SelectableText(
                      record.difficulty!.name.toUpperCase(),
                      style: TextStyle(
                        color: difficultyColor(
                          record.difficulty,
                          brightness: Theme.of(context).brightness,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            _fieldRow(
              'レベル',
              record.level == null ? '—' : 'Lv${record.level}',
              selectable: record.level != null,
            ),
            // コピー可能テキスト（01a20b17・ユーザー指示 2026-11-24「曲名、
            // スコアや判定数の数字をコピー可能なテキストにできますか」）:
            // ユーザー確認の結果、対象は **8 値 = 7 行**に確定 = 曲名・スコア・
            // 判定内訳（COOL/GREAT/GOOD/BAD を 1 行に同居）・MAX COMBO・難易度
            // ・レベル・機種。日時・メダル・状態・記録元は確定スコープ外のため
            // 非対象（メダル行は詳細画面でも通常の Text 行、状態行は Chip）。
            // メモ（2026-11-26 追加）は本文をそのまま持ち帰りたいので selectable
            // に含める。上記の「8 値」は当時の確定スコープの記録であり、この
            // 追加でメモが加わった。
            _fieldRow(
              '曲名',
              record.songName ?? '（曲名未入力）',
              selectable: record.songName != null,
            ),
            _fieldRow(
              'スコア',
              record.score == null ? '—' : _formatScore(record.score!),
              valueWidget: record.score == null ? null : _scoreValue(record),
            ),
            _fieldRow('判定内訳', _formatJudgments(record), selectable: true),
            _fieldRow(
              'MAX COMBO',
              record.maxCombo == null ? '—' : '${record.maxCombo}',
              selectable: record.maxCombo != null,
            ),
            _fieldRow(
              '機種',
              record.machine == null || record.machine!.isEmpty
                  ? '—'
                  : record.machine!,
              selectable: record.machine != null && record.machine!.isNotEmpty,
            ),
            // メモ（2026-11-26）: 値があるときだけ行を出す。WHY 空でも行を
            // 出さないか: 詳細画面は「記録に何が入っているか」を読む場所で、
            // 未入力のメモ行は情報量ゼロのまま視線を奪うため。本文は長くなり
            // うるのでコピーできるよう SelectableText にする。
            if (record.memo != null && record.memo!.isNotEmpty)
              _fieldRow('メモ', record.memo!, selectable: true),
            _fieldRow(
              '状態',
              '',
              valueWidget: _StatusChipView(status: record.status),
            ),
            _fieldRow('記録元', _sourceLabel(record.source)),
          ],
        ),
      ),
    );
  }

  /// 詳細行 1 件（ラベル固定幅＋値）。
  ///
  /// [selectable] が true の行は値を [SelectableText] で描画し、長押し選択・
  /// コピーを可能にする（01a20b17）。WHY 既定を false にしたか: コピー対象は
  /// ユーザー確認で **8 値 = 7 行**（曲名・スコア・判定内訳・MAX COMBO・難易度
  /// ・レベル・機種）に確定しており、日時・メダル・状態・記録元まで選択可能に
  /// すると長押し時の選択メニューが意図せず出て操作の邪魔になるため
  /// （対象行のみ opt-in）。
  ///
  /// null の「—」プレースホルダは呼び出し側で selectable を false にして渡す
  /// （コピーする中身が無いため。表示規約は設計確認書 §3.2 のまま不変）。
  Widget _fieldRow(
    String label,
    String value, {
    Widget? valueWidget,
    bool selectable = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child:
                valueWidget ??
                (selectable ? SelectableText(value) : Text(value)),
          ),
        ],
      ),
    );
  }

  /// FR-7: スコア値 + 自己ベスト chip。
  ///
  /// WHY: v1 は is_self_best を保存せず表示時導出する（設計 §3/§4）。比較は
  /// songName 一致キー内の最大スコアで、v1 は difficulty 未記録のため難易度を
  /// またぐスコアが比較競合する既知限界がある（resolver モジュール doc 参照・
  /// song_id + difficulty 着地時に解消）。フラグ保持方式と異なり修正・削除後も
  /// 再読込時に常に正しい best が表示される。
  Widget _scoreValue(PlayRecord record) {
    final bool isSelfBest = _selfBestIds.contains(record.id);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // スコアはコピー対象（01a20b17）。「自己ベスト」Chip はラベルであって
        // 値ではないため選択対象に含めない（Row の外側に置いたまま）。
        SelectableText(_formatScore(record.score!)),
        if (isSelfBest) ...<Widget>[
          const SizedBox(width: 8),
          const Chip(label: Text('自己ベスト')),
        ],
      ],
    );
  }

  /// 日時を `yyyy/MM/dd HH:mm` で整形する。
  String _formatPlayedAt(DateTime playedAt) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${playedAt.year}/${two(playedAt.month)}/${two(playedAt.day)} '
        '${two(playedAt.hour)}:${two(playedAt.minute)}';
  }

  /// スコアを 3 桁区切りで整形する（98108 → 98,108）。
  String _formatScore(int score) {
    final String digits = score.toString();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      final int remaining = digits.length - i;
      buffer.write(digits[i]);
      if (remaining > 1 && (remaining - 1) % 3 == 0) {
        buffer.write(',');
      }
    }
    return buffer.toString();
  }

  /// 判定内訳を 1 行に整形する。null 判定は個別に「—」とする。
  String _formatJudgments(PlayRecord record) {
    String? orDash(int? value) => value?.toString() ?? '—';
    return 'COOL ${orDash(record.cool)} / GREAT ${orDash(record.great)} '
        '/ GOOD ${orDash(record.good)} / BAD ${orDash(record.bad)}';
  }

  /// 記録元の表示名。v1 は playshare のみ。
  String _sourceLabel(PlayRecordSource source) {
    switch (source) {
      case PlayRecordSource.playshare:
        return 'プレーシェア';
    }
  }

  /// 修正: 手入力モードの確認画面（FR-4 実装）へ遷移する。
  ///
  /// WHY: FR-4 で「既存値の復元 → 全上書き update → 成功/失敗 SnackBar →
  /// 二重保存防止」まで実装済みのため、新規編集画面は作らず再利用する
  /// （設計確認書 §3.3）。appBarTitle のみ「スコア修正」へ差し替える。
  Future<void> _openEdit() async {
    final PlayRecord? record = _record;
    if (record == null) {
      return;
    }
    await Navigator.of(context).push(
      OcrResultScreen.route(
        // WHY(v4 案2): 写真なし手入力のレコード（空パス）は原画像を渡せない
        // ため null にする（プレビューも非表示になる）。
        imageFile: record.resultImagePath.isEmpty
            ? null
            : File(record.resultImagePath),
        playRecordRepository: widget.playRecordRepository,
        existingRecordId: widget.recordId,
        appBarTitle: 'スコア修正',
        // WHY(01a21152): 修正は曲名を打ち直す場面なので、DB 由来の候補
        // サジェストを出す（ユーザー要望「スコア修正の時にも曲名DBをもとに
        // 曲名サジェスト」）。辞書はこの画面で 1 つだけキャッシュして使い回す。
        onSongTitleSearch: _songTitleSearch.search,
        onSongEntryResolve: _songTitleSearch.resolve,
        onSongSearchWide: _songTitleSearch.searchWide,
        memoTemplateRepository: widget.memoTemplateRepository,
      ),
    );
    if (mounted) {
      await _reload();
    }
  }

  /// 再 OCR: 保存済み画像へ OCR パイプラインを再実行して確認画面へ遷移する
  /// （FR-4 の未確定一覧実装と同一挙動）。
  Future<void> _rerunOcr(PlayRecord record) async {
    try {
      final OcrPipeline pipeline = OcrPipeline(
        engine: widget.ocrEngine,
        mainSongRepository: widget.mainSongRepository,
        additionalSongRepository: widget.additionalSongRepository,
      );
      final OcrPipelineContext pipelineContext = await pipeline.run(
        File(record.resultImagePath),
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        OcrResultScreen.route(
          imageFile: File(record.resultImagePath),
          pageResult: pipelineContext.pageResult,
          extractionResult: pipelineContext.extractionResult,
          songMatchResult: pipelineContext.songMatchResult,
          // WHY: 一次 OCR（home_screen._runOcr）と同一パターンで matchedSong
          // を渡す。smoke test（01a20390-7dcc）で発見された経路カバレッジ欠落
          // — 再 OCR 経路だけ渡さないと VR-1/VR-3 が確認画面で常に skip に
          // なり、段階 B 機能の非対称が生じるため。
          matchedSong: pipelineContext.matchedSong,
          playRecordRepository: widget.playRecordRepository,
          existingRecordId: widget.recordId,
          appBarTitle: 'スコア修正',
          // WHY(01a21152): 再 OCR 後の確認画面でも曲名を直せるため、修正経路と
          // 同じライブサジェストを配線する（曲名入力の全入口を揃える）。
          onSongTitleSearch: _songTitleSearch.search,
          onSongEntryResolve: _songTitleSearch.resolve,
          onSongSearchWide: _songTitleSearch.searchWide,
          memoTemplateRepository: widget.memoTemplateRepository,
        ),
      );
    } catch (error) {
      // WHY: 再 OCR の失敗で画面が閉じないよう catch して通知だけ出す。
      // レコードは未確定のまま残る。
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('再OCRに失敗しました: $error')));
    }
    if (mounted) {
      await _reload();
    }
  }

  /// 削除: 確認ダイアログで承認された場合のみ削除し、詳細を閉じる。
  Future<void> _confirmDelete() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('レコードの削除'),
        content: const Text('このレコードを削除しますか？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          // WHY: ValueKey は FR-4 の未確定一覧と統一（テスト互換）。
          TextButton(
            key: const ValueKey<String>('confirm-delete-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.playRecordRepository.delete(widget.recordId);
    if (!mounted) {
      return;
    }
    // WHY: 削除後は詳細を閉じて一覧へ戻る（一覧側で再読込される）。
    await Navigator.of(context).maybePop();
    if (mounted) {
      await _reload();
    }
  }
}

/// 状態チップ（[PlayRecordStatus] の 2 値表示・一覧と同じ規約）。
class _StatusChipView extends StatelessWidget {
  const _StatusChipView({required this.status});

  final PlayRecordStatus status;

  @override
  Widget build(BuildContext context) {
    final bool isPending = status == PlayRecordStatus.pending;
    final Color color = isPending
        ? Colors.orange.shade700
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isPending ? '未確定' : '確定',
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}

/// PlayRecord.clearMedal（String? / enum name）→ 表示ラベル。
///
/// WHY: 詳細画面でメダル未設定なら "—"、設定済みなら日本語ラベル
/// （フルコンボ / クリア / アシストクリア / イージークリア / 失敗）を表示。
String _medalLabelText(String? clearMedalName) {
  if (clearMedalName == null) return '—';
  switch (clearMedalName) {
    case 'fullComboFamily':
      return 'フルコンボ';
    case 'clear':
      return 'クリア';
    case 'assistClear':
      return 'アシストクリア';
    case 'easyClear':
      return 'イージークリア';
    case 'failed':
      return '失敗';
    default:
      return '—';
  }
}
