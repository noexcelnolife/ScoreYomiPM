// ST-6 Bundled Seed リポジトリ（オフラインフォールバック）
//
// spec.md §10: アプリ同梱のシード辞書。ネットワーク不通時のフォールバック用。
// pubspec.yaml の flutter/assets に登録し、rootBundle で読込。

import 'dart:convert';

import 'package:flutter/services.dart';

import 'song_entry.dart';
import 'song_repository.dart';

/// アセットJSONから楽曲辞書を構築するリポジトリ。
///
/// JSON スキーマ:
///   {
///     "schemaVersion": 1,
///     "updatedAt": "2026-11-22T00:00:00Z",
///     "sourceType": "bundledSeed",
///     "songCount": 33,
///     "songs": [ { "id": "...", "title": "...", ... } ]
///   }
class BundledSeedRepository implements SongRepository {
  /// 既定アセット。seed_v2（notesCounts マップ化＋レベル修正 5 件・
  /// タスク 01a20305）に切替。seed_v1 は生成ツールの入力として disk に残置。
  static const String _defaultAssetPath = 'assets/songs/seed_v2.json';

  final String _assetPath;

  BundledSeedRepository({String? assetPath})
    : _assetPath = assetPath ?? _defaultAssetPath;

  final List<SongEntry> _songs = [];
  bool _loaded = false;

  @override
  String get sourceName => 'bundledSeed($_assetPath)';

  @override
  bool get isAvailable => _loaded && _songs.isNotEmpty;

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

  /// アセットJSONを非同期で読込。読込失敗時は空辞書として動作（isAvailable=false）。
  Future<void> load() async {
    try {
      final jsonString = await rootBundle.loadString(_assetPath);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final songsJson = json['songs'] as List<dynamic>?;

      _songs.clear();
      if (songsJson != null) {
        for (final songJson in songsJson) {
          try {
            final entry = SongEntry.fromJson(songJson as Map<String, dynamic>);
            _songs.add(entry);
          } catch (_) {
            // Bad行はスキップ（partial failure 許容）
          }
        }
      }

      // WHY: 同名異曲（同一 normalizedKey）が seed に複数件入ることがあるため、
      // normalizedKey 単独ソート（非安定）だと実行毎に先頭エントリが入れ替わり
      // findByNormalizedKey の結果が非決定的になる。id をタイブレークに加えて
      // 全順序を保証する（2026-11-22・実 seed で確認）。
      _songs.sort((a, b) {
        final byKey = a.normalizedKey.compareTo(b.normalizedKey);
        if (byKey != 0) {
          return byKey;
        }
        return a.id.compareTo(b.id);
      });
      _loaded = true;
    } catch (_) {
      _loaded = false;
    }
  }
}
