// SongSearchScreen（曲名の全件検索画面）のウィジェットテスト（01a211d6）。
//
// 検証観点:
// - クエリ空の案内・検索中インジケータ・0 件表示・件数行・一覧描画
// - 行タップで SongEntry を返して閉じる（Navigator.pop の戻り値）
// - 世代カウンタにより、古い検索応答が新しい結果を上書きしない

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/ui/difficulty_levels.dart';
import 'package:scoreyomipm/ui/song_search_screen.dart';

SongEntry _entry(
  String id,
  String title, {
  String? genre,
  String? artist,
  Map<String, int> levels = const <String, int>{},
}) {
  return SongEntry(
    id: id,
    title: title,
    normalizedKey: normalizeSongTitle(title),
    genre: genre,
    artist: artist,
    levels: levels,
  );
}

/// 1 回だけ成功する固定検索。呼び出し回数を数えられるようにしておく。
Future<List<SongEntry>> Function(String) _fixedSearch(List<SongEntry> results) {
  return (String query) async => results;
}

const ValueKey<String> _fieldKey = ValueKey<String>('song-search-field');
const ValueKey<String> _emptyKey = ValueKey<String>('song-search-empty');
const ValueKey<String> _countKey = ValueKey<String>('song-search-count');
const ValueKey<String> _listKey = ValueKey<String>('song-search-list');

