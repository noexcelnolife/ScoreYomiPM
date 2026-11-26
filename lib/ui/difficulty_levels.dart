// 難易度レベルの表示順を一元化する。
//
// WHY 共通ヘルパにするか: 曲名検索画面の候補行でレベルを並べる必要が出た。
// 同じ並びを複数画面で書くと順序が食い違うため、順序と整形をここに集約する。

/// 難易度の表示順（低 → 高）。
///
/// アプリと DB の難易度キーは `LIGHT` / `NORMAL` / `HYPER` / `EX` の 4 種で、
/// 最下位は `LIGHT`（`GameDifficulty` も同じ 4 値）。ユーザー提示の
/// 「EASY / NORMAL / HYPER / EX」のうち EASY はこの `LIGHT` に対応するが、
/// enum・DB・CSV 出力の互換があるため `EASY` へは改名も読み替えもしない。
const List<String> kDifficultyDisplayOrder = <String>[
  'LIGHT',
  'NORMAL',
  'HYPER',
  'EX',
];

/// 既知の難易度キーだけを表示順で返す（存在するものだけ）。
///
/// WHY 未知キーを落とすか: 将来 `UPPER` などが増えても表示順が未定義のまま
/// 一覧に混ざると、並びが実装依存になる。順序が決まらないものは出さない。
List<MapEntry<String, int>> orderedLevels(Map<String, int> levels) {
  final List<MapEntry<String, int>> ordered = <MapEntry<String, int>>[];
  for (final String difficulty in kDifficultyDisplayOrder) {
    final int? level = levels[difficulty];
    if (level != null) {
      ordered.add(MapEntry<String, int>(difficulty, level));
    }
  }
  return ordered;
}

/// `Lv.LIGHT 6・Lv.NORMAL 21・Lv.HYPER 29・Lv.EX 31` 形式に整える。
///
/// 該当する難易度が 1 つも無ければ null（呼び出し側は行ごと出さない）。
String? formatLevels(Map<String, int> levels) {
  final List<MapEntry<String, int>> ordered = orderedLevels(levels);
  if (ordered.isEmpty) {
    return null;
  }
  return ordered
      .map((MapEntry<String, int> entry) => 'Lv.${entry.key} ${entry.value}')
      .join('・');
}
