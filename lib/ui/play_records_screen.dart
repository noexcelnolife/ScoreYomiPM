import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../data/play_record.dart';
import '../data/play_record_repository.dart';
import '../data/play_record_stats.dart';
import '../ocr/ocr_engine.dart';
import '../ocr/song_repository.dart';
import 'difficulty_color.dart';
import 'play_record_detail_screen.dart';

/// FR-10: 記録一覧画面（確定・未確定の全レコード対象）。
///
/// FR-4 の未確定レコード一覧（`PendingRecordsScreen`）を全件対象へ発展した
/// 画面。未確定グループ → 確定グループの順に表示し、行タップで詳細画面
/// [PlayRecordDetailScreen]（FR-11）へ遷移する。
///
/// WHY: FR-4 の一覧は「未確定のみ」という一点を除けば FR-10 の骨格そのもの。
/// 新規に一覧画面を作ると画面・テスト・遷移が二重化するため、発展・リネームで
/// 統合する（設計確認書 §3.1・KISS）。
///
/// v4 案3 v2（docs/v4_list_best_stats_design_2026-11-23.md・2026-11-23 改訂）:
/// 統計サマリカード・表示順トグル（日付/スコア）・(曲名, 難易度) 別自己ベスト
/// バッジ・副題の難易度表示を追加。グループキーからレベルを外した理由
/// （バージョンで変わり得るため比較識別子にしない）は play_record_stats.dart の
/// WHY 参照。ソートは表示専用で、リポジトリの保存契約（listAll 無順序・
/// _reload が日付順にソート）は変更しない。
class PlayRecordsScreen extends StatefulWidget {
  const PlayRecordsScreen({
    super.key,
    required this.playRecordRepository,
    required this.ocrEngine,
    this.mainSongRepository,
    this.additionalSongRepository,
  });

  /// 記録の保存先。
  final PlayRecordRepository playRecordRepository;

  /// 詳細画面の再 OCR に使う OCR エンジン（経由渡し）。
  final OcrEngine ocrEngine;

  /// 詳細画面の再 OCR へ渡すメイン DB リポジトリ（経由渡し・任意注入）。
  final SongRepository? mainSongRepository;

  /// 詳細画面の再 OCR へ渡すローカル追加 DB リポジトリ（経由渡し・任意注入）。
  final SongRepository? additionalSongRepository;

  /// この画面への [MaterialPageRoute] を生成する。
  static Route<void> route({
    required PlayRecordRepository playRecordRepository,
    required OcrEngine ocrEngine,
    SongRepository? mainSongRepository,
    SongRepository? additionalSongRepository,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => PlayRecordsScreen(
        playRecordRepository: playRecordRepository,
        ocrEngine: ocrEngine,
        mainSongRepository: mainSongRepository,
        additionalSongRepository: additionalSongRepository,
      ),
    );
  }

  @override
  State<PlayRecordsScreen> createState() => _PlayRecordsScreenState();
}

class _PlayRecordsScreenState extends State<PlayRecordsScreen> {
  /// 未確定レコード（playedAt 降順）。読み込み完了までは空。
  List<PlayRecord> _pendingRecords = const <PlayRecord>[];

  /// 確定レコード（playedAt 降順）。読み込み完了までは空。
  List<PlayRecord> _confirmedRecords = const <PlayRecord>[];

  /// 初回読み込み中フラグ。
  bool _isLoading = true;

  /// 表示順トグルの選択値（UI 状態のみ保持）。
  ///
  /// WHY: listAll のデータ順（_reload が実施日降順にソート）は保存契約として
  /// 保ち、並び替えは画面側の表示処理で完結させる（v4 案3 §2）。
  String _sortMode = _sortModeDate;

  static const String _sortModeDate = 'sort-date';
  static const String _sortModeScore = 'sort-score';

  /// 曲名検索の入力欄のコントローラ（01a20b92）。
  ///
  /// WHY コントローラを持つか: クリアボタンとサジェスト候補タップで表示中の
  /// 文字列を書き換える必要がある。TextField の表示と [_query] がずれるのを
  /// 避けるため 1 つのコントローラを唯一の真実源にする。
  final TextEditingController _searchController = TextEditingController();

