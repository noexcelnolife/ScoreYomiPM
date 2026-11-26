// LiveSongTitleSearch（曲名入力のライブ辞書検索）の単体テスト（01a21152）。
//
// 検証観点:
// - 注入した配布辞書が優先され、辞書由来の候補が返る
// - 候補選択後のエントリ解決（resolve / v2 UX #15）が効く
// - invalidate() で辞書を作り直し、辞書の更新が次の検索から反映される

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/ui/song_title_live_search.dart';

/// allSongs の中身を後から差し替えられる SongRepository フェイク。
///
/// WHY: invalidate() 後に辞書が作り直されることを検証するため、同じ
/// リポジトリインスタンスの内容を差し替えてから再検索する。
class _SwappableSongRepository implements SongRepository {
  _SwappableSongRepository(this.songs);

  List<SongEntry> songs;

  @override
  String get sourceName => 'fakeSwappable';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => List<SongEntry>.unmodifiable(songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final SongEntry song in songs) {
      if (song.normalizedKey == normalizedKey) {
        return song;
      }
    }
    return null;
  }

  @override
  int get length => songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) {
    return findByNormalizedKey(normalizedKey) != null;
  }
}

SongEntry _entry(String id, String title) {
  return SongEntry(
    id: id,
    title: title,
    normalizedKey: normalizeSongTitle(title),
    notesCounts: <String, int>{'EX': 1000},
  );
}

void main() {
  test('注入した辞書から候補が返る（シードより優先）', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _SwappableSongRepository(<SongEntry>[
        _entry('a', 'テスト曲あ'),
        _entry('i', 'テスト曲い'),
      ]),
    );
    addTearDown(search.invalidate);

    final SongMatchResult? result = await search.search('テスト曲');

    expect(result, isNotNull);
    expect(
      result!.topCandidates.map((SongMatchCandidate c) => c.originalTitle),
      containsAll(<String>['テスト曲あ', 'テスト曲い']),
    );
    expect(result.autoDecided, isFalse, reason: '2 候補が同距離なら確定させず、チップを出させる');
  });

  test('正規化キーから曲エントリを解決できる（v2 UX #15）', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _SwappableSongRepository(<SongEntry>[
        _entry('a', 'テスト曲あ'),
      ]),
    );
    addTearDown(search.invalidate);

    final SongEntry? entry = await search.resolve(normalizeSongTitle('テスト曲あ'));

    expect(entry, isNotNull);
    expect(entry!.id, 'a');
    expect(await search.resolve(normalizeSongTitle('存在しない曲')), isNull);
  });

  test('invalidate() で辞書を作り直し、更新が次の検索へ反映される', () async {
    final _SwappableSongRepository repo = _SwappableSongRepository(<SongEntry>[
      _entry('a', 'テスト曲あ'),
    ]);
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: repo,
    );
    addTearDown(search.invalidate);

    expect(await search.resolve(normalizeSongTitle('テスト曲い')), isNull);

    repo.songs = <SongEntry>[_entry('a', 'テスト曲あ'), _entry('i', 'テスト曲い')];

    expect(
      await search.resolve(normalizeSongTitle('テスト曲い')),
      isNull,
      reason: 'invalidate 前は構築済み辞書（キャッシュ）を使うため見えない',
    );

    search.invalidate();

    expect(
      await search.resolve(normalizeSongTitle('テスト曲い')),
      isNotNull,
      reason: 'invalidate 後は辞書を作り直すため見える（#13-F の辞書更新原則）',
    );
  });
}
