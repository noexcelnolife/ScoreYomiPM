// バックアップ ZIP のエンコード/デコード（タスク 01a20bfe・データ層）。
//
// WHY: この層は「バイト列 → データ」「データ → バイト列」だけを担当し、ファイル
// 入出力を持たない。純粋関数にしておくと、ホストテストで往復を完結に検証でき、
// 復元（書き込み）の失敗と形式不正を切り分けられる。
//
// ZIP レイアウト:
//   manifest.json           … 形式・スキーマ版・件数の宣言
//   records.json            … PlayRecord の JSON 配列（resultImagePath は相対パス）
//   images/<id>.<ext>       … リザルト画像（JPEG/PNG は再圧縮せず格納）
//   memo_templates.json     … メモのテンプレート配列（任意・旧 ZIP には無い）
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../data/memo_template.dart';
import '../data/play_record.dart';
import 'backup_format_exception.dart';
import 'backup_manifest.dart';

export 'backup_format_exception.dart';

/// 復号結果。`records` の `resultImagePath` は ZIP 内の相対パスのまま返す。
///
/// WHY: 絶対パスは復元先端末でしか通用しない。コーデックは純粋関数なので
/// ファイルを書き出せず、実パスへの解決は取り込みサービス側の責務にする。
class BackupArchive {
  const BackupArchive({
    required this.manifest,
    required this.records,
    required this.imagesById,
    required this.warnings,
    this.templates = const <MemoTemplate>[],
  });

  final BackupManifest manifest;

  /// `resultImagePath` は `images/<id>.<ext>`（画像なしは空文字）。
  final List<PlayRecord> records;

  /// キーは画像ファイル名（例 `r123-1.jpg`）。拡張子はキーに含まれる。
  final Map<String, Uint8List> imagesById;

  /// 復元を止めずに継続した事象（画像欠落など）の説明。
  final List<String> warnings;

  /// 同梱されていたメモのテンプレート（無ければ空）。
  ///
  /// WHY 空を既定にするか: テンプレート同梱前の ZIP でも同じ経路で復元したい
  /// （「テンプレートが無い」は異常ではなく、単に同梱されていないだけ）。
  final List<MemoTemplate> templates;
}

/// バックアップ ZIP のエンコーダ兼デコーダ。
class BackupArchiveCodec {
  const BackupArchiveCodec();

  static const String manifestFileName = 'manifest.json';
  static const String recordsFileName = 'records.json';
  static const String imagesDirectoryName = 'images';
  static const String memoTemplatesFileName = 'memo_templates.json';

  /// レコードと画像を ZIP バイト列へ変換する。
  ///
  /// [imagesById] のキーは `<レコード id>.<拡張子>`。キーの stem をレコード id
  /// とみなし、`resultImagePath` を `images/<キー>` に置き換える。
  Uint8List encode({
    required BackupManifest manifest,
    required List<PlayRecord> records,
    required Map<String, Uint8List> imagesById,
    List<MemoTemplate> templates = const <MemoTemplate>[],
  }) {
    final Map<String, String> relativePathByRecordId = _relativePaths(
      imagesById.keys,
    );
    final Archive archive = Archive();

    _addJsonEntry(archive, manifestFileName, manifest.toJson());
    _addJsonEntry(archive, recordsFileName, <Map<String, dynamic>>[
      for (final PlayRecord record in records)
        _recordJson(record, relativePathByRecordId),
    ]);
    // WHY 空でも書くか: 「テンプレート 0 件」を明示でき、ZIP の中身が
    // 件数によらず一定になる（利用者が中を開いたときに有無が分かる）。
    _addJsonEntry(archive, memoTemplatesFileName, <Map<String, dynamic>>[
      for (final MemoTemplate template in templates) template.toJson(),
    ]);

    for (final MapEntry<String, Uint8List> entry in imagesById.entries) {
      // WHY: JPEG/PNG は既に圧縮済みで、再圧縮は画質劣化と処理時間増にしか
      // ならない。画像は無圧縮（store）で格納する。
      archive.add(
        ArchiveFile.noCompress(
          '$imagesDirectoryName/${entry.key}',
          entry.value.length,
          entry.value,
        ),
      );
    }

    return ZipEncoder().encodeBytes(archive);
  }

