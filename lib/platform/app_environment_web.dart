/// ブラウザ向けの [AppEnvironment] 実装。
library;

import 'package:idb_shim/idb_browser.dart' show idbFactoryBrowser;

import '../songdb/unsupported_song_database_service.dart';
import 'app_environment.dart';
import 'blob_store.dart';
import 'idb_blob_store.dart';
import 'storage_persistence_web.dart';
import 'web_capabilities.dart';

/// IndexedDB を保存先にして、ブラウザ用の一式を組み立てる。
///
/// WHY(曲 DB リポジトリを null にするか): 配信取得も追加取り込みも
/// 「端末のファイルを差し替える」処理で、Web にはファイルパスの概念が無い。
/// シード（アプリ同梱）だけで曲名検索は成立するため、補助データ無しで起動する。
///
/// WHY(メモテンプレートを null にするか): 現行のテンプレート実装は
/// documents ディレクトリ配下の JSON を読み書きする。BlobStore への移行は
/// 別作業（計画の残項目）であり、ここで中途半端に繋ぐと保存先が二重になる。
/// テンプレートが無くても手入力そのものは成立する。
Future<AppEnvironment> createAppEnvironment() async {
  // WHY(永続化要求を最初の書き込みに繋ぐか): 起動直後に呼ぶと目的の分から
  // ない許可を求めることになる。最初の記録保存は「利用者がデータを残そうと
  // 決めた」瞬間なので、その直後に 1 回だけ要求する。
  final BlobStore blobStore = IdbBlobStore(
    idbFactoryBrowser,
    onFirstWrite: requestPersistentStorage,
  );

  return AppEnvironment(
    capabilities: const WebCapabilities(),
    blobStore: blobStore,
    // WHY(非対応サービスを渡すか): UI 側は canUpdateSongDatabase で入口を
    // 隠すが、隠し漏れがあっても落ちないよう、呼ばれても失敗を返す実装にする。
    songDatabaseService: const UnsupportedSongDatabaseService(),
  );
}
