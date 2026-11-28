// ST-7 プラットフォーム環境（IO / Android）

import 'package:path_provider/path_provider.dart';

import 'package:scoreyomipm/data/memo_template_repository.dart';
import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/merged_song_repository.dart';
import 'package:scoreyomipm/ocr/song_json_parser.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/platform/app_environment.dart';
import 'package:scoreyomipm/platform/io_blob_store.dart';
import 'package:scoreyomipm/platform/platform_capabilities.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

/// IO 環境向けの [createAppEnvironment] ファクトリ。
///
/// `FileSongDatabaseService(blobStore:)` を注入し、`MergedSongRepository` は
/// `BlobStoreSongRepositoryLoader` 経由で `IoBlobStore` から辞書を読む。
///
/// 初期ロードは行わない（`reload()` は初期化後に別途呼び出す）。
/// WHY: `BlobStore` 読み込みを起動時経路（`createAppEnvironment` → `main()`）で
/// await すると初回描画をブロックするため。読み直しは `_runSongMatching` の
/// run ごと、`song_title_live_search` の `_loadRepository()`、取り込み直後、
/// バックアップ復元直後（S5）の 4 か所で行う。OCR は元々数秒かかる処理なので、
/// IndexedDB/ファイルからの 1MB 読みコストはその中に隠れる。
Future<AppEnvironment> createAppEnvironment() async {
  final documentsDirectory = await getApplicationDocumentsDirectory();
  final blobStore = IoBlobStore(documentsDirectory);

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
    capabilities: const LocalCapabilities(),
    mainSongRepository: mainSongRepository,
    additionalSongRepository: additionalSongRepository,
    memoTemplateRepository: FileMemoTemplateRepository(
      documentsDirectoryResolver: () async => documentsDirectory,
    ),
  );
}
