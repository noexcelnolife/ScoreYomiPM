// 曲名検索画面への導線（2026-11-25 ユーザー要望）のウィジェットテスト。
//
// 検証対象:
// (a) onSongSearchWide を渡したときだけ曲名欄に虫めがねを出す（後方互換）
// (b) 虫めがねで全件検索画面が開き、現在の入力が検索語として引き継がれる
// (c) 検索結果を選ぶと曲名欄がその曲名になり、選択曲がリンクとして残る
// (d) 戻る（選択なし）では曲名欄が変わらない
// (e) ライブ候補が並んでいる行に「もっと探す」が出て、同じ画面へ行ける

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/song_search_screen.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

SongEntry _song(
  String title, {
  int notes = 1234,
  Map<String, int> levels = const <String, int>{},
}) {
  return SongEntry(
    id: 'id-$title',
    title: title,
    normalizedKey: normalizeSongTitle(title),
    levels: levels,
    notesCounts: <String, int>{'EX': notes},
  );
}

/// 4 難易度そろった曲（ダイアログの 4 行を確認する用）。
const Map<String, int> _fourLevels = <String, int>{
  'LIGHT': 6,
  'NORMAL': 21,
  'HYPER': 29,
  'EX': 31,
};

/// 難易度・レベル選択ダイアログ。
final Finder _levelPicker = find.byKey(
  const ValueKey<String>('song-level-picker'),
);

/// レベル欄（数値フィールド）。
final Finder _levelField = find.byKey(
  const ValueKey<String>('field-input-level'),
);

/// 難易度チップが選択状態か。
bool _difficultySelected(WidgetTester tester, String name) {
  return tester
      .widget<ChoiceChip>(find.byKey(ValueKey<String>('difficulty-chip-$name')))
      .selected;
}

/// 曲名欄の虫めがね（`onSongSearchWide` を渡したときだけ出る）。
final Finder _searchButton = find.byKey(
  const ValueKey<String>('song-name-search-button'),
);

/// 全件検索画面の検索語入力欄。
final Finder _searchField = find.byKey(
  const ValueKey<String>('song-search-field'),
);

/// ライブ候補（autoDecided=false）を 2 件返す照合結果。
SongMatchResult _twoCandidates() {
  return SongMatchResult(
    rawOcrText: 'manual input',
    normalizedOcrText: 'manual input',
    bestMatchNormalized: 'ろんどんすうぃーと',
    bestMatchOriginal: 'ロンドン☆スウィート',
    bestDistance: 1,
    topCandidates: <SongMatchCandidate>[
      SongMatchCandidate(
        normalizedTitle: 'ろんどんすうぃーと',
        originalTitle: 'ロンドン☆スウィート',
        distance: 1,
      ),
      SongMatchCandidate(
        normalizedTitle: 'ろんどんばす',
        originalTitle: 'ロンドンバス',
        distance: 2,
      ),
    ],
    autoDecided: false,
  );
}

