// バックアップのエクスポート（タスク 01a20bfe・データ層）。
//
// WHY: ZIP と CSV は保存先選択（UI 側）に渡すバイト列/文字列として作り、
// この層では保存ダイアログを出さない。UI とデータ層の責務を分けておくと、
// 保存先の選択ミスや権限エラーを UI 側で一元的に扱える。
import 'dart:io';
import 'dart:typed_data';

import '../data/memo_template.dart';
import '../data/memo_template_repository.dart';
import '../data/play_record.dart';
import '../data/play_record_repository.dart';
import 'backup_archive_codec.dart';
import 'backup_csv_encoder.dart';
import 'backup_manifest.dart';

/// 既存レコードからバックアップを作る。
class BackupExportService {
  BackupExportService({
    required this._repository,
    required this._appVersion,
    this._memoTemplateRepository,
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

  /// 全レコードと画像（とメモのテンプレート）を ZIP バイト列にする。
  Future<Uint8List> buildZip() async {
    final List<PlayRecord> records = await _repository.listAll();
    final Map<String, Uint8List> imagesById = await _loadImages(records);
    final List<MemoTemplate> templates =
        await _memoTemplateRepository?.listAll() ?? const <MemoTemplate>[];

    return _codec.encode(
      manifest: BackupManifest(
        appVersion: _appVersion,
        exportedAt: _clock(),
        recordCount: records.length,
        imageCount: imagesById.length,
        templateCount: templates.length,
      ),
      records: records,
      imagesById: imagesById,
      templates: templates,
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
      final File file = File(record.resultImagePath);
      // WHY: 画像ファイルが既に消えている場合（手動削除・OS の掃除）でも
      // バックアップ自体は作れるようにし、そのレコードは画像なしとして扱う。
      if (!await file.exists()) {
        continue;
      }
      // WHY: ZIP 内の画像名はレコード id を stem にして、復元時にレコードと
      // 確実に対応づけられるようにする。
      images['${record.id}.${_imageExtension(record.resultImagePath)}'] =
          await file.readAsBytes();
    }
    return images;
  }

  String _imageExtension(String path) =>
      path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
}
