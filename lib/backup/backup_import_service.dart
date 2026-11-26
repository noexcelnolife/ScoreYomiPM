// バックアップのインポート（タスク 01a20bfe・データ層）。
//
// WHY: 復元は「プレビュー → 実行」の 2 段階にして、実行前に件数と重複を提示
// できるようにする。プレビューは 1 バイトも書き込まない。また、ZIP を最後まで
// 検証してから書き込みを始めることで、壊れたファイルでの部分復元を防ぐ。
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../data/memo_template_repository.dart';
import '../data/play_record.dart';
import '../data/play_record_bulk_writer.dart';
import 'backup_archive_codec.dart';
import 'backup_manifest.dart';

/// 取り込み方式。
enum ImportMode {
  /// 既存を残し、同じ id はスキップする（冪等）。
  merge,

  /// 既存をすべて削除してから復元する。
  replace,
}

/// 取り込み前の確認情報。この取得では一切書き込まない。
class BackupImportPreview {
  const BackupImportPreview({
    required this.manifest,
    required this.recordCount,
    required this.imageCount,
    required this.duplicateCount,
    required this.warnings,
    this.templateCount = 0,
  });

  final BackupManifest manifest;

  /// ZIP 内のレコード数。
  final int recordCount;

  /// ZIP 内の画像数。
  final int imageCount;

  /// 既存データ（または ZIP 内の先行レコード）と id が重複する件数。
  final int duplicateCount;

  /// 復元を止めずに継続した事象（画像欠落など）。
  final List<String> warnings;

  /// ZIP 内のメモテンプレート数。
  ///
  /// WHY(既定値 0): 旧 ZIP にはテンプレートが入っていない。呼び出し側が
  /// 件数を出さない実装でも壊れないよう省略可能にしてある。
  final int templateCount;
}

/// 取り込みの実績。
class BackupImportOutcome {
  const BackupImportOutcome({
    required this.imported,
    required this.skipped,
    required this.imagesRestored,
    required this.missingImages,
    this.templatesImported = 0,
  });

  final int imported;

  /// 重複などで書き込まなかった件数。
  final int skipped;

  /// 復元できた画像枚数。
  final int imagesRestored;

  /// 画像が見つからず、画像なしとして復元した件数。
  final int missingImages;

  /// 新しく追加したメモテンプレート数（既存と id が同じものは数えない）。
  final int templatesImported;
}

/// ZIP バイト列を既存データへ取り込む。
class BackupImportService {
  BackupImportService({
    required this._listRecords,
    required this._writer,
    this._memoTemplateRepository,
    this._codec = const BackupArchiveCodec(),
    Future<Directory> Function()? temporaryDirectoryFactory,
  }) : _temporaryDirectoryFactory =
           temporaryDirectoryFactory ?? _createDefaultTemporaryDirectory;

  final Future<List<PlayRecord>> Function() _listRecords;
  final PlayRecordBulkWriter _writer;
  final BackupArchiveCodec _codec;
  final Future<Directory> Function() _temporaryDirectoryFactory;

  /// メモテンプレートの復元先。null なら復元しない（旧 ZIP・機能未使用時）。
  final MemoTemplateRepository? _memoTemplateRepository;

  static Future<Directory> _createDefaultTemporaryDirectory() =>
      Directory.systemTemp.createTemp('scoreyomipm_import_');

  /// 取り込み内容を調べる（書き込みは行わない）。
  Future<BackupImportPreview> preview(Uint8List zipBytes) async {
    final BackupArchive archive = _codec.decode(zipBytes);
    final Set<String> existingIds = (await _listRecords())
        .map((PlayRecord record) => record.id)
        .toSet();

    final Set<String> seenInArchive = <String>{};
    int duplicates = 0;
    for (final PlayRecord record in archive.records) {
      if (existingIds.contains(record.id) || !seenInArchive.add(record.id)) {
        duplicates++;
      }
    }

    return BackupImportPreview(
      manifest: archive.manifest,
      recordCount: archive.records.length,
      imageCount: archive.imagesById.length,
      duplicateCount: duplicates,
      warnings: archive.warnings,
      templateCount: archive.templates.length,
    );
  }

