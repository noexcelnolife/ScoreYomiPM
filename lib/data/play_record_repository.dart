// FR-4 未確定レコードの永続化（lib/data 本体実装・設計書 §2）。
//
// WHY: 新依存ゼロの JSON ファイル方式。records.json は tmp→rename の
// アトミック書き込みで書き込み中クラッシュによる全損を防ぎ、パース失敗時は
// records.json.corrupt.<タイムスタンプ> に退避してから空リストで復帰する
// （ユーザーデータの復旧可能性を保持・原画像は常に残置）。
// 将来の SQLite 化はこの抽象の実装差し替えのみで対応できる（DIP）。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'play_record.dart';
import 'play_record_bulk_writer.dart';

/// プレイ記録の永続化抽象（UI はこの抽象のみに依存する）。
abstract class PlayRecordRepository {
  /// ドラフトと原画像からレコードを作成して保存する。
  ///
  /// 原画像はバイト等価コピーで records/images/ 配下に保存される。
  /// 元画像が読み出せない場合は FileSystemException を投げる（レコード未作成）。
  /// [resultImage] が null の場合は画像なしで作成し、resultImagePath は空文字
  /// になる（v4 案2・写真なし手入力。JSON 復元時の既定 `?? ''` と整合）。
  Future<PlayRecord> create(PlayRecordDraft draft, File? resultImage);

  /// 全レコードを返す（破損時は退避後に空リスト）。
  Future<List<PlayRecord>> listAll();

  /// 指定 id のレコードを返す（なければ null）。
  Future<PlayRecord?> findById(String id);

  /// 既存レコードをドラフト値で上書き更新する（未知の id は StateError）。
  ///
  /// WHY: create と同様に未正規化のドラフトを受け取り正規化を一元化する。
  /// 曲名欄を空にして保存すれば songName は null になる（全上書きセマンティクス）。
  /// id・playedAt・resultImagePath・songId・clearMedal は既存値を維持。
  Future<PlayRecord> update(String id, PlayRecordDraft draft);

  /// レコードと原画像ファイルの両方を削除する（未知の id は無音で成功・冪等）。
  Future<void> delete(String id);
}

