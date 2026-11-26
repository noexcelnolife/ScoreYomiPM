// 曲名検索画面（全件検索・複数候補）(01a211d6)。
//
// WHY この画面を独立させるか: スコア編集画面の曲名入力は「OCR 候補 3 件」を出す
// ライブサジェストで、辞書全体を引く入口が無かった。ユーザー要望「候補 3 件では
// 不足する」に対して、入力中の文字列からマージ辞書を全件引き、候補を一覧で選ぶ
// 画面を用意する。選択結果は [SongEntry] を pop の戻り値で返すだけにして、
// 呼び出し側（編集画面）が保存・リンクの責務を持つ。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ocr/song_entry.dart';
import 'difficulty_levels.dart';
import 'song_title_live_search.dart';

/// 曲名の全件検索画面。
class SongSearchScreen extends StatefulWidget {
  const SongSearchScreen({
    super.key,
    required this.search,
    this.initialQuery = '',
    this.initialSong,
  });

  /// クエリ（入力中の生文字列）を受け取り候補を返す検索関数。
  ///
  /// WHY 関数で受け取るか: 画面は辞書の生成元を知らないままにしておき、
  /// [LiveSongTitleSearch.searchWide] でもテスト用フェイクでも同じ画面を使える。
  final Future<List<SongEntry>> Function(String query) search;

  /// 入力欄の初期値（編集画面の入力中の文字列を引き継ぐ）。
  final String initialQuery;

  /// 現在リンク済みの曲。渡された場合は該当行にチェックを出す。
  final SongEntry? initialSong;

  /// 1 回の検索で受け取る件数の上限。
  ///
  /// WHY: 件数行の「上位 N 件」表示に使う。返却件数がこの値に達していれば、
  /// 呼び出し側の検索が上限で打ち切られている（=[LiveSongTitleSearch.searchWide]
  /// の既定 limit と同じ値）。
  static const int resultCap = LiveSongTitleSearch.wideSearchDefaultLimit;

  static Route<SongEntry> route({
    required Future<List<SongEntry>> Function(String query) search,
    String initialQuery = '',
    SongEntry? initialSong,
  }) {
    return MaterialPageRoute<SongEntry>(
      builder: (BuildContext context) => SongSearchScreen(
        search: search,
        initialQuery: initialQuery,
        initialSong: initialSong,
      ),
    );
  }

  @override
  State<SongSearchScreen> createState() => _SongSearchScreenState();
}

class _SongSearchScreenState extends State<SongSearchScreen> {
  static const ValueKey<String> _listKey = ValueKey<String>('song-search-list');
  static const ValueKey<String> _emptyKey = ValueKey<String>(
    'song-search-empty',
  );
  static const ValueKey<String> _countKey = ValueKey<String>(
    'song-search-count',
  );

  late final TextEditingController _controller;

  /// 直近に実行したクエリ（空なら入力待ちの案内を出す）。
  String _query = '';
  List<SongEntry> _results = const <SongEntry>[];
  bool _isSearching = false;

  /// 応答の世代。古い応答を破棄するために毎回インクリメントする。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    final String initial = widget.initialQuery.trim();
    if (initial.isEmpty) {
      return;
    }
    // WHY: 初期値が入っているなら、利用者が 1 文字打ち直さなくても候補を見せる。
    // initState では setState せずにフィールドを直接立てる。
    _query = initial;
    _isSearching = true;
    unawaited(_fetch(initial));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleChanged(String value) {
    final String query = value.trim();
    if (query.isEmpty) {
      _discardInFlight();
      return;
    }
    setState(() {
      _query = query;
      _isSearching = true;
    });
    unawaited(_fetch(query));
  }

  /// 入力が空になったら進行中の応答を捨て、入力待ちの案内へ戻す。
  void _discardInFlight() {
    _generation++;
    setState(() {
      _query = '';
      _results = const <SongEntry>[];
      _isSearching = false;
    });
  }

  /// 検索を 1 回実行し、最新世代のときだけ結果を反映する。
  Future<void> _fetch(String query) async {
    final int generation = ++_generation;
    List<SongEntry> results;
    try {
      results = await widget.search(query);
    } catch (_) {
      // WHY: 検索側の失敗で画面を落とさない。0 件表示に劣化させる
      // （[LiveSongTitleSearch.searchWide] は例外を投げない契約）。
      results = const <SongEntry>[];
    }
    // WHY 世代を比較する: 入力のたびに検索が走るため、遅い旧クエリの応答が
    // 後着すると新しい結果を上書きしてしまう。
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _results = results;
      _isSearching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('曲名を検索')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              key: const ValueKey<String>('song-search-field'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _handleChanged,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '曲名',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_isSearching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildResults(context)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_query.isEmpty) {
      return _buildMessage('曲名を入力してください', '漢字・かな・英字など、覚えている表記で検索できます');
    }
    // WHY 初回検索中は案内を出さない: まだ結果が返っていないだけなのに
    // 「該当する曲がありません」と出すと誤解になる（進捗は上部のバーで示す）。
    if (_results.isEmpty && _isSearching) {
      return const SizedBox.shrink();
    }
    if (_results.isEmpty) {
      return _buildMessage('該当する曲がありません', null, key: _emptyKey);
    }
    return Column(
      children: <Widget>[
        _buildCountRow(context),
        Expanded(
          child: ListView.builder(
            key: _listKey,
            itemCount: _results.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildTile(context, _results[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildCountRow(BuildContext context) {
    final int count = _results.length;
    final String text = count >= SongSearchScreen.resultCap
        ? '上位 $count 件'
        : '$count 件';
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(
          text,
          key: _countKey,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, SongEntry song) {
    final String? genreArtist = _describeGenreArtist(song);
    final String? levels = formatLevels(song.levels);
    final bool hasSubtitle = genreArtist != null || levels != null;
    final bool selected =
        widget.initialSong?.normalizedKey == song.normalizedKey;
    return ListTile(
      // 副題は最大 2 行。副題が無いときに isThreeLine を立てると assertion になる。
      isThreeLine: hasSubtitle,
      title: Text(song.title),
      subtitle: hasSubtitle
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (genreArtist != null) Text(genreArtist),
                if (levels != null) Text(levels),
              ],
            )
          : null,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => Navigator.of(context).pop(song),
    );
  }

  Widget _buildMessage(String title, String? description, {Key? key}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, key: key, textAlign: TextAlign.center),
            if (description != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(description, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  /// 副題 1 行目（ジャンル・アーティストのうち存在するものだけを「・」で連結）。
  ///
  /// レベルは 2 行目に [formatLevels] で 4 難易度すべてを出す（ユーザー指示
  /// 2026-11-25「EASY/NORMAL/HYPER/EX の 4 つを表示」）。1 行に詰めると
  /// 曲名・ジャンル・アーティストと合わせて折り返しが崩れるため行を分ける。
  static String? _describeGenreArtist(SongEntry song) {
    final List<String> parts = <String>[];
    final String? genre = song.genre;
    if (genre != null && genre.isNotEmpty) {
      parts.add(genre);
    }
    final String? artist = song.artist;
    if (artist != null && artist.isNotEmpty) {
      parts.add(artist);
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('・');
  }
}
