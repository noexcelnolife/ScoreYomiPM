// FR-4 未確定レコードの永続化（lib/data 本体実装・設計書 §2）。
//
// WHY(BlobStore 経由にする理由): 記録も原画像も BlobStore 抽象だけを通して
// 読み書きする。実行環境ごとのファイル API（dart:io の File / ブラウザの
// IndexedDB）をデータ層が直接知らないため、同じコードが Android と Web で動く。
// 将来 SQLite などへ移す場合も実装の差し替えだけで済む（DIP）。
//
// WHY(キー配置を変えない理由): 既存端末は <documents>/records/records.json と
// <documents>/records/images/<name> を持っている。キーの配置を変えると、
// アップデートした瞬間に全記録・全画像が行方不明になる。
//
// 書き込みは BlobStore.write が tmp→rename で行うため、途中でクラッシュしても
// 旧ファイルは保全される。パースに失敗した records.json は .corrupt.<μ秒> に
// 退避してから空リストで復帰する（復旧の余地を残す）。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import '../platform/blob_store.dart';
import 'play_record.dart';
import 'play_record_bulk_writer.dart';

/// プレイ記録の永続化抽象（UI はこの抽象のみに依存する）。
abstract class PlayRecordRepository {
  /// ドラフトと原画像バイト列からレコードを作成して保存する。
  ///
  /// [resultImageBytes] が null なら画像なしで作成し、resultImagePath は空文字に
  /// なる（v4 案2・写真なし手入力。JSON 復元時の既定 `?? ''` と整合）。
  Future<PlayRecord> create(PlayRecordDraft draft, Uint8List? resultImageBytes);

  /// 全レコードを返す（破損時は退避後に空リスト）。
  Future<List<PlayRecord>> listAll();

  /// 指定 id のレコードを返す（なければ null）。
  Future<PlayRecord?> findById(String id);

  /// 既存レコードをドラフト値で上書き更新する（未知の id は StateError）。
  ///
  /// WHY: create と同様に未正規化のドラフトを受け取り正規化を一元化する。
  /// 曲名欄を空にして保存すれば songName は null になる（全上書きセマンティクス）。
  /// id・playedAt・resultImagePath・songId は既存値を維持。
  Future<PlayRecord> update(String id, PlayRecordDraft draft);

  /// レコードと原画像の両方を削除する（未知の id は無音で成功・冪等）。
  Future<void> delete(String id);

  /// 保存済み原画像のバイト列を [imageName] で読み出す。
  ///
  /// WHY(名前で受けるか): `resultImagePath` に入るのは basename だけで、保存先の
  /// ディレクトリ構成はデータ層の内部事情。呼び出し側にキー組み立てをさせない。
  /// [imageName] が空文字なら null（画像なしの記録）。
  Future<Uint8List?> readImage(String imageName);

  /// バルクインポート（バックアップ復元）。
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
    Map<String, Uint8List?>? imageBytesById,
  });
}

