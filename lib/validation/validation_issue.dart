/// FR-6（ST-6）整合性検証で使用する値型とルール識別子。
///
/// WHY: UI に直接置くと検証ロジックがテスト不能になり、lib/ocr に置くと
/// OCR-Core 領域の既存契約を変えることになる。純粋な値型として
/// lib/validation に分離し、検証器（play_record_validator.dart）と
/// UI 配線の共有契約とする（設計確認書 §3）。
library;

import 'package:flutter/foundation.dart';

/// クリアメダルの分類（spec.md §5.4 VR-4・ユーザー提供メダル一覧由来）。
///
/// WHY: メダル形状（★/◆/●/四つ葉/若葉）単体ではクリア種別が一意に決まらない
/// （★◆● は FC/クリア/FAILED 兼用）。将来のメダル OCR 側が分類できるときだけ
/// 値を返し、分類不能なら null を返す契約とする。検証器は分類済み入力のみを
/// 扱い、確実性の判断は認識側に委ねる（SRP）。
enum ClearMedalCategory {
  /// パーフェクト（GOOD=0・BAD=0）/ フルコンボ（BAD=0・GOOD≥1）の総称。
  fullComboFamily,

  /// クリア（BAD≥1・メダル階級 ★◆●）。
  clear,

  /// アシストクリア（四つ葉・ロングポップ君。BAD=0 なら FC 表示が優先される）。
  assistClear,

  /// イージークリア（若葉・BAD≥1 前提）。
  easyClear,

  /// FAILED（ゲージ喪失。ボンバーおじゃまでは BAD=0 のまま失敗し得る稀な例外）。
  failed,
}

/// 検証ルールの識別子（spec.md §5.4 の VR 番号に対応付ける）。
enum ValidationRule {
  /// VR-4: BAD=0 ↔ フルコンボ系メダルの一致（段階 A）。
  vr4MedalJudgment,

  /// VR-2': スコア ⇔ 判定内訳の相互整合（逆算総ノーツ・段階 A）。
  vr2JudgmentScore,

  /// VR-3': MAX COMBO ≤ 判定合計（DB 不要の恒等式・段階 A 追加分）。
  vr3ComboJudgments,

  /// VR-1: 判定合計 vs 総ノーツ数（段階 B・SongEntry v2 totalNotes 経由）。
  vr1JudgmentNotes,

  /// VR-3: MAX COMBO ≤ 総ノーツ数（段階 B・SongEntry v2 totalNotes 経由）。
  vr3ComboNotes,
}

/// 1 件の整合性検証の結果（矛盾したルール・確認対象フィールド・説明）。
///
/// WHY: 「どのフィールド行を確認すべきか」を fieldId（FR-3 の行キー語彙と同一:
/// score/cool/great/good/bad/maxCombo/level）で伝える。UI は既存の
/// errorContainer ハイライト機構をそのまま流用できる（設計確認書 §4）。
@immutable
class ValidationIssue {
  const ValidationIssue({
    required this.rule,
    required this.fieldIds,
    required this.message,
  });

  final ValidationRule rule;

  /// 確認を促すフィールド行の id（対応する行にハイライトとメッセージを出す）。
  final List<String> fieldIds;

  /// ユーザー向けの説明（修正の当たりを付けられるよう数値を含む）。
  final String message;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ValidationIssue &&
        other.rule == rule &&
        other.message == message &&
        listEquals(other.fieldIds, fieldIds);
  }

  @override
  int get hashCode => Object.hash(rule, Object.hashAll(fieldIds), message);
}
