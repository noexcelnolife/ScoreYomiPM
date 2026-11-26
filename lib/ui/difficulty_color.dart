import 'package:material_ui/material_ui.dart';

import '../data/play_record.dart';

/// 難易度 4 種のゲーム内カラーイメージ（単一真実源）。
///
/// ユーザー指示（2026-11-24）: LIGHT = 明るい青 / NORMAL = 明るい緑 /
/// HYPER = 黄色 / EX = 赤。入力チップ・一覧副題・詳細・曲名確定時の
/// ダイアログの 4 面はすべてこの関数を参照し、色値を各所へ撒かない。
///
/// WHY データ層に置かない: 色は表示都合であり、enum 名・JSON キー・保存値に
/// UI 都合を混ぜると将来のテーマ変更でストレージ破壊的変更を強いられる。
/// 表示は「難易度名 → 色」の関数 1 本で足りる。
///
/// WHY brightness で 2 パレット: ゲーム内の明るい色は暗背景でこそ映えるが、
/// 淡い背景では文字色として沈む（WCAG 2.1 コントラスト比・実測）:
/// 例 #FBC02D は白背景 1.66 / 暗背景 10.34、#4FC3F7 は 2.00 / 8.55。
/// 本アプリは現状ライトテーマのみ（main.dart は theme のみ指定）だが、
/// 将来のダークテーマ追加に備え、呼び出し側は Theme の明度を渡せる。
/// 既定値 Light は「現行テーマ＝淡い背景」を安全側にしたもの。
///
/// WHY ライト値の選定（白背景 #FFFFFF での実測コントラスト比）:
/// - LIGHT #0277BD（lightBlue 800）= 4.80。ゲーム内の lightBlue 300 は
///   2.00 で 14sp の本文には淡すぎるため、青の色相を保ったまま AA（4.5）
///   を満たす濃さまで落とした。
/// - NORMAL #2E7D32（green 800）= 5.13。同様に緑の色相を保ち AA 達成。
/// - HYPER #B8860B（darkGoldenrod）= 3.25。黄系で AA を満たす明度は存在
///   しない（yellow 900 でも 2.65・しかも橙寄りに転ぶ）。黄の色相を保つ
///   中で最大コントラストの金茶を選び、文字は太字併用で視認を補う。
/// - EX #C62828（red 800）= 5.62。一覧行に同居する確定待ちのステータス
///   チップ（orange 700 #F57C00）とは色相（赤 0° / 橙 22°）と明度で区別
///   でき、自己ベストの amber 300 バッジとも色相が離れている。
///
/// WHY ダーク値: ゲーム内イメージそのまま（lightBlue 300 / green 400 /
/// yellow 700 / red 400）。暗背景 #1C1B1F で 8.55 / 7.24 / 10.34 / 4.91 と
/// いずれも AA 以上。
///
/// WHY null → null: 難易度不明（未記録・OCR 未確定）は従来の既定色のまま
/// 着色しない。誤った難易度色を見せないことが最優先。
Color? difficultyColor(
  GameDifficulty? difficulty, {
  Brightness brightness = Brightness.light,
}) {
  final bool dark = brightness == Brightness.dark;
  switch (difficulty) {
    case GameDifficulty.light:
      return dark ? const Color(0xFF4FC3F7) : const Color(0xFF0277BD);
    case GameDifficulty.normal:
      return dark ? const Color(0xFF66BB6A) : const Color(0xFF2E7D32);
    case GameDifficulty.hyper:
      return dark ? const Color(0xFFFBC02D) : const Color(0xFFB8860B);
    case GameDifficulty.ex:
      return dark ? const Color(0xFFEF5350) : const Color(0xFFC62828);
    case null:
      return null;
  }
}
