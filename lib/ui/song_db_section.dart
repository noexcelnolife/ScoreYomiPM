// 収録曲辞書の取得・更新・追加 DB 取り込みを行うセクション（spec §10）。
//
// HomeScreen に埋め込む最小構成で、画面遷移なしで完結する。
// WHY: DB 操作の結果通知は失敗・スキップ時のみ SnackBar とし、成功・進捗は
// セクション内のインライン表示に留める。スキップ案内は v2 UX #11（P-5・
// リード裁定 2026-11-23）で追加（旧設計は URL 未設定をサイレントとしていた）。
//
// WHY(案A/B・2026-11-24): 成功・進捗のインライン表示は、折りたたみ
// （ExpansionTile は maintainState=false）が子を破棄すると畳んだ時点で消えて
// いたため、辞書の状態行と最終操作行として常設化した（リード裁定 2026-11-24）。
// 失敗・スキップの SnackBar 通知だけは従来どおり残す。
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../songdb/song_database_service.dart';

/// 収録曲辞書セクションの StatefulWidget。
class SongDbSection extends StatefulWidget {
  const SongDbSection({
    super.key,
    required this.songDatabaseService,
    this.pickAdditionalFile = defaultPickAdditionalFile,
    // WHY(v4 案1): ホームでは折りたたみ（ExpansionTile）のタイトルが見出しを
    // 担うため、埋め込み先でヘッダ重複を避けられるように切替可能にした。
    this.showHeader = true,
    this.seedSongCount,
    this.totalSongCount,
    this.onDictionaryChanged,
  });

  /// 収録曲 DB 操作サービス（抽象にのみ依存する・DIP）。
  final SongDatabaseService songDatabaseService;

  /// 見出し「収録曲辞書」を表示するか。false で埋め込み先が見出しを持つ。
  final bool showHeader;

  /// 追加 DB の JSON ファイルを選択する関数。null でキャンセル。
  ///
  /// WHY: デフォルト引数で注入可能にし、ウィジェットテストでは
  /// 実際のファイル選択ダイアログへ依存しないよう差し替える（DIP）。
  final Future<String?> Function() pickAdditionalFile;

  /// 内蔵シード辞書の曲数を返す（null は「不明」＝「—」表示）。
  final Future<int?> Function()? seedSongCount;

  /// マージ辞書の総曲数を返す（null は「不明」＝「—」表示）。
  final Future<int?> Function()? totalSongCount;

  /// 辞書が実際に差し替わったときに呼ぶ（親の曲数表示を更新してもらう）。
  final VoidCallback? onDictionaryChanged;

  @override
  State<SongDbSection> createState() => _SongDbSectionState();
}

/// file_selector による既定の追加 DB ファイル選択。
Future<String?> defaultPickAdditionalFile() async {
  const XTypeGroup jsonType = XTypeGroup(
    label: 'JSON',
    extensions: <String>['json'],
  );
  final XFile? file = await openFile(
    acceptedTypeGroups: <XTypeGroup>[jsonType],
  );
  return file?.path;
}

class _SongDbSectionState extends State<SongDbSection> {
  late final TextEditingController _urlController;

  /// 更新・取り込み処理の実行中フラグ（進捗インジケーターとボタン無効化に使用）。
  bool _isBusy = false;

  /// 直近に読み込んだ辞書ステータス（読めなかった場合は null）。
  SongDatabaseStatus? _status;
  int? _seedCount;
  int? _totalCount;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _restoreUrl();
    // WHY(案A/B): 折りたたみを開いた瞬間に状態行が揃っている必要がある。
    _refreshStatus();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// 設定済み URL を復元し、URL 設定済みなら起動時の自動更新を行う。
  Future<void> _restoreUrl() async {
    final String url = await widget.songDatabaseService.loadDistributionUrl();
    if (!mounted) return;
    _urlController.text = url;
    // WHY: URL 未設定の起動時はサイレントでシード辞書のままにする（設計確定事項）。
    if (url.isNotEmpty) {
      await _runUpdate(saveUrlFromField: false);
    }
  }

