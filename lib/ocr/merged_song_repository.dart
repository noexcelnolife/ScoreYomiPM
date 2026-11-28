// ST-6 楽曲辞書マージリポジトリ
//
// spec.md §10: bundledSeed / downloadedMain / localAdditional の3ソースをマージ。
// 正規化キー重複時は追加DB（localAdditional）優先 → downloadedMain → bundledSeed
// の順で上書き。新曲の運用反映を追加DBで上書きできる意。
//
// Bad行（JSONパースエラー・必須フィールド欠如等）は1エントリずつスキップし、
// マージ全体は失敗させない（partial failure 許容）。

import 'package:scoreyomipm/ocr/blob_store_song_repository_loader.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';

/// 3ソースをマージした統合楽曲辞書リポジトリ。
///
/// 優先順位（高→低）:
///   1. localAdditional（ユーザー追加オーバーレイ）
///   2. downloadedMain（配信サーバーDL済みメインDB）
///   3. bundledSeed（アセットJSON・オフラインフォールバック）
class MergedSongRepository implements SongRepository, ReloadableSongRepository {
  MergedSongRepository({
    required List<SongRepository> sources,
    required this.loaders,
  }) : _sources = List<SongRepository>.from(sources) {
    _merge();
  }

  final List<SongRepository> _sources;
  final List<BlobStoreSongRepositoryLoader> loaders;

  final Map<String, SongEntry> _byNormalizedKey = {};
  final List<SongEntry> _allSongs = [];

  /// [sources] は優先順位順（インデックス0が最優先）で渡すこと。
  /// [loaders] は [reload] で BlobStore からソースを再読み込みする際に使用する。

  @override
  String get sourceName =>
      'merged(${_sources.map((s) => s.sourceName).join(', ')})';

  @override
  bool get isAvailable => _sources.any((s) => s.isAvailable);

  @override
  List<SongEntry> get allSongs => List.unmodifiable(_allSongs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) =>
      _byNormalizedKey[normalizedKey];

  @override
  int get length => _allSongs.length;

  List<SongEntry> findCandidates(String query) {
    if (query.isEmpty) return const <SongEntry>[];
    final q = query.toLowerCase();
    return _allSongs.where((e) => e.title.toLowerCase().contains(q)).toList();
  }

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      _byNormalizedKey.containsKey(normalizedKey);

  /// ソースを優先順位順（高→低）でマージ。
  ///
  /// 同一 normalizedKey が複数ソースに存在する場合、より優先度の高いソース
  /// のエントリが採用される。
  void _merge() {
    _byNormalizedKey.clear();
    _allSongs.clear();

    // 優先順位の低いソースから順に処理し、上書きしていく。
    // これにより、高優先度ソースのエントリが最終的に残る。
    for (int i = _sources.length - 1; i >= 0; i--) {
      final source = _sources[i];
      if (!source.isAvailable) continue;
      for (final entry in source.allSongs) {
        _byNormalizedKey[entry.normalizedKey] = entry;
      }
    }

    // 正規化キー順でソートして安定した順序を確保。
    _allSongs.addAll(_byNormalizedKey.values);
    _allSongs.sort((a, b) => a.normalizedKey.compareTo(b.normalizedKey));
  }

  /// ソースリストを再マージ（ソース追加・削除・変更後に呼び出す）。
  void refresh() {
    _merge();
  }

  /// BlobStore からソースを読み直し、再マージする。
  ///
  /// 取り込み直後に呼び出すことで、新しい曲がすぐに検索に出るようにする。
  /// 各ローダーから新しい [InMemorySongRepository] を作成し、ソース差し替え後
  /// に [refresh] を実行する。
  @override
  Future<void> reload() async {
    final sources = <SongRepository>[];
    for (final loader in loaders) {
      sources.add(await loader.load());
    }
    _sources
      ..clear()
      ..addAll(sources);
    _merge();
  }
}
