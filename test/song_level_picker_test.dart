// 曲名確定時の難易度・レベル選択ダイアログ（2026-11-25 ユーザー指示）のテスト。
//
// 検証対象:
// (a) 曲名DBに登録されている難易度だけを LIGHT→NORMAL→HYPER→EX の順で出す
// (b) 選んだ難易度とレベルが SongLevelChoice として返る
// (c) 「自動入力しない」は null（＝呼び出し側は何も変えない）
// (d) 外側タップ・戻るも null
// (e) 登録が無い曲・未知キーだけの曲ではダイアログを出さず null
// (f) 各行が難易度色（difficulty_color.dart の単一真実源）で着色される

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ui/difficulty_color.dart';
import 'package:scoreyomipm/ui/song_level_picker.dart';

/// ダイアログを開くだけのホスト。戻り値は外へ流す。
class _Host extends StatelessWidget {
  const _Host(this.song, {required this.onResult});

  final SongEntry song;
  final void Function(SongLevelChoice? choice) onResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 比較用の入力欄。編集画面の TextField と同じく style を指定しない。
            const TextField(key: ValueKey<String>('form-text-field')),
            ElevatedButton(
              key: const ValueKey<String>('open-picker'),
              onPressed: () async {
                final SongLevelChoice? choice = await showSongLevelPicker(
                  context,
                  song,
                );
                onResult(choice);
              },
              child: const Text('開く'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 4 難易度すべてに登録がある曲の代表値。
const Map<String, int> _fourLevels = <String, int>{
  'LIGHT': 6,
  'NORMAL': 21,
  'HYPER': 29,
  'EX': 31,
};

SongEntry _song(
  String title, {
  Map<String, int> levels = const <String, int>{},
}) {
  return SongEntry(
    id: 'id-$title',
    title: title,
    normalizedKey: title,
    levels: levels,
  );
}

/// ダイアログを開き、結果を受け取るための箱を返す。
Future<List<SongLevelChoice?>> _open(
  WidgetTester tester,
  SongEntry song, {
  Brightness brightness = Brightness.light,
}) async {
  final List<SongLevelChoice?> results = <SongLevelChoice?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: _Host(song, onResult: results.add),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open-picker')));
  await tester.pumpAndSettle();
  return results;
}

/// 選択肢 1 行の見出しを組み立てている TextSpan の根。
TextSpan _titleSpan(WidgetTester tester, String difficultyKey) {
  final ListTile tile = tester.widget<ListTile>(
    find.byKey(ValueKey<String>('song-level-option-$difficultyKey')),
  );
  return (tile.title! as Text).textSpan! as TextSpan;
}

/// 選択肢 1 行の表示文字列（難易度語と Lv を連結したもの）。
String _titleText(WidgetTester tester, String difficultyKey) {
  return _titleSpan(tester, difficultyKey).toPlainText();
}

/// 選択肢 1 行の文字スタイル。Text.rich の内側 span か Text.style のどちらに
/// 指定されていても拾う（指定位置に依存せず「実際に効くサイズ」を見るため）。
TextStyle? _optionTextStyle(WidgetTester tester, String difficultyKey) {
  final ListTile tile = tester.widget<ListTile>(
    find.byKey(ValueKey<String>('song-level-option-$difficultyKey')),
  );
  final Text text = tile.title! as Text;
  return (text.textSpan! as TextSpan).style ?? text.style;
}

/// 選択肢 1 行の難易度色ドット。
CircleAvatar _colorDot(WidgetTester tester, String difficultyKey) {
  return tester.widget<CircleAvatar>(
    find.descendant(
      of: find.byKey(ValueKey<String>('song-level-option-$difficultyKey')),
      matching: find.byType(CircleAvatar),
    ),
  );
}

void main() {
  testWidgets('登録済みの 4 難易度を低→高の順で出す', (WidgetTester tester) async {
    await _open(
      tester,
      _song(
        '四難易度',
        levels: const <String, int>{
          'EX': 31,
          'HYPER': 29,
          'LIGHT': 6,
          'NORMAL': 21,
        },
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('song-level-picker')),
      findsOneWidget,
    );

    final List<String> labels = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((ListTile tile) => (tile.title! as Text).textSpan!.toPlainText())
        .toList();
    expect(labels, <String>[
      'LIGHT  Lv.6',
      'NORMAL  Lv.21',
      'HYPER  Lv.29',
      'EX  Lv.31',
    ]);
  });

  testWidgets('登録が無い難易度は出さない', (WidgetTester tester) async {
    await _open(
      tester,
      _song('二難易度', levels: const <String, int>{'NORMAL': 21, 'HYPER': 29}),
    );

    expect(
      find.byKey(const ValueKey<String>('song-level-option-light')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('song-level-option-ex')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('song-level-option-normal')),
      findsOneWidget,
    );
  });

  testWidgets('難易度とレベルを選ぶと SongLevelChoice が返る', (WidgetTester tester) async {
    final List<SongLevelChoice?> results = await _open(
      tester,
      _song(
        '四難易度',
        levels: const <String, int>{
          'LIGHT': 6,
          'NORMAL': 21,
          'HYPER': 29,
          'EX': 31,
        },
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('song-level-option-ex')),
    );
    await tester.pumpAndSettle();

    expect(results.length, 1);
    expect(results.single, isNotNull);
    expect(results.single!.difficulty, GameDifficulty.ex);
    expect(results.single!.level, 31);
    expect(
      find.byKey(const ValueKey<String>('song-level-picker')),
      findsNothing,
    );
  });

  testWidgets('「自動入力しない」は null を返す', (WidgetTester tester) async {
    final List<SongLevelChoice?> results = await _open(
      tester,
      _song('四難易度', levels: const <String, int>{'EX': 31}),
    );

    await tester.tap(find.byKey(const ValueKey<String>('song-level-skip')));
    await tester.pumpAndSettle();

    // results には null が 1 件だけ入る（＝呼び出し側は入力欄を変えない）。
    expect(results.length, 1);
    expect(results.single, isNull);
    expect(
      find.byKey(const ValueKey<String>('song-level-picker')),
      findsNothing,
    );
  });

  testWidgets('外側タップでも null を返す', (WidgetTester tester) async {
    final List<SongLevelChoice?> results = await _open(
      tester,
      _song('四難易度', levels: const <String, int>{'EX': 31}),
    );

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(results.single, isNull);
  });

  testWidgets('登録が無ければダイアログを出さず null', (WidgetTester tester) async {
    final List<SongLevelChoice?> results = await _open(tester, _song('登録なし'));

    expect(
      find.byKey(const ValueKey<String>('song-level-picker')),
      findsNothing,
    );
    expect(results.single, isNull);
  });

  testWidgets('未知キーだけなら出さず、既知キーがあれば既知だけ出す', (WidgetTester tester) async {
    final List<SongLevelChoice?> unknownOnly = await _open(
      tester,
      _song('未知のみ', levels: const <String, int>{'UPPER': 50}),
    );
    expect(
      find.byKey(const ValueKey<String>('song-level-picker')),
      findsNothing,
    );
    expect(unknownOnly.single, isNull);

    await _open(
      tester,
      _song('混在', levels: const <String, int>{'UPPER': 50, 'EX': 31}),
    );
    expect(
      find.byKey(const ValueKey<String>('song-level-option-ex')),
      findsOneWidget,
    );
    expect(find.text('UPPER  Lv.50'), findsNothing);
  });

  testWidgets('難易度語だけが難易度色になり、レベル数値は既定色のまま', (WidgetTester tester) async {
    await _open(tester, _song('四難易度', levels: _fourLevels));

    const Map<String, GameDifficulty> keys = <String, GameDifficulty>{
      'light': GameDifficulty.light,
      'normal': GameDifficulty.normal,
      'hyper': GameDifficulty.hyper,
      'ex': GameDifficulty.ex,
    };
    keys.forEach((String key, GameDifficulty difficulty) {
      final List<InlineSpan> spans = _titleSpan(tester, key).children!;
      final TextSpan word = spans[0] as TextSpan;
      final TextSpan level = spans[1] as TextSpan;
      expect(word.text, key.toUpperCase());
      expect(word.style?.color, difficultyColor(difficulty));
      // 色が指すのは難易度であってレベルではないため、Lv は色を継がない。
      expect(level.style?.color, isNull);
    });
  });

  testWidgets('各行の先頭に難易度色のドットが出る', (WidgetTester tester) async {
    await _open(tester, _song('四難易度', levels: _fourLevels));

    expect(
      _colorDot(tester, 'light').backgroundColor,
      difficultyColor(GameDifficulty.light),
    );
    expect(
      _colorDot(tester, 'normal').backgroundColor,
      difficultyColor(GameDifficulty.normal),
    );
    expect(
      _colorDot(tester, 'hyper').backgroundColor,
      difficultyColor(GameDifficulty.hyper),
    );
    expect(
      _colorDot(tester, 'ex').backgroundColor,
      difficultyColor(GameDifficulty.ex),
    );
  });

  testWidgets('選択肢の文字サイズは入力欄と同じになる', (WidgetTester tester) async {
    await _open(tester, _song('四難易度', levels: _fourLevels));

    // 入力欄（style 未指定の TextField）が実際に描画しているサイズを基準にする。
    final EditableText formField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('form-text-field')),
        matching: find.byType(EditableText),
      ),
    );
    final double? formFontSize = formField.style.fontSize;
    expect(formFontSize, isNotNull);

    for (final String key in <String>['light', 'normal', 'hyper', 'ex']) {
      expect(
        _optionTextStyle(tester, key)?.fontSize,
        formFontSize,
        reason: '$key の文字サイズが入力欄と揃っていない',
      );
    }
  });

  testWidgets('ダークテーマではダーク用の配色になる', (WidgetTester tester) async {
    await _open(
      tester,
      _song('四難易度', levels: _fourLevels),
      brightness: Brightness.dark,
    );

    expect(
      _colorDot(tester, 'ex').backgroundColor,
      difficultyColor(GameDifficulty.ex, brightness: Brightness.dark),
    );
    final TextSpan word = _titleSpan(tester, 'ex').children![0] as TextSpan;
    expect(
      word.style?.color,
      difficultyColor(GameDifficulty.ex, brightness: Brightness.dark),
    );
  });

  testWidgets('着色しても表示文字列は変わらない', (WidgetTester tester) async {
    await _open(tester, _song('四難易度', levels: _fourLevels));

    expect(_titleText(tester, 'light'), 'LIGHT  Lv.6');
    expect(_titleText(tester, 'ex'), 'EX  Lv.31');
  });
}