void main() {
  testWidgets('初期描画ではクエリ空の案内を出す', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(search: _fixedSearch(const <SongEntry>[])),
      ),
    );

    expect(find.text('曲名を入力してください'), findsOneWidget);
    expect(find.text('漢字・かな・英字など、覚えている表記で検索できます'), findsOneWidget);
    expect(find.byKey(_listKey), findsNothing);
    expect(find.byKey(_emptyKey), findsNothing);
  });

  testWidgets('入力すると結果一覧と件数が出る', (WidgetTester tester) async {
    final List<SongEntry> results = <SongEntry>[
      _entry(
        'a',
        'テスト曲あ',
        genre: 'ポップス',
        artist: 'アーティストA',
        levels: const <String, int>{'EX': 42},
      ),
      _entry('i', 'テスト曲い'),
    ];
    await tester.pumpWidget(
      MaterialApp(home: SongSearchScreen(search: _fixedSearch(results))),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(find.byKey(_countKey), findsOneWidget);
    expect(find.text('2 件'), findsOneWidget);
    expect(find.byKey(_listKey), findsOneWidget);
    expect(find.text('テスト曲あ'), findsOneWidget);
    expect(find.text('テスト曲い'), findsOneWidget);
    // 副題は 2 行: 1 行目が genre/artist、2 行目がレベル（4 難易度すべて）。
    expect(find.text('ポップス・アーティストA'), findsOneWidget);
    expect(find.text('Lv.EX 42'), findsOneWidget);
  });

  testWidgets('副題の 2 行目に 4 難易度すべてを低→高の順で出す', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(
          search: _fixedSearch(<SongEntry>[
            _entry(
              'a',
              'テスト曲あ',
              genre: 'ポップス',
              artist: 'アーティストA',
              // 入力順をわざと崩し、表示順が実装側で決まることを確かめる。
              levels: const <String, int>{
                'EX': 31,
                'LIGHT': 6,
                'NORMAL': 21,
                'HYPER': 29,
              },
            ),
          ]),
        ),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(
      find.text('Lv.LIGHT 6・Lv.NORMAL 21・Lv.HYPER 29・Lv.EX 31'),
      findsOneWidget,
    );
  });

  testWidgets('存在する難易度だけを出す（欠けている EX は出さない）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(
          search: _fixedSearch(<SongEntry>[
            _entry(
              'a',
              'テスト曲あ',
              levels: const <String, int>{'NORMAL': 21, 'HYPER': 29},
            ),
          ]),
        ),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(find.text('Lv.NORMAL 21・Lv.HYPER 29'), findsOneWidget);
    expect(find.textContaining('Lv.EX '), findsNothing);
    expect(find.textContaining('Lv.LIGHT '), findsNothing);
  });

  testWidgets('levels が空なら副題は genre/artist のみ', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(
          search: _fixedSearch(<SongEntry>[
            _entry('a', 'テスト曲あ', genre: 'ポップス', artist: 'アーティストA'),
          ]),
        ),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(find.text('ポップス・アーティストA'), findsOneWidget);
    expect(find.textContaining('Lv.'), findsNothing);
  });

  testWidgets('genre/artist/levels がすべて空でも落ちない', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(
          search: _fixedSearch(<SongEntry>[_entry('a', 'テスト曲あ')]),
        ),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(find.text('テスト曲あ'), findsOneWidget);
    // 副題が無い ListTile で isThreeLine を立てると assertion になるため、
    // ここが null でないことが「クラッシュしない」の確認になる。
    expect(tester.takeException(), isNull);
  });

  testWidgets('0 件なら該当なしの案内を出す', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(search: _fixedSearch(const <SongEntry>[])),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'ぬぬぬ');
    await tester.pumpAndSettle();

    expect(find.byKey(_emptyKey), findsOneWidget);
    expect(find.byKey(_listKey), findsNothing);
  });

  testWidgets('検索中はインジケータを出す', (WidgetTester tester) async {
    final Completer<List<SongEntry>> completer = Completer<List<SongEntry>>();
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(search: (String query) => completer.future),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    completer.complete(const <SongEntry>[]);
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('行をタップすると SongEntry を返して閉じる', (WidgetTester tester) async {
    final SongEntry song = _entry('a', 'テスト曲あ');
    SongEntry? returned;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return TextButton(
              onPressed: () async {
                returned = await Navigator.of(context).push(
                  SongSearchScreen.route(
                    search: _fixedSearch(<SongEntry>[song]),
                  ),
                );
              },
              child: const Text('開く'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト曲あ'));
    await tester.pumpAndSettle();

    expect(returned, isNotNull);
    expect(returned?.id, 'a');
    expect(find.byKey(_fieldKey), findsNothing);
  });

  testWidgets('選択中の曲には check アイコンを出す', (WidgetTester tester) async {
    final SongEntry song = _entry('a', 'テスト曲あ');
    await tester.pumpWidget(
      MaterialApp(
        home: SongSearchScreen(
          search: _fixedSearch(<SongEntry>[song]),
          initialSong: _entry('a', 'テスト曲あ'),
        ),
      ),
    );

    await tester.enterText(find.byKey(_fieldKey), 'テスト');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('古い応答が後着しても新しい結果を上書きしない', (WidgetTester tester) async {
    final Map<String, Completer<List<SongEntry>>> pending =
        <String, Completer<List<SongEntry>>>{};
    Future<List<SongEntry>> search(String query) {
      final Completer<List<SongEntry>> completer = Completer<List<SongEntry>>();
      pending[query] = completer;
      return completer.future;
    }

    await tester.pumpWidget(
      MaterialApp(home: SongSearchScreen(search: search)),
    );

    await tester.enterText(find.byKey(_fieldKey), '旧');
    await tester.pump();
    await tester.enterText(find.byKey(_fieldKey), '新');
    await tester.pump();

    // 新しいクエリが先に返る。
    pending['新']!.complete(<SongEntry>[_entry('new', '新しい曲')]);
    await tester.pumpAndSettle();
    // その後に古いクエリが返る（世代カウンタで破棄されるべき）。
    pending['旧']!.complete(<SongEntry>[_entry('old', '古い曲')]);
    await tester.pumpAndSettle();

    expect(find.text('新しい曲'), findsOneWidget);
    expect(find.text('古い曲'), findsNothing);
  });

  group('formatLevels', () {
    test('表示順（LIGHT→NORMAL→HYPER→EX）に並べ、未知キーは無視する', () {
      // UPPER は現行の DB・enum に存在しないキー。順序が未定義なので出さない。
      expect(
        formatLevels(<String, int>{'EX': 31, 'UPPER': 50, 'LIGHT': 6}),
        'Lv.LIGHT 6・Lv.EX 31',
      );
    });

    test('該当する難易度が無ければ null', () {
      expect(formatLevels(const <String, int>{}), isNull);
      expect(formatLevels(const <String, int>{'UPPER': 50}), isNull);
    });
  });
}
