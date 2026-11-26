// バックアップ画面（タスク 01a20c14・UI 層）。
//
// WHY: ZIP（記録 + 結果画像）と CSV（画像なし）の書き出し、および ZIP からの
// 復元を 1 画面にまとめる。生成・復元の実処理は lib/backup/ のサービスが持つので、
// この画面は「保存先の選択」「確認」「結果とエラーの提示」という UI 都合の責務
// だけを担う。
//
// WHY(ゲートウェイ抽象): file_selector / flutter_file_dialog / path_provider は
// プラットフォームチャネルを使うため widget テストから直接呼べない。画面は
// [BackupFileGateway] だけを見て、本番実装 [PlatformBackupFileGateway] は
// 呼び出し側（ホーム画面）から注入する（DIP）。画面ファイルが 400 行を超えた
// ため、入出力の実装は backup_file_gateway.dart に分けてある。
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../backup/backup_export_service.dart';
import '../backup/backup_format_exception.dart';
import '../backup/backup_import_service.dart';
import 'file_export_gateway.dart';

/// ホーム画面の導線から開いたときに、その場で自動実行する操作。
///
/// WHY: ホームの「エクスポート・インポート」内の 3 項目を押した直後にもう一度
/// 同じ項目を選ばせないため、押された項目をそのまま実行する（タスク指示）。
enum BackupAction {
  /// ZIP でバックアップ（画像込み）。
  exportZip,

  /// CSV で出力（画像なし）。
  exportCsv,

  /// ZIP から復元。
  restore,
}

