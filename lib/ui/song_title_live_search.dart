// 曲名入力のライブ辞書検索（シード＋配布辞書＋追加辞書のマージ辞書）。
//
// WHY(切り出し・01a21152): 「辞書をマージしてキャッシュし、曲名照合と曲エントリ
// 解決に使う」処理は HomeScreen の private メソッドに閉じていた。ユーザー要望
// 「スコア修正の時にも曲名DBをもとに曲名サジェストしてください」により記録詳細
// 画面（修正・再OCR）と手入力経路でも同じ検索が必要になったため、1 箇所に
// 集約して全入口から使い回す。

import '../ocr/bundled_seed_repository.dart';
import '../ocr/levenshtein.dart';
import '../ocr/merged_song_repository.dart';
import '../ocr/blob_store_song_repository_loader.dart';
import '../ocr/song_entry.dart';
import '../ocr/song_repository.dart';
import '../ocr/song_title_matcher.dart';
import '../ocr/song_title_normalizer.dart';

/// 曲名入力欄のライブサジェスト用の辞書検索。
///
/// 辞書の構築は JSON の読み込みとマージを伴うため、キー入力ごとには行わず
/// 初回検索時に 1 度だけ構築してキャッシュする（構築中の多重呼び出しも
/// 同じ Future を共有する）。辞書が更新されたら [invalidate] で捨て、
/// 次の検索で作り直させる。
class LiveSongTitleSearch {
  /// [mainSongRepository] は配布辞書、[additionalSongRepository] は追加辞書。
  /// どちらも未指定ならシード（同梱辞書）だけで検索する。
  LiveSongTitleSearch({this.mainSongRepository, this.additionalSongRepository});

  /// 配布辞書（任意）。
  final SongRepository? mainSongRepository;

  /// 追加辞書（任意）。
  final SongRepository? additionalSongRepository;

  /// [searchWide] の既定の返却上限（曲名検索画面の件数表示と共有する）。
  static const int wideSearchDefaultLimit = 200;

  Future<SongTitleMatcher?>? _matcherFuture;
  Future<MergedSongRepository?>? _repositoryFuture;
  Future<int?>? _seedCountFuture;

  /// [title] を辞書と照合する。辞書を用意できなければ null。
  Future<SongMatchResult?> search(String title) async {
    final SongTitleMatcher? matcher = await _ensureMatcher();
    return matcher?.match(title);
  }

  /// 正規化済み曲名 [normalizedTitle] から曲エントリを引く。見つからなければ null。
  ///
  /// WHY(v2 UX #15): [SongMatchCandidate] は曲エントリ（DB の総ノーツ等）を
  /// 持たないため、候補選択後はこの解決結果を別経路で受け取る必要がある。
  Future<SongEntry?> resolve(String normalizedTitle) async {
    final MergedSongRepository? repository = await _ensureRepository();
    return repository?.findByNormalizedKey(normalizedTitle);
  }

