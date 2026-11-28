import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';

/// `SongEntry` のリストから作る、同期の `SongRepository` 実装。
///
/// ローダーから生成した内容をメモリ上に保持し、ディスク I/O を伴わない。
/// `MergedSongRepository` のソースとして使われる。
class InMemorySongRepository implements SongRepository {
  InMemorySongRepository({
    required this.entries,
    this.sourceName = 'inMemory',
  });

  final List<SongEntry> entries;

  @override
  final String sourceName;

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => List.unmodifiable(entries);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    try {
      return entries.firstWhere((e) => e.normalizedKey == normalizedKey);
    } on StateError {
      return null;
    }
  }

  @override
  int get length => entries.length;

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      entries.any((e) => e.normalizedKey == normalizedKey);
}
