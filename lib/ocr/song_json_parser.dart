import 'dart:convert';

import 'package:scoreyomipm/ocr/song_entry.dart';

/// 曲 JSON をパースして [List<SongEntry>] に変換する。
///
/// bad row（id/title 欠如等）は [SongEntry.fromJson] が例外を投げるため、
/// スキップして partial failure を許容する。JSON 全体が壊れている場合や
/// `songs` キーが欠落・型違いの場合は caller 側で catch して空リストにする。
List<SongEntry> parseSongsJson(String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final songs = data['songs'] as List<dynamic>;
  return songs
      .whereType<Map<String, dynamic>>()
      .map((row) {
        try {
          return SongEntry.fromJson(row);
        } catch (_) {
          return null;
        }
      })
      .whereType<SongEntry>()
      .toList();
}
