// 曲名確定時に、曲名DBに登録されている難易度とレベルを選ばせるダイアログ。
//
// WHY(ユーザー指示 2026-11-25): 「曲名が確定したら、ポップアップ等で曲名DBに
// 登録されている難易度とレベルを選択肢で選ばせる（『自動入力しない』という
// 選択肢も作る）」。編集画面の難易度チップとレベル欄は手入力のみだったため、
// 曲名DBの登録値を入力欄へ持ってくる経路を 1 箇所にまとめる。
//
// WHY(ユーザー指示 2026-11-25): 「曲名確定時のダイアログにも難易度対応の色を
// 付けて」。色は difficulty_color.dart の 1 関数だけを参照し、色値をここへ
// 書かない（色の定義が 2 箇所に分かれると片方の変更が漏れる）。

import 'package:material_ui/material_ui.dart';

import '../data/play_record.dart';
import '../ocr/song_entry.dart';
import 'difficulty_color.dart';
import 'difficulty_levels.dart';

/// ユーザーが選んだ難易度とレベル。
class SongLevelChoice {
  const SongLevelChoice({required this.difficulty, required this.level});

  /// 選ばれた難易度。
  final GameDifficulty difficulty;

  /// その難易度のレベル（曲名DB の登録値）。
  final int level;
}

/// 曲名DBの登録内容から難易度とレベルを 1 つ選ばせる。
///
/// 戻り値 null は「自動入力しない」を意味する（呼び出し側は入力欄を変更しない）。
/// 表示順は [kDifficultyDisplayOrder]（LIGHT→NORMAL→HYPER→EX の低→高）で、
/// 登録が無い難易度と未知キー（現行 DB に無い UPPER 等）は出さない。
/// 表示できる難易度が 1 つも無ければダイアログを出さずに null を返す。
Future<SongLevelChoice?> showSongLevelPicker(
  BuildContext context,
  SongEntry song,
) async {
  final List<MapEntry<String, int>> choices = orderedLevels(song.levels)
      .where((MapEntry<String, int> level) => _difficultyOf(level.key) != null)
      .toList();
  if (choices.isEmpty) {
    return null;
  }
  return showDialog<SongLevelChoice>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const ValueKey<String>('song-level-picker'),
      title: _title(dialogContext, song),
      content: _content(dialogContext, choices),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('song-level-skip'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('自動入力しない'),
        ),
      ],
    ),
  );
}

/// 曲名は title の副題として出す（どの曲の登録値か一目で分かるようにする）。
Widget _title(BuildContext context, SongEntry song) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text('曲名DBの難易度とレベル'),
      Text(song.title, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

/// 説明文と、登録がある難易度の選択肢。
Widget _content(BuildContext context, List<MapEntry<String, int>> choices) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text('登録されている難易度とレベルです。選ぶと入力欄へ反映します。'),
      for (final MapEntry<String, int> level in choices)
        _option(context, level),
    ],
  );
}

/// 選択肢 1 行。難易度色は「難易度語」と先頭の丸印に載せる。
///
/// 色だけに意味を持たせず、難易度名（LIGHT 等）も必ず併記する。
/// Lv の数値は既定色のまま（色が指すのは難易度であってレベルではない）。
Widget _option(BuildContext context, MapEntry<String, int> level) {
  final GameDifficulty difficulty = _difficultyOf(level.key)!;
  final ThemeData theme = Theme.of(context);
  final Color? color = difficultyColor(
    difficulty,
    brightness: theme.brightness,
  );
  return ListTile(
    dense: true,
    key: ValueKey<String>('song-level-option-${level.key.toLowerCase()}'),
    leading: color == null
        ? null
        : CircleAvatar(backgroundColor: color, radius: 6),
    // 表記は曲名検索画面の副題（Lv.<難易度> <数値>）に合わせる。
    // 文字サイズは入力欄に合わせる（編集画面の TextField は style を指定して
    // いないため bodyLarge で描画される。dense 指定の ListTile 既定は
    // bodyMedium で、入力欄より 1 段小さい）。
    title: Text.rich(
      TextSpan(
        style: theme.textTheme.bodyLarge,
        children: <InlineSpan>[
          TextSpan(
            text: level.key,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          TextSpan(text: '  Lv.${level.value}'),
        ],
      ),
    ),
    onTap: () =>
        Navigator.of(context)
            .pop(SongLevelChoice(difficulty: difficulty, level: level.value)),
  );
}

/// DB の難易度キー（"EX" 等）→ [GameDifficulty]。未知キーは null。
///
/// WHY 大文字小文字を無視するか: DB のキーは大文字（LIGHT/NORMAL/HYPER/EX）、
/// enum の name は小文字のため、そのままでは一致しない。
GameDifficulty? _difficultyOf(String key) {
  for (final GameDifficulty difficulty in GameDifficulty.values) {
    if (difficulty.name.toUpperCase() == key.toUpperCase()) {
      return difficulty;
    }
  }
  return null;
}