void main() {
  testWidgets('onSongSearchWide を渡さないときは虫めがねを出さない（後方互換）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_searchButton, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('song-search-more-button')),
      findsNothing,
    );
  });

  testWidgets('虫めがねで検索画面が開き、現在の入力が初期の検索語になる', (WidgetTester tester) async {
    final List<String> queries = <String>[];
    Future<List<SongEntry>> search(String query) async {
      queries.add(query);
      return <SongEntry>[_song('ロンドン☆スウィート')];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();

    expect(find.byType(SongSearchScreen), findsOneWidget);
    expect(tester.widget<TextField>(_searchField).controller!.text, 'ろんどん');
    // 初期語でも検索が走る（空の一覧を出さない）。
    expect(queries, contains('ろんどん'));
  });

  testWidgets('検索結果を選ぶと曲名欄がその曲名になり、選択曲がリンクとして残る', (WidgetTester tester) async {
    const String title = 'ロンドン☆スウィート';
    Future<List<SongEntry>> search(String query) async {
      return <SongEntry>[_song(title, levels: _fourLevels)];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();

    // 曲名確定後は難易度・レベル選択ダイアログが重なる。このテストの関心は
    // 曲名欄とリンクの状態だけなので「自動入力しない」で閉じる（意味は変えない）。
    await tester.tap(find.byKey(const ValueKey<String>('song-level-skip')));
    await tester.pumpAndSettle();

    // 曲名欄へ反映される。
    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(field.controller!.text, title);

    // 選択曲がリンクとして残っていることを、検索画面の「選択中」表示で確認する
    // （WHY: _selectedMatchedSong は総ノーツ数の源になる内部状態で、画面からは
    // 検索画面の check アイコンとして観測できる）。
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('検索画面から戻るだけなら曲名欄は変わらない', (WidgetTester tester) async {
    Future<List<SongEntry>> search(String query) async {
      return <SongEntry>[_song('ロンドン☆スウィート')];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(field.controller!.text, 'ろんどん');
  });

  testWidgets('ライブ候補があれば「もっと探す」から同じ検索画面へ行ける', (WidgetTester tester) async {
    Future<SongMatchResult?> liveSearch(String title) async => _twoCandidates();
    Future<List<SongEntry>> wideSearch(String query) async {
      return <SongEntry>[_song('ロンドン☆スウィート')];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongTitleSearch: liveSearch,
          onSongSearchWide: wideSearch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();

    final Finder more = find.byKey(
      const ValueKey<String>('song-search-more-button'),
    );
    expect(more, findsOneWidget);

    // WHY ensureVisible: 2026-11-26 に画像プレビューを画面先頭へ移し、高さも
    // 240 にそろえたため、フィールドセクションの下端は 600px の画面外へ出る。
    // 実際の利用でもスクロールしてから押す操作になる。
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.byType(SongSearchScreen), findsOneWidget);
    expect(tester.widget<TextField>(_searchField).controller!.text, 'ろんどん');
  });

  testWidgets('検索画面から曲を選ぶと難易度・レベル選択ダイアログが出て、選ぶと反映される', (
    WidgetTester tester,
  ) async {
    const String title = 'ロンドン☆スウィート';
    Future<List<SongEntry>> search(String query) async {
      return <SongEntry>[_song(title, levels: _fourLevels)];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();

    // 曲名確定 → 曲名DBの登録内容が選択肢として出る。
    expect(_levelPicker, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('song-level-option-ex')),
    );
    await tester.pumpAndSettle();

    expect(_levelPicker, findsNothing);
    expect(tester.widget<TextField>(_levelField).controller!.text, '31');
    expect(_difficultySelected(tester, 'ex'), isTrue);
  });

  testWidgets('「自動入力しない」では既存の難易度・レベルを変えない', (WidgetTester tester) async {
    const String title = 'ロンドン☆スウィート';
    Future<List<SongEntry>> search(String query) async {
      return <SongEntry>[_song(title, levels: _fourLevels)];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 事前に手入力しておく（自動入力がここを壊さないことの回帰）。
    await tester.enterText(_levelField, '15');
    await tester.tap(
      find.byKey(const ValueKey<String>('difficulty-chip-hyper')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(_levelPicker, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('song-level-skip')));
    await tester.pumpAndSettle();

    expect(_levelPicker, findsNothing);
    expect(tester.widget<TextField>(_levelField).controller!.text, '15');
    expect(_difficultySelected(tester, 'hyper'), isTrue);
    expect(_difficultySelected(tester, 'ex'), isFalse);
  });

  testWidgets('levels が空の曲ではダイアログを出さない', (WidgetTester tester) async {
    const String title = 'ロンドン☆スウィート';
    Future<List<SongEntry>> search(String query) async {
      return <SongEntry>[_song(title)];
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongSearchWide: search,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();
    await tester.tap(_searchButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();

    expect(_levelPicker, findsNothing);
    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('field-input-songName')),
    );
    expect(field.controller!.text, title);
  });

  testWidgets('候補チップのタップでも同じダイアログが出て反映される', (WidgetTester tester) async {
    Future<SongMatchResult?> liveSearch(String title) async => _twoCandidates();
    Future<SongEntry?> resolve(String normalizedTitle) async {
      return _song('ロンドン☆スウィート', levels: _fourLevels);
    }

    await tester.pumpWidget(
      _wrap(
        OcrResultScreen(
          imageFile: File('dummy.png'),
          pageResult: null,
          extractionResult: null,
          onSongTitleSearch: liveSearch,
          onSongEntryResolve: resolve,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('field-input-songName')),
      'ろんどん',
    );
    await tester.pumpAndSettle();

    // WHY ensureVisible: 画像プレビューが先頭に来たぶん候補チップが画面外へ出る
    // （2026-11-26 の並び替え）。実機でもスクロールしてから押す操作になる。
    await tester.ensureVisible(find.text('ロンドン☆スウィート'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ロンドン☆スウィート'));
    await tester.pumpAndSettle();

    expect(_levelPicker, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('song-level-option-normal')),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_levelField).controller!.text, '21');
    expect(_difficultySelected(tester, 'normal'), isTrue);
  });
}