  /// メイン DB の取得・更新を実行する。
  ///
  /// [saveUrlFromField] が true の場合、入力欄の URL を設定へ保存してから
  /// 実行する（ボタン押下時）。false は起動時自動更新用。
  Future<void> _runUpdate({required bool saveUrlFromField}) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
    });
    if (saveUrlFromField) {
      await widget.songDatabaseService.saveDistributionUrl(
        _urlController.text.trim(),
      );
    }
    final SongDbUpdateResult result = await widget.songDatabaseService
        .updateFromConfiguredUrl();
    if (!mounted) return;
    setState(() {
      _isBusy = false;
    });
    _handleUpdateResult(result);
    if (result.status == SongDbUpdateStatus.applied) {
      // WHY: 辞書が入れ替わったので、親のライブ検索キャッシュと曲数表示を作り直す。
      widget.onDictionaryChanged?.call();
    }
    await _refreshStatus();
  }

  /// 更新結果に応じて通知を出し分ける（成功は常設の最終操作行だけに出す）。
  ///
  /// WHY: 成否・時刻・曲数は常設の最終操作行が担うため、インラインの重複表示は
  /// 廃止した（リード裁定 2026-11-24）。失敗・スキップだけは SnackBar で知らせる。
  void _handleUpdateResult(SongDbUpdateResult result) {
    switch (result.status) {
      case SongDbUpdateStatus.applied:
      case SongDbUpdateStatus.upToDate:
        break;
      case SongDbUpdateStatus.skippedNoUrl:
        // WHY: 旧設計は URL 未設定をサイレントとしていたが、フィードバック
        // ゼロで分からない（smoke test レポート P-5）。リード裁定
        // （2026-11-23・v2 UX #11）により 1 行の SnackBar 案内を足す。
        // バンドル内蔵辞書（シード）が使われる挙動自体は変わらない。
        _showNoticeSnackBar('配信 URL が未入力のため更新をスキップしました');
      case SongDbUpdateStatus.failed:
        _showNoticeSnackBar(result.message ?? '辞書の更新に失敗しました。');
    }
  }

  /// 追加 DB の JSON ファイルを選択して取り込む。
  Future<void> _importAdditional() async {
    final String? sourceFilePath = await widget.pickAdditionalFile();
    // WHY: ファイル選択のキャンセルは操作として無視（サイレント）。
    if (sourceFilePath == null) return;
    final SongImportResult result = await widget.songDatabaseService
        .importAdditionalJson(sourceFilePath);
    if (!mounted) return;
    if (result.success) {
      widget.onDictionaryChanged?.call();
    } else {
      _showNoticeSnackBar(result.message ?? '追加辞書の取り込みに失敗しました。');
    }
    await _refreshStatus();
  }

  /// 辞書ステータスと曲数を読み直して表示を最新化する。
  ///
  /// WHY: `loadStatus()` はホーム画面の起動時に呼ぶため、読めなかっただけで
  /// 画面が落ちないよう UI 側でも例外を握って「—」表示に倒す（データ層の
  /// IO 耐性との二重防御・リード指示 2026-11-24）。
  Future<void> _refreshStatus() async {
    SongDatabaseStatus? status;
    try {
      status = await widget.songDatabaseService.loadStatus();
    } catch (_) {
      status = null;
    }
    final int? seedCount = await _invokeCount(widget.seedSongCount);
    final int? totalCount = await _invokeCount(widget.totalSongCount);
    if (!mounted) return;
    setState(() {
      _status = status;
      _seedCount = seedCount;
      _totalCount = totalCount;
    });
  }

  Future<int?> _invokeCount(Future<int?> Function()? provider) async {
    if (provider == null) return null;
    try {
      return await provider();
    } catch (_) {
      return null;
    }
  }

  /// 失敗・スキップ時のみ SnackBar を表示する（成功時の結果は常設行に出す）。
  ///
  /// WHY: スキップ案内は v2 UX #11（P-5・リード裁定 2026-11-23）で追加。
  /// 既存の失敗通知と同じ SnackBar 体裁に揃える。
  void _showNoticeSnackBar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // WHY(v4 案1): 埋め込み先が見出しを持つ場合（ExpansionTile 等）は
            // 重複表示を避けるため非表示にする。
            if (widget.showHeader) ...<Widget>[
              Text('収録曲辞書', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
            ],
            TextField(
              key: const ValueKey('song-db-url-field'),
              controller: _urlController,
              enabled: !_isBusy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '配信URL',
                hintText: 'https://…/main_v1.json（空なら内蔵辞書）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('song-db-update-button'),
                    onPressed: _isBusy
                        ? null
                        : () {
                            _runUpdate(saveUrlFromField: true);
                          },
                    child: const Text('DB取得・更新'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('song-db-import-button'),
                    onPressed: _isBusy
                        ? null
                        : () {
                            _importAdditional();
                          },
                    child: const Text('追加DBを取り込み'),
                  ),
                ),
              ],
            ),
            if (_isBusy) ...<Widget>[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 8),
            ..._buildStatusRows(theme),
          ],
        ),
      ),
    );
  }

  /// 常設ステータス行（内蔵シード・配信DB・追加DB・合計・最終操作）。
  ///
  /// WHY: 1 行 1 Text にすると find.text で行全体を厳密に固定でき、表示の退行を
  /// 検出しやすい（リード承認 2026-11-24）。
  List<Widget> _buildStatusRows(ThemeData theme) {
    final TextStyle? style = theme.textTheme.bodySmall;
    final SongDbLastOperation? lastOperation = _status?.lastOperation;
    return <Widget>[
      Text(
        _describeSeedRow(_seedCount),
        key: const ValueKey('song-db-status-seed'),
        style: style,
      ),
      const SizedBox(height: 2),
      Text(
        _describeSourceRow(
          '配信DB',
          _status?.main,
          actionLabel: '更新',
          showDbVersion: true,
        ),
        key: const ValueKey('song-db-status-main'),
        style: style,
      ),
      const SizedBox(height: 2),
      Text(
        _describeSourceRow('追加DB', _status?.additional, actionLabel: '取込'),
        key: const ValueKey('song-db-status-additional'),
        style: style,
      ),
      const SizedBox(height: 4),
      const Divider(height: 8),
      Text(
        _describeTotalRow(_totalCount),
        key: const ValueKey('song-db-status-total'),
        style: style,
      ),
      if (lastOperation != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _describeLastOperation(lastOperation),
          key: const ValueKey('song-db-last-operation'),
          style: style,
        ),
      ],
    ];
  }
}