  /// マージ辞書を全件引いて、複数候補を段階付きで返す（曲名検索画面用）。
  ///
  /// WHY: [search] は OCR 結果 1 件に対する最有力候補の照合で、候補は 3 件までに
  /// 絞られる。ユーザー要望「候補 3 件では不足する」に対して、入力中の文字列から
  /// 辞書全体を引き、完全一致 → 前方一致 → 部分一致 → それ以外の順に並べて返す。
  ///
  /// 並び順は段階 → 入力文字の被覆率（降順）→ 編集距離 → 正規化キーの昇順
  /// （同点でも順序が決まる）。
  ///
  /// WHY 段階 3 に距離の足切りを置かない（2026-11-25 ユーザー裁定）:
  /// 「使用文字・読みなどが難解な楽曲が多く、長文（20 文字近く）の曲名に対して
  /// ユーザーが理解でき入力できる文字が数文字ということが十分あり得る」ため、
  /// 距離で候補を落とすと目的の曲に到達できない。同じ理由で入力文字数の下限も置かない。
  ///
  /// WHY 段階 3 を「入力文字の被覆率」で並べる: 絶対距離でも
  /// 長さで正規化した距離でも、曲名が長いほど不利になる。ユーザーが長い曲名の
  /// 一部の文字しか入力できない場面では「入力した文字がその曲名にどれだけ現れるか」が
  /// 手掛かりになるため、LCS の長さをクエリ長で割った値の降順で並べる。
  ///
  /// 辞書を構築できなかったときは空リストを返す（[search] と同じ劣化方針）。
  Future<List<SongEntry>> searchWide(
    String query, {
    int limit = wideSearchDefaultLimit,
  }) async {
    final String q = normalizeSongTitle(query);
    if (q.isEmpty || limit <= 0) {
      return const <SongEntry>[];
    }
    final MergedSongRepository? repository = await _ensureRepository();
    if (repository == null) {
      return const <SongEntry>[];
    }
    final List<_WideHit> hits = <_WideHit>[];
    final Set<String> seen = <String>{};
    for (final SongEntry song in repository.allSongs) {
      // マージ辞書は正規化キーで一意だが、ソース側の重複に備えて明示的に畳む。
      if (!seen.add(song.normalizedKey)) {
        continue;
      }
      final int distance = levenshteinDistance(q, song.normalizedKey);
      hits.add(
        _WideHit(
          tier: _tierOf(q, song.normalizedKey),
          coverage: _lcsLength(q, song.normalizedKey) / q.length,
          distance: distance,
          song: song,
        ),
      );
    }
    hits.sort(_WideHit.compare);
    final int take = hits.length < limit ? hits.length : limit;
    return <SongEntry>[for (int i = 0; i < take; i++) hits[i].song];
  }

  /// 最長共通部分列の長さ（文字の並び順を保ったまま一致する最大文字数）。
  ///
  /// WHY 部分列か: ユーザーが長い曲名の一部の文字しか入力できない場合、その文字は
  /// 曲名の中で連続しているとは限らない（例「ゾンガ」→「ゾンビランドサガ」）。
  /// 時間 O(m·n)・空間 O(min(m,n))。曲名は数十文字なので 1 曲あたりの負荷は小さい。
  static int _lcsLength(String a, String b) {
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    final bool aIsShorter = a.length <= b.length;
    final String shorter = aIsShorter ? a : b;
    final String longer = aIsShorter ? b : a;
    final List<int> previous = List<int>.filled(shorter.length + 1, 0);
    final List<int> current = List<int>.filled(shorter.length + 1, 0);
    for (int i = 1; i <= longer.length; i++) {
      for (int j = 1; j <= shorter.length; j++) {
        current[j] = longer[i - 1] == shorter[j - 1]
            ? previous[j - 1] + 1
            : (previous[j] > current[j - 1] ? previous[j] : current[j - 1]);
      }
      for (int j = 0; j <= shorter.length; j++) {
        previous[j] = current[j];
      }
    }
    return previous[shorter.length];
  }

  /// 一致の段階（0: 完全一致 / 1: 前方一致 / 2: 部分一致 / 3: それ以外）。
  ///
  /// 段階 3 が落ちる（null を返す）ことはない。距離や入力文字数で足切りすると
  /// 難解な長い曲名に到達できなくなるため（[searchWide] の WHY を参照）。
  static int _tierOf(String query, String key) {
    if (key == query) {
      return 0;
    }
    if (key.startsWith(query)) {
      return 1;
    }
    if (key.contains(query)) {
      return 2;
    }
    return 3;
  }

  /// マージ辞書の総曲数（正規化キーで重複排除済み）。
  ///
  /// WHY(案A): 収録曲辞書のタイトル行に常時「サジェスト対象の曲数」を出すため、
  /// シード＋配布＋追加をマージした実際の検索母数を返す（単純合計ではない）。
  /// 辞書を作れなかったときは 0 を返し、表示側で「—」に倒す。
  Future<int> totalSongCount() async {
    final MergedSongRepository? repository = await _ensureRepository();
    return repository?.length ?? 0;
  }

