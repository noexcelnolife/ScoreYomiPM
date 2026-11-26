// ST-6 楽曲辞書リポジトリ抽象（DIP）
//
// spec.md §10: 収録曲DB リポジトリ抽象化。bundledSeed（アセットJSON・オフライン
// フォールバック）／downloadedMain（配信サーバーからDL済み）／localAdditional
//（ユーザー追加オーバーレイ）の3ソースを統一的に扱う。
//
// SongTitleMatcher は変更なしでこの抽象を受け取る（契約を壊さない）。

import 'song_entry.dart';

/// 楽曲辞書リポジトリのインターフェース。
///
/// 3つの具体実装（BundledSeed / DownloadedMain / LocalAdditional）および
/// それらをマージした MergedSongRepository がこのインターフェースを実装する。
abstract class SongRepository {
  /// ソース種別名（デバッグ・ログ用）。
  String get sourceName;

  /// このソースが利用可能か（ネットワーク不通・ファイル欠落等で false）。
  bool get isAvailable;

  /// マージ後全楽曲リスト（正規化キー順）。
  List<SongEntry> get allSongs;

  /// 正規化キーで楽曲を検索。見つからなければ null。
  SongEntry? findByNormalizedKey(String normalizedKey);

  /// 辞書エントリ数。
  int get length;

  /// 正規化済みキーが辞書に存在するか。
  bool containsNormalizedKey(String normalizedKey);
}