/// マージ辞書の総曲数を 1 行で示す（ExpansionTile の subtitle 用）。
///
/// WHY(案A): 折りたたんだ状態でも辞書の規模（サジェスト対象の曲数）が分かる
/// ようにするため、タイトル行に常時出す。ExpansionTile はホーム画面側に
/// あるので、そのままテストできる小さなウィジェットとして切り出した。
class SongDbTotalCountSubtitle extends StatefulWidget {
  const SongDbTotalCountSubtitle({
    super.key,
    required this.loadTotalCount,
    this.refreshToken = 0,
  });

  /// マージ辞書の総曲数を返す（null は「不明」＝「—」表示）。
  final Future<int?> Function() loadTotalCount;

  /// これが変わると再取得する（辞書更新後に親が加算して渡す）。
  final int refreshToken;

  @override
  State<SongDbTotalCountSubtitle> createState() =>
      _SongDbTotalCountSubtitleState();
}

class _SongDbTotalCountSubtitleState extends State<SongDbTotalCountSubtitle> {
  int? _totalCount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SongDbTotalCountSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // WHY: 辞書を作り直したのは refreshToken が変わったときだけなので、
    // 再ビルドのたびに読み直さない。
    if (widget.refreshToken != oldWidget.refreshToken) {
      _load();
    }
  }

  Future<void> _load() async {
    int? totalCount;
    try {
      totalCount = await widget.loadTotalCount();
    } catch (_) {
      // WHY: 表示専用の件数なので、読めなくても画面を落とさず「—」に倒す。
      totalCount = null;
    }
    if (!mounted) return;
    setState(() {
      _totalCount = totalCount;
    });
  }

  @override
  Widget build(BuildContext context) {
    final int? totalCount = _totalCount;
    final String label = totalCount != null && totalCount > 0
        ? '${_groupDigits(totalCount)}曲'
        : '—';
    return Text(
      label,
      key: const ValueKey('song-db-total-subtitle'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// 内蔵シード辞書の行（例: `内蔵シード 33曲`）。
String _describeSeedRow(int? seedCount) {
  if (seedCount == null) return '内蔵シード —';
  return '内蔵シード ${_groupDigits(seedCount)}曲';
}

/// 辞書 1 種の行（例: `配信DB 3,180曲（dbVersion 12・11/20 14:32 更新）`）。
///
/// 「未取得」（ファイルが無い）と「読込失敗」（あるが読めない）は区別する。
String _describeSourceRow(
  String label,
  SongDbSourceStatus? status, {
  required String actionLabel,
  bool showDbVersion = false,
}) {
  if (status == null) return '$label —';
  if (!status.exists) return '$label 未取得';
  final int? songCount = status.songCount;
  if (songCount == null) return '$label 読込失敗';
  final int? dbVersion = status.dbVersion;
  final DateTime? updatedAt = status.updatedAt;
  final List<String> details = <String>[
    if (showDbVersion && dbVersion != null) 'dbVersion $dbVersion',
    if (updatedAt != null) '${_formatMoment(updatedAt)} $actionLabel',
  ];
  final String base = '$label ${_groupDigits(songCount)}曲';
  return details.isEmpty ? base : '$base（${details.join('・')}）';
}

/// 合計行（検索母数であることを明示する）。
String _describeTotalRow(int? totalCount) {
  if (totalCount == null || totalCount <= 0) return '合計 —（サジェスト対象）';
  return '合計 ${_groupDigits(totalCount)}曲（サジェスト対象）';
}

/// 最終操作の行（案B）。
///
/// 更新は「最終更新」、追加 DB 取り込みは「最終取込」で表す。スキップは実行時刻を
/// 持たないため「—」にし、失敗は理由をそのまま出す。
String _describeLastOperation(SongDbLastOperation operation) {
  final String label = operation.kind == SongDbOperationKind.update
      ? '最終更新'
      : '最終取込';
  switch (operation.outcome) {
    case SongDbOperationOutcome.success:
      final String detail = _describeSuccessDetail(operation);
      final String moment = _formatMoment(operation.at);
      if (detail.isEmpty) return '$label: $moment 成功';
      return '$label: $moment 成功（$detail）';
    case SongDbOperationOutcome.failure:
      return '$label: ${_formatMoment(operation.at)} 失敗'
          '（${operation.message ?? '理由不明'}）';
    case SongDbOperationOutcome.skipped:
      // WHY: スキップの記録は現状 URL 未設定のみ（P-5）なので既定文言もそれに合わせる。
      return '$label: — スキップ（${operation.message ?? '配信 URL が未設定です'}）';
  }
}

/// 成功時の内訳（括弧内）。内訳が無ければ空文字。
String _describeSuccessDetail(SongDbLastOperation operation) {
  final int? dbVersion = operation.dbVersion;
  final int? songCount = operation.songCount;
  final String? sourceFileName = operation.sourceFileName;
  final List<String> parts = <String>[
    if (dbVersion != null) 'dbVersion $dbVersion',
    if (songCount != null)
      sourceFileName == null
          ? '${_groupDigits(songCount)}曲'
          : '「$sourceFileName」から ${_groupDigits(songCount)}曲'
    else if (sourceFileName != null)
      '「$sourceFileName」',
  ];
  return parts.join('・');
}

/// 時刻を端末ローカルで `M/d HH:mm` に整形する。
String _formatMoment(DateTime at) {
  final DateTime local = at.toLocal();
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day} $hour:$minute';
}

/// 曲数を 3 桁区切りにする（例: 3201 → `3,201`）。
String _groupDigits(int value) {
  final String digits = value.toString();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
