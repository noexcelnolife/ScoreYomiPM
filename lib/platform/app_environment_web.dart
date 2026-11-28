// ST-7 プラットフォーム環境（Web）

import 'dart:convert';
import 'dart:html';

import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/platform/app_environment.dart';
import 'package:scoreyomipm/platform/idb_blob_store.dart';
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

/// Web 環境向けの [createAppEnvironment] ファクトリ。
///
/// `FileSongDatabaseService(blobStore:)` を注入し、`MergedSongRepository` は
/// `BlobStoreSongRepositoryLoader` 経由で `IdbBlobStore` から辞書を読む。
///
/// 初期ロードは行わない（`reload()` は初期化後に別途呼び出す）。
/// WHY: IdbBlobStore から 1MB 読む処理を初期化時に await すると初回描画を
/// ブロックするため。取り込み成功後の `_handleSongDbChanged` または
/// 最初の検索で reload() を呼び出す。
Future<AppEnvironment> createAppEnvironment() async {
  final blobStore = IdbBlobStore(window.indexedDB!);
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

  return AppEnvironment(
    blobStore: blobStore,
    songDatabaseService: songDatabaseService,
    capabilities: const LocalCapabilities(),
    mainSongRepository: mainSongRepository,
    additionalSongRepository: additionalSongRepository,
  );
}