  /// ZIP バイト列を検証しつつ復号する。形式不正は [BackupFormatException]。
  ///
  /// 画像の欠落だけは例外にせず [BackupArchive.warnings] に積む（裁定 D と同旨:
  /// 1 枚の欠落でバックアップ全体を復元不能にしない）。
  BackupArchive decode(Uint8List bytes) {
    final Archive archive = _decodeZip(bytes);
    final BackupManifest manifest = _readManifest(archive);
    final List<String> warnings = <String>[];
    final Map<String, Uint8List> imagesById = <String, Uint8List>{};
    final List<PlayRecord> records = _readRecords(
      archive,
      imagesById,
      warnings,
    );

    return BackupArchive(
      manifest: manifest,
      records: records,
      imagesById: imagesById,
      warnings: warnings,
      templates: _readMemoTemplates(archive, warnings),
    );
  }

  /// `memo_templates.json` を読む（無ければ空・壊れていても復元は続行）。
  ///
  /// WHY 例外にしないか: テンプレートは入力の補助データであり、その 1 ファイルの
  /// 破損で記録（本体データ）の復元を止めるのは釣り合わない。破損は warnings に
  /// 積んで利用者に知らせる。
  List<MemoTemplate> _readMemoTemplates(
    Archive archive,
    List<String> warnings,
  ) {
    final ArchiveFile? file = archive.find(memoTemplatesFileName);
    if (file == null) {
      return const <MemoTemplate>[];
    }
    final dynamic decoded;
    try {
      decoded = _decodeJson(file, memoTemplatesFileName);
    } on BackupFormatException catch (error) {
      warnings.add('$memoTemplatesFileName を読み取れないため、メモのテンプレートは復元しません。');
      developer.log(
        '$memoTemplatesFileName の復号に失敗: $error',
        name: 'backup_archive_codec',
      );
      return const <MemoTemplate>[];
    }
    if (decoded is! List) {
      warnings.add('$memoTemplatesFileName の形式が不正なため、メモのテンプレートは復元しません。');
      return const <MemoTemplate>[];
    }
    final List<MemoTemplate> templates = <MemoTemplate>[];
    for (final dynamic entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      try {
        templates.add(MemoTemplate.fromJson(entry));
      } on FormatException catch (error) {
        // 1 件単位の不備はスキップ（records.json と同じ方針）。
        warnings.add('不正なメモのテンプレートを 1 件スキップしました。');
        developer.log('不正なメモテンプレート: $error', name: 'backup_archive_codec');
      }
    }
    return templates;
  }

  Map<String, String> _relativePaths(Iterable<String> imageFileNames) {
    final Map<String, String> result = <String, String>{};
    for (final String fileName in imageFileNames) {
      result[_recordIdOf(fileName)] = '$imagesDirectoryName/$fileName';
    }
    return result;
  }

