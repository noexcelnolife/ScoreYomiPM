// ST-6 Local Additional リポジトリ（スタブ）
//
// spec.md §10: ユーザー追加DB（オーバーレイ）。アーケード新曲リリース時に
// メインDB更新が追いつかない場合、ユーザーが新曲をここで上書き登録できる。
// マージ時は最優先（bundledSeed/downloadedMain より上）。
//
// 実ディスク読込は App-UI 層（タスク 01a201da）で実装。本層ではスタブ。

import 'dart:convert';
import 'dart:io';

import 'song_entry.dart';
import 'song_repository.dart';

/// ユーザー追加DBリポジトリ（スタブ）。
///
/// [jsonPath] はユーザー追加DBのJSONファイルパス。
//  本タスク（OCR層）ではスタブとし、ファイル存在チェックのみ行う。
class LocalAdditionalRepository implements SongRepository {
  final String _jsonPath;

  LocalAdditionalRepository(this._jsonPath);

  final List<SongEntry> _songs = [];
  bool _loaded = false;

  @override
  String get sourceName => 'localAdditional($_jsonPath)';

  @override
  bool get isAvailable {
    if (!_loaded) {
      _loadIfExists();
    }
    return _loaded && _songs.isNotEmpty;
  }

  @override
  List<SongEntry> get allSongs => List.unmodifiable(_songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final entry in _songs) {
      if (entry.normalizedKey == normalizedKey) {
        return entry;
      }
    }
    return null;
  }

  @override
  int get length => _songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      _songs.any((e) => e.normalizedKey == normalizedKey);

  /// ファイルが存在すれば読込、なければ空辞書。
  void _loadIfExists() {
    final file = File(_jsonPath);
    if (!file.existsSync()) {
      _loaded = false;
      return;
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final songsJson = json['songs'] as List<dynamic>?;

      _songs.clear();
      if (songsJson != null) {
        for (final songJson in songsJson) {
          try {
            final entry = SongEntry.fromJson(songJson as Map<String, dynamic>);
            _songs.add(entry);
          } catch (_) {
            // Bad行はスキップ
          }
        }
      }

      _songs.sort((a, b) => a.normalizedKey.compareTo(b.normalizedKey));
      _loaded = true;
    } catch (_) {
      _loaded = false;
    }
  }
}
