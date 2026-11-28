import 'dart:convert';
import 'dart:developer' as developer;

import 'package:scoreyomipm/ocr/in_memory_song_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/platform/blob_store.dart';

/// `BlobStore` のキー + JSON パーサを受け取り `Future<InMemorySongRepository>` を返す。
///
/// `dart:io` を持たず、Web の IndexedDB (`IdbBlobStore`) でも動作する。
/// 壊れた行はスキップし、正常にパースできた件数を返す。
class BlobStoreSongRepositoryLoader {
  BlobStoreSongRepositoryLoader({
    required this.blobStore,
    required this.key,
    required this.parser,
  });

  final BlobStore blobStore;
  final String key;
  final List<SongEntry> Function(String json) parser;

  /// BlobStore から JSON を読み込み、`InMemorySongRepository` を構築する。
  ///
  /// キーにデータが無い場合は空のリポジトリを返す。JSON が壊れていても
  /// 例外を投げず、空のリポジトリを返す（§5-1）。
  Future<InMemorySongRepository> load() async {
    final bytes = await blobStore.read(key);
    if (bytes == null) {
      return InMemorySongRepository(entries: const <SongEntry>[]);
    }
    final json = utf8.decode(bytes);
    try {
      final entries = parser(json);
      return InMemorySongRepository(entries: entries);
    } catch (e) {
      // 境界なので例外を握り潰さず、空リポジトリとして扱う。
      // 壊れた JSON・songs キー欠落・行の型違いなどをすべてここで吸収する。
      developer.log('BlobStoreSongRepositoryLoader: 壊れたデータをスキップ ($key)', error: e, name: 'BlobStoreSongRepositoryLoader');
      return InMemorySongRepository(entries: const <SongEntry>[]);
    }
  }
}