  /// 曲名検索語（生の入力値。比較には [_normalizedQuery] を使う）。
  String _query = '';

  /// サジェスト候補の最大表示件数。
  ///
  /// WHY 上限を設けるか: 記録が増えると候補が数十件になり、チップの壁で一覧が
  /// 埋もれる。超過分は「他 N 件」で件数だけ示し、黙って隠さない。
  static const int _maxSuggestions = 8;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// リポジトリから全レコードを読み込み、未確定/確定に分けてソートする。
  ///
  /// WHY: 詳細画面での修正・削除・再 OCR の後や、一覧から戻るたびに呼び出して
  /// 常に最新状態を表示する。ソートはデータ層ではなく UI 側で行う
  /// （リポジトリ API にソート引数を追加しない — KISS）。
  Future<void> _reload() async {
    final List<PlayRecord> all = await widget.playRecordRepository.listAll();
    if (!mounted) {
      return;
    }
    final List<PlayRecord> pending =
        all
            .where(
              (PlayRecord record) => record.status == PlayRecordStatus.pending,
            )
            .toList()
          ..sort(
            (PlayRecord a, PlayRecord b) => b.playedAt.compareTo(a.playedAt),
          );
    final List<PlayRecord> confirmed =
        all
            .where(
              (PlayRecord record) =>
                  record.status == PlayRecordStatus.confirmed,
            )
            .toList()
          ..sort(
            (PlayRecord a, PlayRecord b) => b.playedAt.compareTo(a.playedAt),
          );
    setState(() {
      _pendingRecords = pending;
      _confirmedRecords = confirmed;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isEmpty = _pendingRecords.isEmpty && _confirmedRecords.isEmpty;
    // WHY 毎回 build で再計算: CSV 保存規模（数百件）なら統計・ベスト集計は
    // 体感差がなく、キャッシュすると更新漏れの stale バグを招く（v4 案3 §2）。
    final List<PlayRecord> allRecords = <PlayRecord>[
      ..._pendingRecords,
      ..._confirmedRecords,
    ];
    final Set<String> bestRecordIds = personalBestRecordIds(allRecords);
    // 01a20b92: フィルタ→ソートの順で合成する（検索結果にも選択中ソートが効く）。
    final List<PlayRecord> shownPending = _filtered(_pendingRecords);
    final List<PlayRecord> shownConfirmed = _filtered(_confirmedRecords);
    final bool hasNoMatch =
        _isSearching && shownPending.isEmpty && shownConfirmed.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('記録一覧')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : isEmpty
          ? const Center(child: Text('記録はありません'))
          : ListView(
              children: <Widget>[
                // WHY: 0 件のグループの見出しは表示しない（情報量 0 の
                // 見出しは視認性を下げる。テストで規約を固定）。
                // v4 案3: 統計カードとソート切替はレコード 1 件以上ある
                // ときのみ（空時は上の isEmpty 枝が ListView 一式を差し替える）。
                // 01a20b92: 検索欄はレコード 1 件以上あるとき常設
                // （検索対象が 0 件なら出しても無意味なので空時は出さない）。
                // WHY 統計カードは全件基準のままか: 総記録数・演奏曲数・
                // フルコンボは「記録全体のサマリ」であり、検索で数字が
                // 動くと絞り込み表示と混同される。検索結果の件数は
                // グループ見出し（「確定 N 件」等）側で示す。
                _buildStatsCard(context, allRecords),
                _buildSearchField(),
                _buildSuggestions(allRecords),
                _buildSortSelector(),
                if (hasNoMatch) _buildNoMatch(),
                if (shownPending.isNotEmpty)
                  ..._buildGroup(
                    context,
                    '未確定 ${shownPending.length} 件',
                    _displayOrder(shownPending),
                    const <String>{},
                  ),
                if (shownConfirmed.isNotEmpty)
                  ..._buildGroup(
                    context,
                    '確定 ${shownConfirmed.length} 件',
                    _displayOrder(shownConfirmed),
                    bestRecordIds,
                  ),
              ],
            ),
    );
  }

  /// 検索語（前後空白を除去し小文字化した比較用の値）。
  ///
  /// WHY: 空クエリ=全件、ASCII は大文字小文字を区別しない、が既定値
  /// （2026-11-24 ユーザー承認）。空白のみの入力は空クエリとして扱う。
  String get _normalizedQuery => _query.trim().toLowerCase();

  /// 検索中か（空クエリなら false）。
  bool get _isSearching => _normalizedQuery.isNotEmpty;

  /// 曲名検索の絞り込み（非破壊）。
  ///
  /// WHY 非破壊か: 呼び出し元の _pendingRecords/_confirmedRecords は保存順
  /// （playedAt 降順）の契約を持つため、絞り込み結果は新しいリストで返す。
  List<PlayRecord> _filtered(List<PlayRecord> records) {
    if (!_isSearching) {
      return records;
    }
    final String query = _normalizedQuery;
    return records
        .where((PlayRecord record) => _matchesQuery(record, query))
        .toList();
  }

  /// 1 レコードが検索語に一致するか。
  ///
  /// WHY 曲名 null は不一致か: 「（曲名未入力）」は表示上のプレースホルダで、
  /// 曲名として検索語に一致させる意味が無い（既定値として承認済み）。
  bool _matchesQuery(PlayRecord record, String query) {
    final String? name = record.songName;
    return name != null && name.toLowerCase().contains(query);
  }

  /// 曲名検索欄（一覧上部に常設・入力中のみクリアボタン）。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        key: const ValueKey<String>('records-search-field'),
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: '曲名で検索',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          // WHY 入力中だけ出すか: 消す対象が無いときにボタンを出すと
          // 「何か消せる」という誤解を与える。
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey<String>('records-search-clear'),
                  tooltip: '検索をクリア',
                  icon: const Icon(Icons.clear),
                  onPressed: _clearSearch,
                ),
        ),
        onChanged: (String value) => setState(() => _query = value),
      ),
    );
  }

  /// 検索語を空へ戻す（全件表示に復帰）。
  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  /// 検索語に一致する曲名の候補チップ（レコード由来・重複排除・上限あり）。
  Widget _buildSuggestions(List<PlayRecord> allRecords) {
    final List<String> names = _suggestionNames(allRecords);
    if (names.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<String> shown = names.take(_maxSuggestions).toList();
    final int hidden = names.length - shown.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        key: const ValueKey<String>('records-suggestions'),
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          for (final String name in shown)
            ActionChip(
              key: ValueKey<String>('records-suggestion-$name'),
              label: Text(name),
              onPressed: () => _applySuggestion(name),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '他 $hidden 件',
                key: const ValueKey<String>('records-suggestion-overflow'),
              ),
            ),
        ],
      ),
    );
  }

  /// サジェスト候補（保存済みレコードの曲名・重複排除・昇順）。
  ///
  /// WHY レコード由来か: 曲名 DB 全件から候補を出すと「記録が 1 件も無い曲」を
  /// 選べてしまい、検索結果が常に空になる（2026-11-24 ユーザー合意）。
  ///
  /// 完全一致した候補だけを集合から除く（部分一致で残る候補はそのまま出す）。
  /// WHY サジェスト全体を消さないか: 曲名の末尾に数字や UPPER が付いただけの
  /// 別曲（例: 'Harmonia' と 'Harmonia2'）が多数あるため、全体非表示にすると
  /// 「近い別曲」を選べなくなる（2026-11-24 ユーザー指摘）。全候補が完全一致
  /// した場合だけ集合が空になり、コンテナは既存どおり非表示になる。
  List<String> _suggestionNames(List<PlayRecord> allRecords) {
    if (!_isSearching) {
      return const <String>[];
    }
    final String query = _normalizedQuery;
    final Set<String> names = <String>{};
    for (final PlayRecord record in allRecords) {
      final String? name = record.songName;
      if (name == null || name.isEmpty) {
        continue;
      }
      final String lower = name.toLowerCase();
      if (!lower.contains(query) || lower == query) {
        continue;
      }
      names.add(name);
    }
    final List<String> sorted = names.toList()
      ..sort((String a, String b) {
        // WHY 小文字比較を先に見るか: 入力中に候補が増減しても順序が安定する。
        final int byLower = a.toLowerCase().compareTo(b.toLowerCase());
        return byLower != 0 ? byLower : a.compareTo(b);
      });
    return sorted;
  }

  /// 候補タップ: 検索語を候補の曲名で確定する。
  ///
  /// WHY _sortMode を触らないか: 「サジェスト選択後も選択中のソートが効く」
  /// という要件を、フィルタ→ソートの合成のまま保つため。
  void _applySuggestion(String name) {
    _searchController.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
    setState(() => _query = name);
  }

  /// 一致 0 件の案内（検索中のみ表示）。
  Widget _buildNoMatch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Center(
        child: Text(
          '「${_query.trim()}」に一致する記録はありません',
          key: const ValueKey<String>('records-search-empty'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// グループ見出しとレコード行のリストを返す。
  ///
  /// WHY bestIds 引数: 自己ベスト集合は build ルートで 1 回だけ計算して
  /// 下ろす（行ごと再計算 avoid）。未確定グループはベスト判定母集団外なので
  /// 空集合を渡す（設計確認書 §1）。
  List<Widget> _buildGroup(
    BuildContext context,
    String header,
    List<PlayRecord> records,
    Set<String> bestIds,
  ) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(header, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final PlayRecord record in records)
        _buildTile(context, record, bestIds.contains(record.id)),
    ];
  }

  /// 選択中の表示順へソートした表示用リストを返す（非破壊）。
  ///
  /// WHY: _reload の playedAt 降順ソート（保存契約）は複製上でしか触らない。
  /// スコア降順は「ソート後の先頭=最高スコア」の視覚的一貫性のため null を
  /// 末尾へ集め、同スコアは playedAt 降順のタイブレークを適用する（§2）。
  List<PlayRecord> _displayOrder(List<PlayRecord> records) {
    if (_sortMode == _sortModeDate) {
      return List<PlayRecord>.of(records);
    }
    final List<PlayRecord> sorted = List<PlayRecord>.of(records)
      ..sort((PlayRecord a, PlayRecord b) {
        final int? scoreA = a.score;
        final int? scoreB = b.score;
        if (scoreA == null && scoreB == null) {
          return b.playedAt.compareTo(a.playedAt);
        }
        if (scoreA == null) {
          return 1;
        }
        if (scoreB == null) {
          return -1;
        }
        final int byScore = scoreB.compareTo(scoreA);
        if (byScore != 0) {
          return byScore;
        }
        return b.playedAt.compareTo(a.playedAt);
      });
    return sorted;
  }

  /// 統計サマリカード（総記録数・演奏曲数・フルコンボ数）。
  ///
  /// WHY 3 値の母集団は設計確認書 §1（総記録数=全件 / 演奏曲数=confirmed
  /// 重複除外 / フルコンボ数=メダル分類一致のみ）。
  Widget _buildStatsCard(BuildContext context, List<PlayRecord> records) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            _buildStatCell(
              context,
              keyName: 'records-stats-total',
              value: '${records.length}',
              label: '総記録数',
            ),
            _buildStatCell(
              context,
              keyName: 'records-stats-songs',
              value: '${countUniqueSongs(records)}',
              label: '演奏曲数',
            ),
            _buildStatCell(
              context,
              keyName: 'records-stats-fullcombo',
              value: '${countFullCombo(records)}',
              label: 'フルコンボ',
            ),
          ],
        ),
      ),
    );
  }

  /// 統計カード 1 マス（数字 + ラベル・ValueKey は Column に付与）。
  Widget _buildStatCell(
    BuildContext context, {
    required String keyName,
    required String value,
    required String label,
  }) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 104,
      child: Column(
        key: ValueKey<String>(keyName),
        children: <Widget>[
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }

  /// 表示順トグル（実施日 / スコア）。キーは SegmentedButton に付与
  /// （selected 状態判定をテストから行うため）。
  ///
  /// WHY 値が String（'sort-date'/'sort-score'）: 設計確認書 §3 のテスト契約が
  /// 値文字列を固定しているため。enum でなく定数 string で持ち、セグメントと
  /// `_sortMode` の対応を 1 箇所で済ませる（KISS）。
  Widget _buildSortSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SegmentedButton<String>(
        key: const ValueKey<String>('records-sort-segment'),
        segments: const <ButtonSegment<String>>[
          ButtonSegment<String>(value: _sortModeDate, label: Text('実施日の新しい順')),
          ButtonSegment<String>(value: _sortModeScore, label: Text('スコアの高い順')),
        ],
        selected: <String>{_sortMode},
        onSelectionChanged: (Set<String> selection) {
          setState(() => _sortMode = selection.first);
        },
      ),
    );
  }

  /// レコード 1 件分の行（サムネイル・曲名＋status チップ・自己ベストバッジ・情報）。
  ///
  /// WHY: アクション（手入力/再OCR/削除）は行に置かず詳細画面へ集約する。
  /// 全件が対象になると「確定レコードに再 OCR ボタン」が不自然になるため
  /// 一覧は閲覧特化とする（設計確認書 §3.1）。
  /// WHY [isBest]（v4 案3）: (曲名, 難易度) グループ最高スコアの行にのみ
  /// バッジを付ける。未確定行は常に false（ベスト判定母集団外）。
  Widget _buildTile(BuildContext context, PlayRecord record, bool isBest) {
    // v2 改訂: 副題に難易度ラベル（FR-10 準拠・「HYPER Lv42」）。null は
    // ラベルなしで従来の「Lv のみ」表示（v5 導入前の旧レコード non-reg）。
    // 難易度カラーリング（01a20a53）: 難易度語のみ difficulty_color.dart の
    // 色で着色する（Text.rich）。残りは DefaultTextStyle（副題の既定色）を
    // 継承させ、文字列そのものは従来と 1 文字も変えない。
    final Color? difficultyTint = difficultyColor(
      record.difficulty,
      brightness: Theme.of(context).brightness,
    );
    return ListTile(
      key: ValueKey<String>('record-row-${record.id}'),
      leading: SizedBox(
        width: 56,
        height: 56,
        // WHY(v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.5): 写真なし
        // 手入力のレコード（空パス）は破れた画像ではなく専用プレースホルダを
        // 表示する。
        child: record.resultImagePath.isEmpty
            ? const Icon(Icons.image_not_supported_outlined)
            : Image.file(
                File(record.resultImagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              ),
      ),
      title: Row(
        children: <Widget>[
          Expanded(child: Text(record.songName ?? '（曲名未入力）')),
          // WHY バッジ位置: ステータスチップの横にまとめる（行の右端は
          // chevron が占有）。グループキーは (曲名, 難易度)。
          if (isBest)
            Container(
              key: const ValueKey<String>('record-best-badge'),
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '自己ベスト',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          _StatusChip(status: record.status),
        ],
      ),
      subtitle: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text:
                  '${record.playedAt.year}/${record.playedAt.month}/'
                  '${record.playedAt.day} / ',
            ),
            // WHY 語のみ着色: 難易度名が「色イメージ」の対象。太字併用は
            // 淡い背景で黄系の判読性を補うため（difficulty_color.dart の WHY）。
            if (record.difficulty != null)
              TextSpan(
                text: '${record.difficulty!.name.toUpperCase()} ',
                style: TextStyle(
                  color: difficultyTint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            TextSpan(
              text:
                  'Lv${record.level ?? '-'} / '
                  '${record.score ?? '-'} 点 / '
                  '${_medalLabelText(record.clearMedal)}',
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openDetail(record),
    );
  }

  /// 詳細画面（FR-11）へ遷移し、戻ったら一覧を再読込する。
  Future<void> _openDetail(PlayRecord record) async {
    await Navigator.of(context).push(
      PlayRecordDetailScreen.route(
        playRecordRepository: widget.playRecordRepository,
        ocrEngine: widget.ocrEngine,
        mainSongRepository: widget.mainSongRepository,
        additionalSongRepository: widget.additionalSongRepository,
        recordId: record.id,
      ),
    );
    if (mounted) {
      await _reload();
    }
  }
}

/// PlayRecord.clearMedal（String? / enum name）→ 表示ラベル。
///
/// WHY: 一覧ではメダルを 1 枠で表示する。未設定なら "—"、設定済みなら
/// 日本語ラベル（フルコンボ / クリア / ... / 失敗）を表示する。
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

/// 未確定/確定を示す小さなチップ。
///
/// WHY: 一覧と詳細で同じ規約（未確定/確定の 2 値表示）を使う。v1 の 2 値のみ
/// を扱うため色分けは最小限（未確定のみ強調色）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

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
