// バックアップのエクスポート（タスク 01a20bfe・データ層）。
//
// WHY: ZIP と CSV は保存先選択（UI 側）に渡すバイト列/文字列として作り、
// この層では保存ダイアログを出さない。UI とデータ層の責務を分けておくと、
// 保存先の選択ミスや権限エラーを UI 側で一元的に扱える。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import '../data/memo_template.dart';
import '../data/memo_template_repository.dart';
import '../data/play_record.dart';
import '../data/play_record_repository.dart';
import '../platform/blob_store.dart';
import '../songdb/song_db_paths.dart';
import 'backup_archive_codec.dart';
import 'backup_csv_encoder.dart';
import 'backup_manifest.dart';

/// 既存レコードからバックアップを作る。
class BackupExportService {
  BackupExportService({
    required this._repository,
    required this._appVersion,
    this._memoTemplateRepository,
    required this._blobStore,
    this._codec = const BackupArchiveCodec(),
    this._csvEncoder = const BackupCsvEncoder(),
    this._clock = DateTime.now,
  });

  final PlayRecordRepository _repository;
  final String _appVersion;
  final BackupArchiveCodec _codec;
  final BackupCsvEncoder _csvEncoder;
  final DateTime Function() _clock;

  /// メモのテンプレート供給元（null ならテンプレートを同梱しない）。
  ///
  /// WHY null 許容か: テンプレートは入力の補助データで、無くても ZIP は成立する。
  /// 既存の呼び出し側・テストを壊さない後方互換のため任意注入にする。
  final MemoTemplateRepository? _memoTemplateRepository;

  /// ファイル保存先（追加辞書の読み出しに使用）。
  final BlobStore _blobStore;

  /// 全レコードと画像（とメモのテンプレート）を ZIP バイト列にする。
  Future<Uint8List> buildZip() async {
    final List<PlayRecord> records = await _repository.listAll();
    final Map<String, Uint8List> imagesById = await _loadImages(records);
    final List<MemoTemplate> templates =
        await _memoTemplateRepository?.listAll() ?? const <MemoTemplate>[];

    // WHY: 追加辞書は存在するときだけ ZIP に入れる。無い ZIP は旧形式と同等で、
    // 復元側は辞書を更新しない（扱いは「変更なし」と同じ）。
    String? additionalSongs;
    int additionalSongCount = 0;
    try {
      final bytes = await _blobStore.read(SongDbPaths.additionalDbRelativePath);
      if (bytes != null) {
        additionalSongs = utf8.decode(bytes);
        final decoded = jsonDecode(additionalSongs) as Map<String, dynamic>;
        final songs = decoded['songs'] as List? ?? const <dynamic>[];
        additionalSongCount = songs.length;
      }
    } on Object catch (error) {
      // 追加辞書の読み出しに失敗してもバックアップ自体は作る（変化なしとみなす）。
      // エントリは書かず、developer に警告を残す。
      additionalSongs = null;
      additionalSongCount = 0;
      developer.log(
        '追加辞書の読み出しに失敗しました。辞書なしでバックアップを続行します。',
        name: 'backup_export_service',
        error: error,
      );
    }

    return _codec.encode(
      manifest: BackupManifest(
        appVersion: _appVersion,
        exportedAt: _clock(),
        recordCount: records.length,
        imageCount: imagesById.length,
        templateCount: templates.length,
        additionalSongCount: additionalSongCount,
      ),
      records: records,
      imagesById: imagesById,
      templates: templates,
      additionalSongs: additionalSongs,
    );
  }

  /// 全レコードを CSV 文字列にする。
  Future<String> buildCsv() async =>
      _csvEncoder.encode(await _repository.listAll());

  Future<Map<String, Uint8List>> _loadImages(List<PlayRecord> records) async {
    final Map<String, Uint8List> images = <String, Uint8List>{};
    for (final PlayRecord record in records) {
      if (record.resultImagePath.isEmpty) {
        continue;
      }
      // WHY(リポジトリ経由で読むか): resultImagePath は basename で、実体の
      // 位置は保存先（端末のディスク / ブラウザの IndexedDB）ごとに違う。
      // ここで File を直接開くと Web で必ず失敗し、画像なしのバックアップが
      // 黙って出来上がる。保存先の知識はリポジトリに閉じ込める。
      final Uint8List? bytes = await _repository.readImage(
        record.resultImagePath,
      );
      // WHY: 画像が既に消えている場合（手動削除・OS の掃除）でもバックアップ
      // 自体は作れるようにし、そのレコードは画像なしとして扱う。
      if (bytes == null) {
        continue;
      }
      // WHY: ZIP 内の画像名はレコード id を stem にして、復元時にレコードと
      // 確実に対応づけられるようにする。
      images['${record.id}.${_imageExtension(record.resultImagePath)}'] = bytes;
    }
    return images;
  }

  String _imageExtension(String path) =>
      path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
}