  String _recordIdOf(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  Map<String, dynamic> _recordJson(
    PlayRecord record,
    Map<String, String> relativePathByRecordId,
  ) {
    final Map<String, dynamic> json = record.toJson();
    // WHY: 端末固有の絶対パスを持ち出すと別端末で復元できない。
    json['resultImagePath'] = relativePathByRecordId[record.id] ?? '';
    return json;
  }

  void _addJsonEntry(Archive archive, String name, Object json) {
    // WHY: JSON は十分に縮むので deflate で入れて ZIP を小さく保つ。
    archive.add(
      ArchiveFile.string(name, jsonEncode(json))
        ..compression = CompressionType.deflate,
    );
  }

  Archive _decodeZip(Uint8List bytes) {
    try {
      // WHY: verify を有効にすると CRC 不一致も検出できる。壊れた ZIP を
      // 途中まで読んで部分復元するより、1 件も書かない方が安全。
      return ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object catch (error) {
      throw BackupFormatException('ZIP として読み込めません: $error');
    }
  }

  BackupManifest _readManifest(Archive archive) {
    final ArchiveFile? file = archive.find(manifestFileName);
    if (file == null) {
      throw const BackupFormatException('manifest.json が見つかりません');
    }
    final BackupManifest manifest = BackupManifest.fromJson(
      _readJsonObject(file, manifestFileName),
    );
    if (manifest.format != BackupManifest.backupFormat) {
      throw BackupFormatException('バックアップ形式が一致しません: ${manifest.format}');
    }
    if (manifest.schemaVersion > BackupManifest.currentSchemaVersion) {
      throw BackupFormatException(
        'このバックアップは新しい形式です（schemaVersion ${manifest.schemaVersion}）。'
        'アプリを更新してください。',
      );
    }
    return manifest;
  }

  List<PlayRecord> _readRecords(
    Archive archive,
    Map<String, Uint8List> imagesById,
    List<String> warnings,
  ) {
    final ArchiveFile? file = archive.find(recordsFileName);
    if (file == null) {
      throw const BackupFormatException('records.json が見つかりません');
    }
    final Object? decoded = _decodeJson(file, recordsFileName);
    if (decoded is! List) {
      throw const BackupFormatException('records.json が JSON 配列ではありません');
    }

    final List<PlayRecord> records = <PlayRecord>[];
    for (final Object? entry in decoded) {
      records.add(_readRecord(entry, archive, imagesById, warnings));
    }
    return records;
  }

  PlayRecord _readRecord(
    Object? entry,
    Archive archive,
    Map<String, Uint8List> imagesById,
    List<String> warnings,
  ) {
    if (entry is! Map<String, dynamic>) {
      throw const BackupFormatException('records.json の要素がオブジェクトではありません');
    }
    return _attachImage(_parseRecord(entry), archive, imagesById, warnings);
  }

  PlayRecord _parseRecord(Map<String, dynamic> json) {
    try {
      return PlayRecord.fromJson(json);
    } on Object catch (error) {
      throw BackupFormatException('レコードを解釈できません: $error');
    }
  }

  PlayRecord _attachImage(
    PlayRecord record,
    Archive archive,
    Map<String, Uint8List> imagesById,
    List<String> warnings,
  ) {
    final String relativePath = record.resultImagePath;
    if (relativePath.isEmpty) {
      return record;
    }

    final String entryName = _imageEntryName(relativePath);
    final ArchiveFile? file = archive.find(entryName);
    if (file == null) {
      warnings.add('画像が見つかりません: $entryName');
      return record.copyWith(resultImagePath: '');
    }

    final String fileName = entryName.substring(imagesDirectoryName.length + 1);
    imagesById[fileName] = file.content;
    return record.copyWith(resultImagePath: entryName);
  }

  String _imageEntryName(String relativePath) {
    final String normalized = relativePath.replaceAll(r'\', '/');
    if (normalized.startsWith('$imagesDirectoryName/')) {
      return normalized;
    }
    // WHY: 旧版や手作業の ZIP は images/ 接頭辞を欠くことがある。ファイル名
    // だけは信用して images/ 配下を探し直す。
    final int slash = normalized.lastIndexOf('/');
    final String fileName = slash < 0
        ? normalized
        : normalized.substring(slash + 1);
    return '$imagesDirectoryName/$fileName';
  }

  Map<String, dynamic> _readJsonObject(ArchiveFile file, String label) {
    final Object? decoded = _decodeJson(file, label);
    if (decoded is! Map<String, dynamic>) {
      throw BackupFormatException('$label が JSON オブジェクトではありません');
    }
    return decoded;
  }

  Object? _decodeJson(ArchiveFile file, String label) {
    try {
      return jsonDecode(utf8.decode(file.content));
    } on Object catch (error) {
      throw BackupFormatException('$label を解釈できません: $error');
    }
  }
}
