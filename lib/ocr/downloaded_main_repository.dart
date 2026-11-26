// ST-6 Downloaded Main リポジトリ（スタブ）
//
// spec.md §10: 配信サーバーから初回起動時・DB更新時にダウンロードした JSON DB。
// 実ディスク読込（path_provider の appDocumentsDirectory 等）は App-UI 層
//（タスク 01a201da）で実装。本層ではスタブとしてファイル存在チェックのみ。
//
// 将来の実装:
//   - appDocumentsDirectory/songs/main_v1.json を読込
//   - network で JSON を取得しキャッシュ
//   - schemaVersion チェックで差分DL判定

import 'dart:convert';
import 'dart:io';

import 'song_entry.dart';
import 'song_repository.dart';

/// ダウンロード済みメインDBリポジトリ（スタブ）。
///
/// [jsonPath] は path_provider で解決した appDocumentsDirectory 配下のパス。
//  本タスク（OCR層）ではスタブとし、ファイル存在チェックのみ行う。
class DownloadedMainRepository implements SongRepository {
  final String _jsonPath;

  DownloadedMainRepository(this._jsonPath);

  final List<SongEntry> _songs = [];
  bool _loaded = false;

  @override
  String get sourceName => 'downloadedMain($_jsonPath)';

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
