// ST-6 楽曲辞書マージリポジトリ
//
// spec.md §10: bundledSeed / downloadedMain / localAdditional の3ソースをマージ。
// 正規化キー重複時は追加DB（localAdditional）優先 → downloadedMain → bundledSeed
// の順で上書き。新曲の運用反映を追加DBで上書きできる意。
//
// ソース「間」では上記の優先順位でキーごとに丸ごと差し替えるが、
// ソース「内」の同一キー行は全部残す（同名異曲を消さない）。
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

  /// ソースを優先順位順（高→低）でマージする。
  ///
  /// WHY(ソース内の同一キー行を残すか): 正規化キーが同じでも別曲（版違い・
  /// アレンジ違い）が実在する。実データでは 14 群が該当し、キー 1 本につき
  /// 1 行しか持たなかった旧実装ではその 14 群で曲が消えていた
  /// （2,100 行 → 2,086 行）。「同名は 1 曲」という前提自体が誤り。
  ///
  /// WHY(ソース間はキー単位で丸ごと差し替えるか): 下位ソースの行だけを
  /// 残すと、優先度の低い古い定義が同じキーに混ざる。キーを持つ最上位
  /// ソースの行群で置き換え、下位ソースの同一キー行は捨てる。
  void _merge() {
    _byNormalizedKey.clear();
    _allSongs.clear();

    // 優先順位の低いソースから積み、上位ソースが同一キーを丸ごと置換する。
    final rowsByKey = <String, List<SongEntry>>{};
    for (int i = _sources.length - 1; i >= 0; i--) {
      final source = _sources[i];
      if (!source.isAvailable) continue;
      rowsByKey.addAll(_groupByNormalizedKey(source.allSongs));
    }

    for (final rows in rowsByKey.values) {
      // WHY(id 昇順に並べるか): 代表行を id 最小に固定するため。代表の
      // 選び方が入力順に依存すると、findByNormalizedKey の戻り値が
      // 実行ごとに変わる。
      rows.sort((a, b) => a.id.compareTo(b.id));
      _byNormalizedKey[rows.first.normalizedKey] = rows.first;
      _allSongs.addAll(rows);
    }

    // WHY(キーと id の 2 段で並べるか): キーだけで並べると同キー内の順序が
    // 未定義になり、allSongs の並び（＝検索結果の順位）が実行ごとに揺れる。
    _allSongs.sort((a, b) {
      final byKey = a.normalizedKey.compareTo(b.normalizedKey);
      return byKey != 0 ? byKey : a.id.compareTo(b.id);
    });
  }

  /// [entries] を normalizedKey ごとにまとめる（キー内の順序は元のまま）。
  static Map<String, List<SongEntry>> _groupByNormalizedKey(
    List<SongEntry> entries,
  ) {
    final grouped = <String, List<SongEntry>>{};
    for (final entry in entries) {
      (grouped[entry.normalizedKey] ??= <SongEntry>[]).add(entry);
    }
    return grouped;
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
