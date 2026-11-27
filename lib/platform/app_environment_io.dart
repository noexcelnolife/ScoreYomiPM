/// 端末（Android/iOS 相当）向けの [AppEnvironment] 実装。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data/memo_template_repository.dart';
import '../ocr/downloaded_main_repository.dart';
import '../ocr/local_additional_repository.dart';
import '../songdb/song_database_service.dart';
import '../songdb/song_db_paths.dart';
import 'app_environment.dart';
import 'blob_store.dart';
import 'io_blob_store.dart';
import 'platform_capabilities.dart';

/// documents ディレクトリを基点に、端末用の一式を組み立てる。
///
/// WHY(documents を基点にするか): キーは `records/records.json` と
/// `records/images/<name>` になり、v1.0.3 以前の配置とそのまま一致する。
/// ここを変えると既存端末の記録・画像が読めなくなる。
Future<AppEnvironment> createAppEnvironment() async {
  final Directory documentsDirectory = await getApplicationDocumentsDirectory();
  final BlobStore blobStore = IoBlobStore(documentsDirectory);

  return AppEnvironment(
    capabilities: const LocalCapabilities(),
    blobStore: blobStore,
    songDatabaseService: FileSongDatabaseService(
      documentsDirectoryResolver: () async => documentsDirectory,
    ),
    // WHY(パスを文字列で渡すか): lib/songdb の書き込み先と lib/ocr リポジトリの
    // 読み込み先は SongDbPaths で一致している必要がある。マージ優先順位
    // （追加 > メイン > シード）とフォールバック判定は MergedSongRepository 側に
    // 完結しており、ここでは素材を渡すだけに留める（DIP）。
    mainSongRepository: DownloadedMainRepository(
      '${documentsDirectory.path}/${SongDbPaths.mainDbRelativePath}',
    ),
    additionalSongRepository: LocalAdditionalRepository(
      '${documentsDirectory.path}/${SongDbPaths.additionalDbRelativePath}',
    ),
    // WHY(records.json と別ファイルか): 入力の補助データであり、記録の
    // スキーマや読み書き経路に手を入れず、破損時の影響範囲も閉じられる。
    memoTemplateRepository: FileMemoTemplateRepository(
      documentsDirectoryResolver: () async => documentsDirectory,
    ),
  );
}
