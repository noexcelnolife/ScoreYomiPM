// ST-7 プラットフォーム環境（IO / Android）

import 'dart:convert';
import 'dart:io';

import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/platform/app_environment.dart';
import 'package:scoreyomipm/platform/io_blob_store.dart';
import 'package:scoreyomipm/platform/platform_capabilities.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

/// 曲 JSON をパースして [List<SongEntry>] に変換する。
///
/// bad row（id/title 欠如等）は [SongEntry.fromJson] が例外を投げるため、
/// 呼び出し側（[BlobStoreSongRepositoryLoader.load]）で catch しスキップする。
List<SongEntry> _parseSongJson(String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final songs = data['songs'] as List<dynamic>;
  return songs
      .whereType<Map<String, dynamic>>()
      .map((row) {
        try {
          return SongEntry.fromJson(row);
        } catch (_) {
          // bad row → skip（partial failure 許容）。
          return null;
        }
      })
      .whereType<SongEntry>()
      .toList();
}

/// IO 環境向けの [createAppEnvironment] ファクトリ。
///
/// `FileSongDatabaseService(blobStore:)` を注入し、`MergedSongRepository` は
/// `BlobStoreSongRepositoryLoader` 経由で `IoBlobStore` から辞書を読む。
///
/// 初期ロードは `createAppEnvironment` 内で `await reload()` する（ファイル
/// I/O は高速なので初回描画をブロックしない）。
Future<AppEnvironment> createAppEnvironment() async {
  final blobStore = IoBlobStore(Directory('data'));

  final songDatabaseService = FileSongDatabaseService(blobStore: blobStore);

  final mainLoader = BlobStoreSongRepositoryLoader(
    blobStore: blobStore,
    key: SongDbPaths.mainDbRelativePath,
    parser: _parseSongJson,
  );
  final additionalLoader = BlobStoreSongRepositoryLoader(
    blobStore: blobStore,
    key: SongDbPaths.additionalDbRelativePath,
    parser: _parseSongJson,
  );

  final mainSongRepository = MergedSongRepository(
    sources: const <SongRepository>[],
    loaders: <BlobStoreSongRepositoryLoader>[mainLoader],
  );
  final additionalSongRepository = MergedSongRepository(
    sources: const <SongRepository>[],
    loaders: <BlobStoreSongRepositoryLoader>[additionalLoader],
  );

  // IO はファイル読み込みが高速なため、初期ロードをここで await する。
  // 初回描画をブロックしない（読み込みは数 KB 程度）。
  await mainSongRepository.reload();
  await additionalSongRepository.reload();

  return AppEnvironment(
    blobStore: blobStore,
    songDatabaseService: songDatabaseService,
    capabilities: const LocalCapabilities(),
    mainSongRepository: mainSongRepository,
    additionalSongRepository: additionalSongRepository,
  );
}