/// ファイルベースの [PlayRecordRepository] 実装。
class FilePlayRecordRepository
    implements PlayRecordRepository, PlayRecordBulkWriter {
  FilePlayRecordRepository({required this._documentsDirectoryResolver});

  static const String _recordsDirName = 'records';
  static const String _recordsFileName = 'records.json';
  static const String _imagesDirName = 'images';
  static const String _tmpSuffix = '.tmp';
  static const String _corruptSuffix = '.corrupt.';
  static const String _logName = 'play_record_repository';

  /// WHY: documents ディレクトリの解決は実行環境依存のため関数として注入し、
  /// テストでは一時ディレクトリへ差し替え可能にする（DIP）。
  final Future<Directory> Function() _documentsDirectoryResolver;

  /// プロセス内 ID 採番シーケンス（同一μ秒でも重複しない接尾辞）。
  int _idSequence = 0;

  @override
  Future<PlayRecord> create(PlayRecordDraft draft, File? resultImage) async {
    final Directory recordsDir = await _recordsDirectory();
    final String id = _generateId();
    // WHY(v4 案2): 写真なし手入力では原画像が存在しない。空文字を「画像なし」
    // の既定表現とし、一覧・詳細は空パスをプレースホルダ表示に切り替える。
    final String resultImagePath = resultImage == null
        ? ''
        : (await _copyImage(recordsDir, id, resultImage)).path;
    final PlayRecord record = draft.toPlayRecord(
      id: id,
      resultImagePath: resultImagePath,
    );
    final List<PlayRecord> records = await _readAll(recordsDir);
    records.add(record);
    await _writeAll(recordsDir, records);
    return record;
  }

  @override
  Future<List<PlayRecord>> listAll() async =>
      _readAll(await _recordsDirectory());

  @override
  Future<PlayRecord?> findById(String id) async {
    final List<PlayRecord> records = await _readAll(await _recordsDirectory());
    for (final PlayRecord record in records) {
      if (record.id == id) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<PlayRecord> update(String id, PlayRecordDraft draft) async {
    final Directory recordsDir = await _recordsDirectory();
    final List<PlayRecord> records = await _readAll(recordsDir);
    final int index = records.indexWhere((PlayRecord item) => item.id == id);
    if (index < 0) {
      throw StateError('未知のレコード id: $id');
    }
    final PlayRecord existing = records[index];
    // WHY: 正規化済みの値で全上書きしつつ、システム管理フィールド
    // （id・記録日時・画像パス・曲 ID）は既存値を維持する。
    // メダルはドラフト経由で値を運ぶ（2026-11-23 メダル編集可に伴い上書き廃止）。
    // 曲名欄を空にして保存すれば songName は null になる（全上書き）。
    final PlayRecord merged = draft
        .toPlayRecord(
          id: existing.id,
          resultImagePath: existing.resultImagePath,
          playedAt: existing.playedAt,
        )
        .copyWith(songId: existing.songId);
    records[index] = merged;
    await _writeAll(recordsDir, records);
    return merged;
  }

  @override
  Future<void> delete(String id) async {
    final Directory recordsDir = await _recordsDirectory();
    final List<PlayRecord> records = await _readAll(recordsDir);
    final int index = records.indexWhere((PlayRecord item) => item.id == id);
    if (index < 0) {
      // WHY: 未知 id の削除は冪等に成功扱い（UI は存在確認済みで呼ぶため
      // 実害はない。将来の並行操作でも例外にならない）。
      return;
    }
    final File imageFile = File(records[index].resultImagePath);
    if (await imageFile.exists()) {
      await imageFile.delete();
    }
    records.removeAt(index);
    await _writeAll(recordsDir, records);
  }

  @override
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
  }) async {
    final Directory recordsDir = await _recordsDirectory();
    final List<PlayRecord> existing = replaceAll
        ? <PlayRecord>[]
        : await _readAll(recordsDir);
    final Set<String> knownIds = <String>{
      for (final PlayRecord record in existing) record.id,
    };

    final List<PlayRecord> imported = <PlayRecord>[];
    int skipped = 0;
    int missingImages = 0;
    for (final PlayRecord record in records) {
      // WHY: マージは既存 id を残してスキップする（同じバックアップを 2 回
      // 当てても件数が増えない＝冪等）。ZIP 内の重複 id も同じ規則で落とす。
      if (!knownIds.add(record.id)) {
        skipped++;
        continue;
      }
      final _ImportedImage image = await _importImage(recordsDir, record);
      if (image.missing) {
        missingImages++;
      }
      imported.add(image.record);
    }

    final List<PlayRecord> merged = <PlayRecord>[...existing, ...imported];
    // WHY: 旧 records.json はこの書き込みの rename 成功まで保全される（tmp→
    // rename）。旧画像もここでは消さないため、途中で失敗しても旧データは
    // そのまま使える。
    await _writeAll(recordsDir, merged);

    // WHY: 全置換の要件は「孤児画像を残さない」こと。削除は書き込み成功後に
    // 限る（先に消すと、失敗時に旧 records.json が参照する画像だけが失われる）。
    if (replaceAll) {
      await _deleteOrphanImages(recordsDir, merged);
    }

    return BulkImportResult(
      imported: imported.length,
      skipped: skipped,
      missingImages: missingImages,
    );
  }

  /// どのレコードからも参照されていない画像を削除する（全置換の後始末）。
  Future<void> _deleteOrphanImages(
    Directory recordsDir,
    List<PlayRecord> records,
  ) async {
    final Directory imagesDir = Directory('${recordsDir.path}/$_imagesDirName');
    if (!await imagesDir.exists()) {
      return;
    }
    final Set<String> referenced = <String>{
      for (final PlayRecord record in records)
        if (record.resultImagePath.isNotEmpty)
          _fileNameOf(record.resultImagePath),
    };

    await for (final FileSystemEntity entity in imagesDir.list()) {
      if (entity is! File || referenced.contains(_fileNameOf(entity.path))) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException catch (error, stackTrace) {
        // WHY: 孤児画像の削除失敗は復元結果を左右しない（レコードは書き込み済み）。
        // 残るのは容量だけであり、次回の全置換で再び掃除対象になる。
        developer.log(
          '孤児画像を削除できません: ${entity.path}',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// パス文字列からファイル名だけを取り出す（区切りは / と \ の両対応）。
  String _fileNameOf(String path) {
    final String normalized = path.replaceAll(r'\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  /// 取り込み 1 件分の画像を複製し、保存先の絶対パスへ差し替える。
  Future<_ImportedImage> _importImage(
    Directory recordsDir,
    PlayRecord record,
  ) async {
    if (record.resultImagePath.isEmpty) {
      return _ImportedImage(record: record, missing: false);
    }
    final File source = File(record.resultImagePath);
    if (!await source.exists()) {
      // WHY: 画像 1 枚の欠落で取り込み全体を失敗させない（裁定 D と同旨）。
      return _ImportedImage(
        record: record.copyWith(resultImagePath: ''),
        missing: true,
      );
    }
    final File copied = await _copyImage(recordsDir, record.id, source);
    return _ImportedImage(
      record: record.copyWith(resultImagePath: copied.path),
      missing: false,
    );
  }

  /// ユニークなレコード ID を生成する（μ秒タイムスタンプ＋採番接尾辞）。
  String _generateId() {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    _idSequence = (_idSequence + 1) % 1000000;
    return 'r$micros-$_idSequence';
  }

  /// 原画像をバイト等価コピーで保存先へ置く（再エンコードなし・NFR-5）。
  Future<File> _copyImage(
    Directory recordsDir,
    String id,
    File resultImage,
  ) async {
    final Directory imagesDir = Directory('${recordsDir.path}/$_imagesDirName');
    await imagesDir.create(recursive: true);
    final String extension = resultImage.path.toLowerCase().endsWith('.png')
        ? 'png'
        : 'jpg';
    final File destination = File('${imagesDir.path}/$id.$extension');
    await resultImage.copy(destination.path);
    return destination;
  }

  Future<Directory> _recordsDirectory() async {
    final Directory documents = await _documentsDirectoryResolver();
    return Directory('${documents.path}/$_recordsDirName');
  }

  /// 全レコードを読み出す。パース失敗時は退避して空リストを返す。
  Future<List<PlayRecord>> _readAll(Directory recordsDir) async {
    final File recordsFile = File('${recordsDir.path}/$_recordsFileName');
    if (!await recordsFile.exists()) {
      return <PlayRecord>[];
    }
    final String content = await recordsFile.readAsString();
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (error, stackTrace) {
      await _backupCorruptFile(recordsFile, error, stackTrace);
      return <PlayRecord>[];
    }
    if (decoded is! List) {
      // WHY: 配列でないルートも破損扱い（スキーマと異なるファイルは
      // 復旧用に退避してから空で開始する）。
      await _backupCorruptFile(
        recordsFile,
        const FormatException('records.json は配列ではありません'),
        StackTrace.current,
      );
      return <PlayRecord>[];
    }
    final List<PlayRecord> records = <PlayRecord>[];
    for (final dynamic entry in decoded) {
      try {
        if (entry is Map<String, dynamic>) {
          records.add(PlayRecord.fromJson(entry));
        }
      } catch (error, stackTrace) {
        // WHY: 1 件単位の不正要素はスキップのみで退避はしない
        // （ファイル全体は正当な JSON なため・シード辞書と同方針）。
        developer.log(
          'records.json の不正要素をスキップ: $error',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return records;
  }

  /// 破損した records.json を復旧用にリネーム退避する。
  Future<void> _backupCorruptFile(
    File recordsFile,
    Object error,
    StackTrace stackTrace,
  ) async {
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File backupFile = File(
      '${recordsFile.path}$_corruptSuffix$timestamp',
    );
    try {
      await recordsFile.rename(backupFile.path);
      developer.log(
        'records.json を破損退避: ${backupFile.path}',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
    } on FileSystemException catch (renameError, renameStackTrace) {
      // WHY: 退避できなくてもアプリは継続（空リスト扱い・原画像は残る）。
      // 本ファイルを上書き破棄しないことが最優先。
      developer.log(
        'records.json の破損退避に失敗: $renameError',
        name: _logName,
        stackTrace: renameStackTrace,
      );
    }
  }

  /// 全レコードを tmp→rename でアトミックに保存する。
  Future<void> _writeAll(Directory recordsDir, List<PlayRecord> records) async {
    await recordsDir.create(recursive: true);
    final File recordsFile = File('${recordsDir.path}/$_recordsFileName');
    final File tmpFile = File('${recordsFile.path}$_tmpSuffix');
    await tmpFile.writeAsString(
      jsonEncode(<Map<String, dynamic>>[
        for (final PlayRecord record in records) record.toJson(),
      ]),
      flush: true,
    );
    // WHY: rename は既存ファイルを置換するため、書き込み中クラッシュ時も
    // 本ファイルは旧状態のまま維持される（全損防止・設計書 §2）。
    await tmpFile.rename(recordsFile.path);
  }
}

/// 取り込み 1 件分の画像処理結果。
class _ImportedImage {
  const _ImportedImage({required this.record, required this.missing});

  /// 保存先パスを反映済みのレコード。
  final PlayRecord record;

  /// 元画像が見つからず画像なしとして扱ったか。
  final bool missing;
}