/// [BlobStore] に永続化する [PlayRecordRepository] 実装。
///
/// クラス名は履歴的な理由で File のままだが、ファイルシステムには直接触れない。
/// `resultImagePath` には **basename のみ**を格納し、`records/images/` の接頭辞は
/// このクラスが内部で付ける（画面や他の層へ保存先の都合を漏らさない）。
class FilePlayRecordRepository
    implements PlayRecordRepository, PlayRecordBulkWriter {
  // WHY 名前付きで受けるか: 依存が 1 つでも、呼び出し側で何を渡しているかを
  // 明示する（BlobStore は保存先そのものなので取り違えると全データを失う）。
  // WHY public final か: private フィールドを名前付き初期化形式
  // （`this._blobStore`）で受けることは Dart の文法上できないため。
  FilePlayRecordRepository({required this.blobStore});

  /// レコード本体のキー。`<documents>/records/records.json` と一致させる。
  static const String _recordsKey = 'records/records.json';

  /// 原画像の接頭辞。`<documents>/records/images/<name>` と一致させる。
  static const String _imagesPrefix = 'records/images/';

  static const String _corruptSuffix = '.corrupt.';
  static const String _logName = 'play_record_repository';

  /// 保存先。実行環境ごとの実装（ファイル / IndexedDB）を注入する。
  final BlobStore blobStore;

  /// プロセス内 ID 採番シーケンス（同一μ秒でも重複しない接尾辞）。
  int _idSequence = 0;

  @override
  Future<PlayRecord> create(
    PlayRecordDraft draft,
    Uint8List? resultImageBytes,
  ) async {
    final String id = _generateId();
    // WHY(v4 案2): 写真なし手入力では原画像が存在しない。空文字を「画像なし」
    // の既定表現とし、一覧・詳細は空パスをプレースホルダ表示に切り替える。
    final String imageName = resultImageBytes == null
        ? ''
        : await _storeImage(id, resultImageBytes);
    final PlayRecord record = draft.toPlayRecord(
      id: id,
      resultImagePath: imageName,
    );
    final List<PlayRecord> records = await _readAll();
    records.add(record);
    await _writeAll(records);
    return record;
  }

  @override
  Future<List<PlayRecord>> listAll() => _readAll();

  @override
  Future<PlayRecord?> findById(String id) async {
    final List<PlayRecord> records = await _readAll();
    for (final PlayRecord record in records) {
      if (record.id == id) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<PlayRecord> update(String id, PlayRecordDraft draft) async {
    final List<PlayRecord> records = await _readAll();
    final int index = records.indexWhere((PlayRecord item) => item.id == id);
    if (index < 0) {
      throw StateError('未知のレコード id: $id');
    }
    final PlayRecord existing = records[index];
    // WHY: 正規化済みの値で全上書きしつつ、システム管理フィールド
    // （id・記録日時・画像・曲 ID）は既存値を維持する。
    // 曲名欄を空にして保存すれば songName は null になる（全上書き）。
    final PlayRecord merged = draft
        .toPlayRecord(
          id: existing.id,
          resultImagePath: existing.resultImagePath,
          playedAt: existing.playedAt,
        )
        .copyWith(songId: existing.songId);
    records[index] = merged;
    await _writeAll(records);
    return merged;
  }

  @override
  Future<void> delete(String id) async {
    final List<PlayRecord> records = await _readAll();
    final int index = records.indexWhere((PlayRecord item) => item.id == id);
    if (index < 0) {
      // WHY: 未知 id の削除は冪等に成功扱い（UI は存在確認済みで呼ぶため
      // 実害はない。将来の並行操作でも例外にならない）。
      return;
    }
    final String imageName = records[index].resultImagePath;
    if (imageName.isNotEmpty) {
      await blobStore.delete(_imageKey(imageName));
    }
    records.removeAt(index);
    await _writeAll(records);
  }

  @override
  Future<Uint8List?> readImage(String imageName) async {
    if (imageName.isEmpty) {
      return null;
    }
    return blobStore.read(_imageKey(imageName));
  }

  @override
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
    Map<String, Uint8List?>? imageBytesById,
  }) async {
    final List<PlayRecord> existing = replaceAll
        ? <PlayRecord>[]
        : await _readAll();
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
      final _ImportedImage image = await _importImage(
        record,
        imageBytesById?[record.id],
      );
      if (image.missing) {
        missingImages++;
      }
      imported.add(image.record);
    }

    final List<PlayRecord> merged = <PlayRecord>[...existing, ...imported];
    // WHY: 旧 records.json はこの書き込みの rename 成功まで保全される。
    // 旧画像もここでは消さないため、途中で失敗しても旧データはそのまま使える。
    await _writeAll(merged);

    // WHY: 全置換の要件は「孤児画像を残さない」こと。削除は書き込み成功後に
    // 限る（先に消すと、失敗時に旧 records.json が参照する画像だけが失われる）。
    if (replaceAll) {
      await _deleteOrphanImages(merged);
    }

    return BulkImportResult(
      imported: imported.length,
      skipped: skipped,
      missingImages: missingImages,
    );
  }

  /// どのレコードからも参照されていない画像を削除する（全置換の後始末）。
  Future<void> _deleteOrphanImages(List<PlayRecord> records) async {
    final Set<String> referenced = <String>{
      for (final PlayRecord record in records)
        if (record.resultImagePath.isNotEmpty)
          _imageKey(record.resultImagePath),
    };
    for (final String key in await blobStore.listKeys(_imagesPrefix)) {
      if (referenced.contains(key)) {
        continue;
      }
      try {
        await blobStore.delete(key);
      } on Object catch (error, stackTrace) {
        // WHY: 孤児画像の削除失敗は復元結果を左右しない（レコードは書き込み済み）。
        // 残るのは容量だけで、次回の全置換で再び掃除対象になる。
        developer.log(
          '孤児画像を削除できません: $key',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// 取り込み 1 件分の画像を保存し、basename を割り当てたレコードを返す。
  ///
  /// [sourceBytes] は呼び出し側（BackupImportService）が ZIP から読み出した
  /// 元画像。BlobStore にまだ入っていない画像をここで探しに行かない。
  Future<_ImportedImage> _importImage(
    PlayRecord record,
    Uint8List? sourceBytes,
  ) async {
    if (record.resultImagePath.isEmpty) {
      return _ImportedImage(record: record, missing: false);
    }
    // 移行読み込み：旧データは絶対パスを持つので、必ず basename に落としてから扱う。
    final String basename = _fileNameOf(record.resultImagePath);

    if (sourceBytes != null) {
      // WHY 拡張子をバイト列から決めるか: ZIP 内の名前は端末を移す過程で
      // 信用できない（大文字小文字・拡張子なしなど）。実体と食い違う名前を
      // 保存すると、共有や保存の MIME 判定だけがずれる。
      final String imageName = '${record.id}.${_extensionOfBytes(sourceBytes)}';
      await blobStore.write(_imageKey(imageName), sourceBytes);
      return _ImportedImage(
        record: record.copyWith(resultImagePath: imageName),
        missing: false,
      );
    }

    // バイト列が渡されなかった場合でも、既に保存済みなら同じ画像を再利用する
    // （同じ ZIP を 2 回当てたときなど）。
    if (await blobStore.exists(_imageKey(basename))) {
      return _ImportedImage(
        record: record.copyWith(resultImagePath: basename),
        missing: false,
      );
    }

    // WHY: 画像 1 枚の欠落で取り込み全体を失敗させない（裁定 D と同旨）。
    return _ImportedImage(
      record: record.copyWith(resultImagePath: ''),
      missing: true,
    );
  }

  /// 原画像バイト列を保存し、basename（`<id>.<ext>`）を返す。
  Future<String> _storeImage(String id, Uint8List bytes) async {
    final String imageName = '$id.${_extensionOfBytes(bytes)}';
    await blobStore.write(_imageKey(imageName), bytes);
    return imageName;
  }

  /// basename から BlobStore のキーを組み立てる（保存先の知識はここだけ）。
  String _imageKey(String imageName) => '$_imagesPrefix$imageName';

  /// パス風の文字列からファイル名だけを取り出す（区切りは / と \ の両対応）。
  String _fileNameOf(String path) {
    final String normalized = path.replaceAll(r'\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  /// ユニークなレコード ID を生成する（μ秒タイムスタンプ＋採番接尾辞）。
  String _generateId() {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    _idSequence = (_idSequence + 1) % 1000000;
    return 'r$micros-$_idSequence';
  }

  /// バイト列から拡張子を推定する（PNG シグネチャなら png、それ以外 jpg）。
  ///
  /// WHY 拡張子を中身から決めるか: Web では選択された画像の元ファイル名を
  /// 当てにできない（ブラウザが名前を落とすことがある）。
  String _extensionOfBytes(Uint8List bytes) {
    final bool isPng =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    return isPng ? 'png' : 'jpg';
  }

  /// 全レコードを JSON で保存する。
  Future<void> _writeAll(List<PlayRecord> records) async {
    final String content = jsonEncode(<Map<String, dynamic>>[
      for (final PlayRecord record in records) record.toJson(),
    ]);
    // WHY utf8.encode か: codeUnits は UTF-16 の符号単位で、Uint8List へ入れると
    // 8bit に切り捨てられて日本語が復元できなくなる。旧実装の writeAsString は
    // UTF-8 だったため、ここも UTF-8 に揃える。
    await blobStore.write(_recordsKey, utf8.encode(content));
  }

  /// 全レコードを読み出す。パース失敗時は退避して空リストを返す。
  Future<List<PlayRecord>> _readAll() async {
    final Uint8List? bytes = await blobStore.read(_recordsKey);
    if (bytes == null) {
      return <PlayRecord>[];
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error, stackTrace) {
      await _backupCorruptFile(error, stackTrace);
      return <PlayRecord>[];
    }
    if (decoded is! List) {
      // WHY: 配列でないルートも破損扱い（スキーマと異なるファイルは
      // 復旧用に退避してから空で開始する）。
      await _backupCorruptFile(
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

  /// 破損した records.json を退避キーへ移す。
  Future<void> _backupCorruptFile(Object error, StackTrace stackTrace) async {
    final Uint8List? bytes = await blobStore.read(_recordsKey);
    if (bytes == null) {
      return;
    }
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String backupKey = '$_recordsKey$_corruptSuffix$timestamp';
    await blobStore.write(backupKey, bytes);
    await blobStore.delete(_recordsKey);
    developer.log(
      'records.json を破損退避: $backupKey',
      name: _logName,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 取り込み 1 件分の画像処理結果。
class _ImportedImage {
  const _ImportedImage({required this.record, required this.missing});

  /// 画像の割り当てを反映したレコード。
  final PlayRecord record;

  /// 元画像が見つからず、画像なしとして扱ったか。
  final bool missing;
}
