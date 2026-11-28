// ST-7 プラットフォーム環境（Web）

import 'package:idb_shim/idb_browser.dart';

import 'package:scoreyomipm/data/blob_store_memo_template_repository.dart';
import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_json_parser.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/platform/app_environment.dart';
import 'package:scoreyomipm/platform/idb_blob_store.dart';
import 'package:scoreyomipm/platform/web_capabilities.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

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
  final blobStore = IdbBlobStore(idbFactoryBrowser);
  final songDatabaseService = FileSongDatabaseService(blobStore: blobStore);

  final mainLoader = BlobStoreSongRepositoryLoader(
    blobStore: blobStore,
    key: SongDbPaths.mainDbRelativePath,
    parser: parseSongsJson,
  );
  final additionalLoader = BlobStoreSongRepositoryLoader(
    blobStore: blobStore,
    key: SongDbPaths.additionalDbRelativePath,
    parser: parseSongsJson,
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
    capabilities: const WebCapabilities(),
    mainSongRepository: mainSongRepository,
    additionalSongRepository: additionalSongRepository,
    memoTemplateRepository: BlobStoreMemoTemplateRepository(blobStore),
  );
}
