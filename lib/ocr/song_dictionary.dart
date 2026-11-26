// ST-6 楽曲辞書リポジトリ（SongRepository へ移行）
//
// spec.md §10: SongDictionary は SongRepository 抽象へ差し替え。
// 後方互換のため SongDictionary クラスは非推奨ラッパーとして残置。
// 新規コードは SongRepository / MergedSongRepository / BundledSeedRepository を使用。

import 'dart:io';

import 'song_repository.dart';
import 'song_title_normalizer.dart';

// ============================================================================
// SongDictionary（非推奨ラッパー：SongRepository へ移行予定）
// ============================================================================

/// 曲名辞書のインターフェース（非推奨）。
///
/// 新規実装は [SongRepository] を使用。本クラスは既存コードとの互換のため
/// 暫定的に残置。
@Deprecated('Use SongRepository instead')
abstract class SongDictionary {
  List<String> get titles;
  String? originalTitle(String normalizedTitle);
  bool contains(String title);
  int get length;
}

/// GT CSV (docs/ground_truth_template.csv) からシード辞書を構築する。
///
/// CSV 第4列（0-indexed: index 3）が曲名。
/// 空欄の行はスキップする。
@Deprecated('Use BundledSeedRepository or MergedSongRepository instead')
class GtCsvSongDictionary implements SongDictionary {
  final Map<String, String> _normalizedToOriginal = {};
  final List<String> _titles = [];

  GtCsvSongDictionary(String csvPath) {
    final lines = File(csvPath).readAsLinesSync();
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final cols = line.split(',');
      if (cols.length < 4) continue;
      final title = cols[3].trim();
      if (title.isEmpty) continue;
      final normalized = normalizeSongTitle(title);
      if (normalized.isEmpty) continue;
      _normalizedToOriginal[normalized] = title;
      if (!_titles.contains(normalized)) {
        _titles.add(normalized);
      }
    }
  }

  @override
  List<String> get titles => List.unmodifiable(_titles);

  @override
  String? originalTitle(String normalizedTitle) =>
      _normalizedToOriginal[normalizedTitle];

  @override
  bool contains(String title) => _normalizedToOriginal.containsKey(title);

  @override
  int get length => _titles.length;
}

/// メモリ上の固定辞書（テスト用・開発用シード）
@Deprecated('Use Static song entries via MergedSongRepository instead')
class StaticSongDictionary implements SongDictionary {
  final Map<String, String> _normalizedToOriginal = {};
  final List<String> _titles = [];

  StaticSongDictionary(List<String> titles) {
    for (final title in titles) {
      final normalized = normalizeSongTitle(title);
      if (normalized.isEmpty) continue;
      _normalizedToOriginal[normalized] = title;
      if (!_titles.contains(normalized)) {
        _titles.add(normalized);
      }
    }
  }

  @override
  List<String> get titles => List.unmodifiable(_titles);

  @override
  String? originalTitle(String normalizedTitle) =>
      _normalizedToOriginal[normalizedTitle];

  @override
  bool contains(String title) => _normalizedToOriginal.containsKey(title);

  @override
  int get length => _titles.length;
}