  /// 実際に取り込む。
  Future<BackupImportOutcome> apply(
    Uint8List zipBytes, {
    required ImportMode mode,
  }) async {
    // WHY: ここで例外が出れば 1 件も書き込んでいない（全置換で既存を消す前に
    // 検証が終わる）。壊れた ZIP で既存データを失わないための順序。
    final BackupArchive archive = _codec.decode(zipBytes);
    final List<PlayRecord> targets = await _selectTargets(
      archive.records,
      mode,
    );

    final Directory tempDir = await _temporaryDirectoryFactory();
    try {
      final _StagedImages staged = await _stageImages(
        targets,
        archive.imagesById,
        tempDir,
      );
      final BulkImportResult result = await _writer.importAll(
        staged.records,
        replaceAll: mode == ImportMode.replace,
      );
      final int templatesImported = await _restoreTemplates(archive);

      return BackupImportOutcome(
        imported: result.imported,
        // WHY: サービス側で除外した重複と、書き込み側で検出した重複の両方を
        // 数える（どちらの経路で落ちた件数も利用者には同じ「スキップ」）。
        skipped: archive.records.length - targets.length + result.skipped,
        imagesRestored: staged.restored,
        missingImages: archive.warnings.length + result.missingImages,
        templatesImported: templatesImported,
      );
    } finally {
      // WHY: 一時ファイルは復元後に不要。放置すると端末の空き容量を圧迫する。
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// ZIP 内のメモテンプレートを取り込み、新しく増えた件数を返す。
  Future<int> _restoreTemplates(BackupArchive archive) async {
    final MemoTemplateRepository? repository = _memoTemplateRepository;
    if (repository == null || archive.templates.isEmpty) return 0;
    try {
      return await repository.mergeAll(archive.templates);
    } on Object catch (error, stackTrace) {
      // WHY(ここで握りつぶすか): レコードの復元は既に成功している。テンプレート
      // だけの失敗で「復元に失敗した」と見せると、利用者は記録が消えたと誤解する。
      developer.log(
        'メモテンプレートの復元に失敗しました',
        name: 'BackupImportService',
        error: error,
        stackTrace: stackTrace,
      );
      return 0;
    }
  }

  Future<List<PlayRecord>> _selectTargets(
    List<PlayRecord> records,
    ImportMode mode,
  ) async {
    final List<PlayRecord> unique = _dedupeById(records);
    if (mode == ImportMode.replace) {
      return unique;
    }
    final Set<String> existingIds = (await _listRecords())
        .map((PlayRecord record) => record.id)
        .toSet();
    return unique
        .where((PlayRecord record) => !existingIds.contains(record.id))
        .toList(growable: false);
  }

  /// ZIP 内で同じ id が複数回現れた場合は最初の 1 件だけを残す。
  List<PlayRecord> _dedupeById(List<PlayRecord> records) {
    final Set<String> seen = <String>{};
    final List<PlayRecord> unique = <PlayRecord>[];
    for (final PlayRecord record in records) {
      if (seen.add(record.id)) {
        unique.add(record);
      }
    }
    return unique;
  }

  Future<_StagedImages> _stageImages(
    List<PlayRecord> records,
    Map<String, Uint8List> imagesById,
    Directory tempDir,
  ) async {
    final List<PlayRecord> staged = <PlayRecord>[];
    int restored = 0;

    for (final PlayRecord record in records) {
      final String relativePath = record.resultImagePath;
      if (relativePath.isEmpty) {
        staged.add(record);
        continue;
      }
      final String fileName = _fileNameOf(relativePath);
      final Uint8List? bytes = imagesById[fileName];
      if (bytes == null) {
        staged.add(record.copyWith(resultImagePath: ''));
        continue;
      }
      // WHY: 画像は一時ディレクトリへ実体化してから一括書き込みへ渡す。こうすると
      // 書き込み側は「実ファイルのコピー」1 経路だけを扱えばよく、ZIP の知識を
      // データ保存層へ漏らさずに済む。
      final File target = File(
        '${tempDir.path}${Platform.pathSeparator}${record.id}${_extensionOf(fileName)}',
      );
      await target.writeAsBytes(bytes, flush: true);
      staged.add(record.copyWith(resultImagePath: target.path));
      restored++;
    }

    return _StagedImages(records: staged, restored: restored);
  }

  String _fileNameOf(String path) {
    final String normalized = path.replaceAll(r'\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  String _extensionOf(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    return dot <= 0 ? '.jpg' : fileName.substring(dot);
  }
}

/// 一時ディレクトリへ実体化した後の状態。
class _StagedImages {
  const _StagedImages({required this.records, required this.restored});

  final List<PlayRecord> records;
  final int restored;
}