  /// 内蔵シード辞書の曲数。読み込めなければ null。
  ///
  /// WHY(案A): 内訳行「内蔵シード 33曲」用。シードは同梱で内容が変わらないため
  /// [invalidate] では捨てない（辞書更新のたびに JSON を読み直さない）。
  Future<int?> seedSongCount() => _seedCountFuture ??= _loadSeedCount();

  Future<int?> _loadSeedCount() async {
    try {
      final BundledSeedRepository seed = BundledSeedRepository();
      await seed.load();
      return seed.length;
    } catch (_) {
      // WHY: 失敗を握り潰さず、次の呼び出しで読み直せるようキャッシュを戻す。
      _seedCountFuture = null;
      return null;
    }
  }

  /// キャッシュを捨てる。次の検索で辞書を作り直す。
  ///
  /// WHY(#13-F): OCR 実行のたびに辞書を組み直す pipeline と歩調を合わせる。
  /// ここで捨てないと、辞書を更新してもライブ検索だけ古い内容を使い続け、
  /// OCR 経路とライブ検索経路で候補が食い違う。
  void invalidate() {
    _matcherFuture = null;
    _repositoryFuture = null;
  }

  Future<SongTitleMatcher?> _ensureMatcher() {
    return _matcherFuture ??= _buildMatcher();
  }

  Future<SongTitleMatcher?> _buildMatcher() async {
    final MergedSongRepository? repository = await _ensureRepository();
    if (repository == null) {
      // WHY: 失敗を握り潰さず次の入力を再試行できるよう、キャッシュを戻す。
      _matcherFuture = null;
      return null;
    }
    return SongTitleMatcher(repository);
  }

  Future<MergedSongRepository?> _ensureRepository() {
    return _repositoryFuture ??= _loadRepository();
  }

  Future<MergedSongRepository?> _loadRepository() async {
    try {
      final BundledSeedRepository seed = BundledSeedRepository();
      await seed.load();
      // 優先順は pipeline.dart と同じ（追加辞書 → 配布辞書 → シード）。
      final List<SongRepository> sources = <SongRepository>[
        ?additionalSongRepository,
        ?mainSongRepository,
        seed,
      ];
    return MergedSongRepository(sources: sources, loaders: const <BlobStoreSongRepositoryLoader>[]);
    } catch (_) {
      // WHY: 辞書が壊れていても入力・保存は続けられるようにする（劣化は
      // 「サジェストが出ない」だけに留める）。失敗はキャッシュせず、
      // 次の入力で読み直す。
      _repositoryFuture = null;
      return null;
    }
  }
}

/// [LiveSongTitleSearch.searchWide] の 1 候補（段階・被覆率・距離を並べ替え用に保持する）。
class _WideHit {
  const _WideHit({
    required this.tier,
    required this.coverage,
    required this.distance,
    required this.song,
  });

  final int tier;

  /// 入力文字が曲名にどれだけ現れるか（LCS の長さ ÷ クエリ長・0.0〜1.0）。
  final double coverage;
  final int distance;
  final SongEntry song;

  /// 段階 → 被覆率（降順）→ 距離 → 正規化キーの昇順。同点でも順序が決まるようにする。
  static int compare(_WideHit a, _WideHit b) {
    if (a.tier != b.tier) {
      return a.tier.compareTo(b.tier);
    }
    final int byCoverage = b.coverage.compareTo(a.coverage);
    if (byCoverage != 0) {
      return byCoverage;
    }
    if (a.distance != b.distance) {
      return a.distance.compareTo(b.distance);
    }
    return a.song.normalizedKey.compareTo(b.song.normalizedKey);
  }
}
