// LiveSongTitleSearch.searchWide（曲名の全件検索・tier 付き）の単体テスト（01a211d6）。
//
// 検証観点:
// - tier の順序（完全一致 → 前方一致 → 部分一致 → 編集距離）
// - 編集距離の段は距離・入力文字数で足切りしない（2026-11-25 ユーザー裁定）
// - 段階 3 の並びは「入力文字の被覆率（LCS÷クエリ長）」の降順
// - limit による打ち切り・空クエリ・辞書構築失敗の劣化（例外を投げない）
//
// 辞書は LiveSongTitleSearch が同梱シードもマージするため、期待値は
// 「候補集合に含まれること」「相対順序」で検証し、件数の絶対値には依存しない。

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/levenshtein.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/ui/song_title_live_search.dart';

/// 固定の allSongs を返す SongRepository フェイク。
class _FakeSongRepository implements SongRepository {
  _FakeSongRepository(this.songs);

  final List<SongEntry> songs;

  @override
  String get sourceName => 'fakeWide';

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

/// allSongs の参照で例外を投げる SongRepository フェイク。
///
/// WHY: MergedSongRepository はコンストラクタで各ソースの allSongs を走査する
/// ため、ここで投げると辞書構築そのものが失敗する経路を再現できる
/// （searchWide が例外を投げずに空リストへ劣化することを検証する）。
class _ThrowingSongRepository implements SongRepository {
  @override
  String get sourceName => 'fakeThrowing';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => throw StateError('辞書が壊れている');

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) => null;

  @override
  int get length => 0;

  @override
  bool containsNormalizedKey(String normalizedKey) => false;
}

SongEntry _entry(String id, String title) {
  return SongEntry(
    id: id,
    title: title,
    normalizedKey: normalizeSongTitle(title),
    notesCounts: const <String, int>{'EX': 1000},
  );
}

List<String> _keys(List<SongEntry> entries) {
  return entries.map((SongEntry e) => e.normalizedKey).toList();
}