/// バックアップ（エクスポート・インポート）画面。
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.exportService,
    required this.fileGateway,
    this.importService,
    this.existingRecordCount,
    this.initialAction,
    this.now = DateTime.now,
  });

  /// ZIP/CSV の生成に使うサービス（所有権は呼び出し側）。
  final BackupExportService exportService;

  /// 保存先選択・ファイル選択の実装（テストではフェイクを注入）。
  final FileExportGateway fileGateway;

  /// 復元に使うサービス。null は「この端末では復元不可」を意味する。
  ///
  /// WHY(null 許容): ホーム画面が持つ型は PlayRecordRepository で、
  /// PlayRecordBulkWriter を実装している保証が型に無い。実行時キャストで落とさず
  /// 機能だけを隠す（本番の FilePlayRecordRepository は両方実装している）。
  final BackupImportService? importService;

  /// 置換の確認ダイアログに出す「既存の記録件数」。取得できなければ null。
  final Future<int> Function()? existingRecordCount;

  /// ホームの導線から開いたときに自動実行する操作（通常は null）。
  final BackupAction? initialAction;

  /// 保存ファイル名の日時に使う時計（テストで固定するため注入可能）。
  final DateTime Function() now;

  /// ホーム画面からの遷移用。
  static Route<bool> route({
    required BackupExportService exportService,
    required FileExportGateway fileGateway,
    BackupImportService? importService,
    Future<int> Function()? existingRecordCount,
    BackupAction? initialAction,
  }) {
    return MaterialPageRoute<bool>(
      builder: (BuildContext context) => BackupScreen(
        exportService: exportService,
        fileGateway: fileGateway,
        importService: importService,
        existingRecordCount: existingRecordCount,
        initialAction: initialAction,
      ),
    );
  }

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _busy = false;
  String? _busyMessage;
  bool _initialActionStarted = false;

  @override
  void initState() {
    super.initState();
    final BackupAction? action = widget.initialAction;
    if (action != null) {
      // WHY: ホームの項目から開いた直後は、同じ操作をもう一度選ばせない。
      // build 中の Navigator 操作を避けるため最初のフレーム後に実行する。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _initialActionStarted) {
          return;
        }
        _initialActionStarted = true;
        _runAction(action);
      });
    }
  }

  Future<void> _runAction(BackupAction action) async {
    switch (action) {
      case BackupAction.exportZip:
        await _exportZip();
      case BackupAction.exportCsv:
        await _exportCsv();
      case BackupAction.restore:
        await _importZip();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('バックアップ')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          if (_busy) _buildProgress(theme),
          const _SectionHeader('エクスポート'),
          ..._buildExportTiles(),
          const Divider(),
          const _SectionHeader('インポート'),
          // WHY(この分岐は通常到達しない): 本番の FilePlayRecordRepository は
          // PlayRecordRepository と PlayRecordBulkWriter の両方を実装するため、
          // 実際の端末では必ず復元できる。ホームが持つ型では書き込み側の実装が
          // 型で保証されないので、実行時キャストで落とさず「使えない」と表示する
          // 安全弁として残している（リード承認 2026-11-24・条件①）。
          if (widget.importService == null)
            ListTile(
              key: const ValueKey<String>('backup-import-unavailable'),
              leading: const Icon(Icons.info_outline),
              title: const Text('この端末では復元を利用できません'),
              subtitle: const Text('バックアップからの復元は利用できません'),
            )
          else
            ListTile(
              key: const ValueKey<String>('backup-import'),
              leading: const Icon(Icons.restore_outlined),
              title: const Text('バックアップから復元'),
              subtitle: const Text('ZIP を選び、内容を確認してから復元します'),
              enabled: !_busy,
              onTap: _busy ? null : _importZip,
            ),
        ],
      ),
    );
  }

  /// エクスポート側の 2 項目（ZIP / CSV）。
  List<Widget> _buildExportTiles() {
    return <Widget>[
      ListTile(
        key: const ValueKey<String>('backup-export-zip'),
        leading: const Icon(Icons.archive_outlined),
        title: const Text('ZIP でバックアップ（画像込み）'),
        subtitle: const Text('記録と結果画像をまとめて 1 つのファイルに保存します'),
        enabled: !_busy,
        onTap: _busy ? null : _exportZip,
      ),
      ListTile(
        key: const ValueKey<String>('backup-export-csv'),
        leading: const Icon(Icons.table_chart_outlined),
        title: const Text('CSV で出力（画像なし）'),
        subtitle: const Text('表計算ソフトで開ける形式で保存します'),
        enabled: !_busy,
        onTap: _busy ? null : _exportCsv,
      ),
    ];
  }

  Widget _buildProgress(ThemeData theme) {
    return Padding(
      key: const ValueKey<String>('backup-progress'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _busyMessage ?? '処理中です…',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportZip() {
    return _export(
      busyMessage: 'ZIP を作成しています…',
      extension: 'zip',
      mimeType: 'application/zip',
      build: widget.exportService.buildZip,
    );
  }

  Future<void> _exportCsv() {
    return _export(
      busyMessage: 'CSV を作成しています…',
      extension: 'csv',
      mimeType: 'text/csv',
      // WHY: buildCsv() は先頭に U+FEFF（BOM）を含む String を返す。UTF-8 で
      // 書けば BOM は EF BB BF の 3 バイトになるため、ここで BOM を足さない
      //（二重付与の防止）。
      build: () async {
        final String csv = await widget.exportService.buildCsv();
        return Uint8List.fromList(utf8.encode(csv));
      },
    );
  }

  Future<void> _export({
    required String busyMessage,
    required String extension,
    required String mimeType,
    required Future<Uint8List> Function() build,
  }) async {
    setState(() {
      _busy = true;
      _busyMessage = busyMessage;
    });
    try {
      final Uint8List bytes = await build();
      final String fileName =
          'scoreman-${_formatTimestamp(widget.now())}.$extension';
      final String? savedPath = await widget.fileGateway.saveBytes(
        bytes: bytes,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (!mounted) {
        return;
      }
      // WHY: 保存ダイアログのキャンセルは失敗ではないため、エラーも完了も出さない。
      if (savedPath == null) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存しました: $fileName')));
    } catch (error) {
      await _showError('保存に失敗しました', details: '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _importZip() async {
    final BackupImportService? service = widget.importService;
    if (service == null) {
      return;
    }
    final XFile? picked = await widget.fileGateway.pickZip();
    if (picked == null || !mounted) {
      // キャンセルはエラーではないので何も出さない。
      return;
    }

    final Uint8List bytes;
    final BackupImportPreview preview;
    try {
      // WHY: 選択した ZIP は 1 回だけ読み、プレビューと実行の両方に渡す。
      bytes = await picked.readAsBytes();
      preview = await service.preview(bytes);
    } on BackupFormatException catch (error) {
      await _showError(error.message);
      return;
    } catch (error) {
      await _showError('読み込みに失敗しました', details: '$error');
      return;
    }
    if (!mounted) {
      return;
    }

    final ImportMode? mode = await _showPreviewDialog(preview);
    if (mode == null || !mounted) {
      return;
    }
    await _applyImport(service, bytes, mode);
  }

  Future<void> _applyImport(
    BackupImportService service,
    Uint8List bytes,
    ImportMode mode,
  ) async {
    setState(() {
      _busy = true;
      _busyMessage = '復元しています…';
    });
    try {
      final BackupImportOutcome outcome = await service.apply(
        bytes,
        mode: mode,
      );
      if (!mounted) {
        return;
      }
      // WHY(先に解除する): 結果ダイアログを出したままスピナーを回し続けると
      // 画面が永久に「処理中」に見える。復元は完了しているので先に消す。
      _clearBusy();
      await _showResultDialog(outcome, mode);
      if (!mounted) {
        return;
      }
      // WHY(true を返す): ホーム画面が最近の記録を取り直す契機にする。追加で 1 件も
      // 入らなかった（全件スキップの）マージはデータが変わらないので閉じない。
      if (mode == ImportMode.replace || outcome.imported > 0) {
        Navigator.of(context).pop(true);
      }
    } on BackupFormatException catch (error) {
      await _showError(error.message);
    } catch (error) {
      await _showError('復元に失敗しました', details: '$error');
    } finally {
      _clearBusy();
    }
  }

  void _clearBusy() {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _busyMessage = null;
    });
  }

  Future<int?> _loadExistingCount() async {
    final Future<int> Function()? loader = widget.existingRecordCount;
    if (loader == null) {
      return null;
    }
    try {
      return await loader();
    } catch (_) {
      // WHY: 既存件数は確認ダイアログの補助情報なので、取れなくても復元を止めない。
      return null;
    }
  }

  /// 復元内容の確認ダイアログ。選ばれた取り込み方式を返す（キャンセルは null）。
  Future<ImportMode?> _showPreviewDialog(BackupImportPreview preview) async {
    // WHY(開く前に読む): 既存件数はリポジトリへの問い合わせで非同期。ダイアログを
    // 出してから数字が後追いで増えると読みにくいので、確定させてから開く。
    final int? existingCount = await _loadExistingCount();
    if (!mounted) {
      return null;
    }
    return showDialog<ImportMode>(
      context: context,
      builder: (BuildContext context) =>
          _ImportPreviewDialog(preview: preview, existingCount: existingCount),
    );
  }

  Future<void> _showResultDialog(
    BackupImportOutcome outcome,
    ImportMode mode,
  ) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const ValueKey<String>('backup-result-dialog'),
        title: const Text('復元が完了しました'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _InfoLine('取り込み', '${outcome.imported} 件'),
              _InfoLine('スキップ', '${outcome.skipped} 件'),
              _InfoLine('画像復元', '${outcome.imagesRestored} 枚'),
              _InfoLine('画像欠落', '${outcome.missingImages} 件'),
              _InfoLine('テンプレート追加', '${outcome.templatesImported} 件'),
              if (outcome.imported == 0 && mode == ImportMode.merge)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('変更はありません（すべて既存と重複しています）'),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showError(String message, {String? details}) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        return AlertDialog(
          key: const ValueKey<String>('backup-error-dialog'),
          title: const Text('エラー'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(message),
                if (details != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(details, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }
}

/// ファイル名用の日時（`yyyyMMdd-HHmm`）。intl 非依存の手組み。
String _formatTimestamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}${two(value.month)}${two(value.day)}'
      '-${two(value.hour)}${two(value.minute)}';
}

/// 画面表示用の日時（`yyyy/MM/dd HH:mm`）。manifest は UTC なので現地時刻へ。
String _formatDateTime(DateTime value) {
  final DateTime local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 復元内容の確認ダイアログ（ZIP の内容表示と取り込み方式の選択）。
///
/// WHY(独立した StatefulWidget): ラジオの選択だけで再描画したいのはダイアログ
/// 内部だけなので、画面の状態（_busy など）を持ち上げない。1 メソッドに dialog
/// ツリーを全部書くと 100 行を超えるため、意味の単位で分けている。
class _ImportPreviewDialog extends StatefulWidget {
  const _ImportPreviewDialog({required this.preview, this.existingCount});

  final BackupImportPreview preview;

  /// 既存の記録件数。取得できなかった場合は null（行ごと省く）。
  final int? existingCount;

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  /// 既定は「追加」。ZIP が空でも既存を消さない側を初期値にする。
  ImportMode _mode = ImportMode.merge;

  /// ZIP に記録が 1 件も無いとき、置換は全消去になるので選ばせない。
  bool get _replaceBlocked => widget.preview.recordCount == 0;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey<String>('backup-preview-dialog'),
      title: const Text('バックアップから復元'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ..._buildInfoLines(theme),
            const Divider(height: 24),
            const Text('取り込み方式'),
            _buildModeSection(theme),
          ],
        ),
      ),
      actions: _buildActions(context),
    );
  }

  List<Widget> _buildInfoLines(ThemeData theme) {
    final BackupImportPreview preview = widget.preview;
    final int? existingCount = widget.existingCount;
    return <Widget>[
      _InfoLine('記録', '${preview.recordCount} 件'),
      _InfoLine('画像', '${preview.imageCount} 枚'),
      _InfoLine('書き出し日時', _formatDateTime(preview.manifest.exportedAt)),
      _InfoLine('アプリ版', preview.manifest.appVersion),
      _InfoLine('重複（既存と同一）', '${preview.duplicateCount} 件'),
      _InfoLine('メモのテンプレート', '${preview.templateCount} 件'),
      if (existingCount != null) _InfoLine('既存の記録', '$existingCount 件'),
      if (preview.warnings.isNotEmpty) ...<Widget>[
        _InfoLine('警告', '${preview.warnings.length} 件'),
        for (final String warning in preview.warnings.take(3).toList())
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 2),
            child: Text('・$warning', style: theme.textTheme.bodySmall),
          ),
      ],
    ];
  }

  Widget _buildModeSection(ThemeData theme) {
    // WHY: RadioListTile の groupValue / onChanged は v3.32 で非推奨に
    // なったため、選択状態は RadioGroup が持つ。
    return RadioGroup<ImportMode>(
      groupValue: _mode,
      onChanged: (ImportMode? value) {
        setState(() => _mode = value ?? ImportMode.merge);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RadioListTile<ImportMode>(
            key: const ValueKey<String>('backup-import-mode-merge'),
            value: ImportMode.merge,
            contentPadding: EdgeInsets.zero,
            title: const Text('追加（既存を残し、同じ記録はスキップ）'),
          ),
          RadioListTile<ImportMode>(
            key: const ValueKey<String>('backup-import-mode-replace'),
            value: ImportMode.replace,
            contentPadding: EdgeInsets.zero,
            title: const Text('置換（既存をすべて削除して復元）'),
            enabled: !_replaceBlocked,
          ),
          ..._buildNotices(theme),
        ],
      ),
    );
  }

  /// ラジオの下に出す注意書き（0 件で置換できない理由／置換の赤い警告）。
  ///
  /// WHY(理由を出す): 置換だけが無効になっている理由が見えないと
  /// 「壊れている」と読まれる。0 件なら追加は成功して「変更なし」で終わる旨も
  /// ここで伝える。
  List<Widget> _buildNotices(ThemeData theme) {
    return <Widget>[
      if (_replaceBlocked)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'バックアップに記録が 0 件のため置換は選べません。'
            '追加を選ぶと変更なしで終わります。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (_mode == ImportMode.replace)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.existingCount == null
                ? '既存の記録と画像はすべて削除されます。'
                      'メモのテンプレートは削除されません（追加のみ）。元に戻せません。'
                : '既存の記録 ${widget.existingCount} 件と画像はすべて削除されます。'
                      'メモのテンプレートは削除されません（追加のみ）。元に戻せません。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildActions(BuildContext dialogContext) {
    return <Widget>[
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('キャンセル'),
      ),
      TextButton(
        key: const ValueKey<String>('backup-import-confirm'),
        onPressed: _mode == ImportMode.replace && _replaceBlocked
            ? null
            : () => Navigator.of(dialogContext).pop(_mode),
        child: Text(_mode == ImportMode.replace ? '置換して復元' : '復元する'),
      ),
    ];
  }
}

/// ダイアログ内の「項目: 値」1 行。
class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text('$label: $value'),
    );
  }
}

/// セクション見出し。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