void main() {
  test('完全一致した曲が先頭に来る', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('prefix', 'ゾンビランドサガ2'),
        _entry('partial', 'だいゾンビランドサガ'),
        _entry('exact', 'ゾンビランドサガ'),
      ]),
    );

    final List<SongEntry> results = await search.searchWide('ゾンビランドサガ');

    expect(results, isNotEmpty);
    expect(results.first.normalizedKey, normalizeSongTitle('ゾンビランドサガ'));
  });

  test('前方一致は部分一致より上位になる', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('partial', 'だいゾンビランドサガ'),
        _entry('prefix', 'ゾンビランドサガ2'),
      ]),
    );

    final List<String> keys = _keys(await search.searchWide('ゾンビランドサガ'));

    final int prefixIndex = keys.indexOf(normalizeSongTitle('ゾンビランドサガ2'));
    final int partialIndex = keys.indexOf(normalizeSongTitle('だいゾンビランドサガ'));
    expect(prefixIndex, isNonNegative);
    expect(partialIndex, isNonNegative);
    expect(prefixIndex, lessThan(partialIndex));
  });

  test('1 文字違いの曲名も拾える（編集距離ファジィ）', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('fuzzy', 'ネコパレード'),
      ]),
    );

    final List<String> keys = _keys(await search.searchWide('ネコパレイド'));

    // 前方一致・部分一致では届かない（'ネコパレード' は 'ネコパレイド' を
    // 含まない）ため、この一致は編集距離 1 のファジィ段のみで成立する。
    expect(keys, contains(normalizeSongTitle('ネコパレード')));
  });

  test('20 文字級の曲名でも数文字の一致で候補に入る（距離の足切りなし）', () async {
    // 18 文字の曲名に対し、利用者が打てたのは 3 文字（「ゾンガ」）だけという状況。
    const String title = 'ゾンビランドサガリベンジオブザデッド';
    const String query = 'ゾンガ';
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('long', title),
      ]),
    );

    final int distance = levenshteinDistance(
      normalizeSongTitle(query),
      normalizeSongTitle(title),
    );
    // WHY この assert を置くか: 「距離で足切りしない」前提そのものを固定する。
    // 旧仕様の「距離 4 以下」を再導入すると、この時点で確実に落ちる。
    expect(distance, greaterThanOrEqualTo(10));

    // 打ち切り（既定 200 件）を外し、順位に依存せず「候補に入っていること」を見る。
    final List<String> keys = _keys(
      await search.searchWide(query, limit: 100000),
    );

    expect(keys, contains(normalizeSongTitle(title)));
  });

  test('被覆率が高い曲名を絶対距離が小さい曲名より上位に置く', () async {
    // 入力「ゾンガ」に対し:
    //   'ガゾン'  … 3 文字中 2 文字一致（距離 2）だが被覆率 2/3
    //   'ゾンビ…' … 3 文字すべて一致（距離 15 前後）だが被覆率 3/3
    const String exactCoverage = 'ゾンビランドサガリベンジオブザデッド';
    const String nearDistance = 'ガゾン';
    const String query = 'ゾンガ';
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('near', nearDistance),
        _entry('cover', exactCoverage),
      ]),
    );

    final int distanceNear = levenshteinDistance(
      normalizeSongTitle(query),
      normalizeSongTitle(nearDistance),
    );
    final int distanceCover = levenshteinDistance(
      normalizeSongTitle(query),
      normalizeSongTitle(exactCoverage),
    );
    // 距離だけを見ると 'ガゾン' が勝つ。並びがこれと逆になることを確かめる。
    expect(distanceNear, lessThan(distanceCover));

    final List<String> keys = _keys(
      await search.searchWide(query, limit: 100000),
    );

    final int coverIndex = keys.indexOf(normalizeSongTitle(exactCoverage));
    final int nearIndex = keys.indexOf(normalizeSongTitle(nearDistance));
    expect(coverIndex, isNonNegative);
    expect(nearIndex, isNonNegative);
    expect(coverIndex, lessThan(nearIndex));
  });

  test('同じ入力で 2 回呼ぶと同じ順序になる（決定的）', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('a', 'ゾンビランドサガ'),
        _entry('b', 'ガゾン'),
        _entry('c', 'ゾンガ'),
      ]),
    );

    final List<String> first = _keys(
      await search.searchWide('ゾンガ', limit: 100000),
    );
    final List<String> second = _keys(
      await search.searchWide('ゾンガ', limit: 100000),
    );

    expect(second, first);
  });

  test('2 文字クエリでも段階 3 が返る（入力文字数の下限なし）', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('short', 'メル'),
      ]),
    );

    // WHY: 旧仕様の「入力 3 文字以上」を再導入すると 'メル' が候補から消えて落ちる。
    final List<String> keys = _keys(
      await search.searchWide('モル', limit: 100000),
    );

    expect(keys, contains(normalizeSongTitle('メル')));
  });

  test('limit で打ち切る', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('a', 'テスト曲0'),
        _entry('b', 'テスト曲1'),
        _entry('c', 'テスト曲2'),
        _entry('d', 'テスト曲3'),
        _entry('e', 'テスト曲4'),
      ]),
    );

    final List<SongEntry> results = await search.searchWide('テスト曲', limit: 2);

    expect(results, hasLength(2));
    expect(_keys(results), <String>[
      normalizeSongTitle('テスト曲0'),
      normalizeSongTitle('テスト曲1'),
    ]);
  });

  test('空クエリは空リストを返す', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _FakeSongRepository(<SongEntry>[
        _entry('a', 'テスト曲あ'),
      ]),
    );

    expect(await search.searchWide(''), isEmpty);
    expect(await search.searchWide('   '), isEmpty);
  });

  test('辞書の構築に失敗しても例外を投げない', () async {
    final LiveSongTitleSearch search = LiveSongTitleSearch(
      mainSongRepository: _ThrowingSongRepository(),
    );

    // 例外が漏れるとテストがそのまま失敗する（expect は正常終了の確認）。
    final List<SongEntry> results = await search.searchWide('テスト曲');

    expect(results, isEmpty);
  });
}
