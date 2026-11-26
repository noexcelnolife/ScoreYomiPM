/// FR-6（ST-6）整合性検証の純粋関数モジュール。
///
/// WHY: lib/ocr の型に依存せず plain int + enum のみを受け取る。これにより
/// OCR 結果画面・将来の記録詳細（FR-11）・ユーザー手入力のどれからでも同じ
/// ルールを再利用でき（DIP）、flutter test で完全検証できる。欠損（null）が
/// あるルールはスキップし、例外を投げない（設計確認書 §2/§4）。
library;

import 'validation_issue.dart';

/// スコア配点式の重み（2026-11-22 ユーザー確認: COOL=1.0/GREAT=0.7/GOOD=0.4/BAD=0）。
const double kCoolWeight = 1.0;
const double kGreatWeight = 0.7;
const double kGoodWeight = 0.4;
const double kBadWeight = 0.0;

/// VR-2' の許容差（逆算総ノーツと判定合計の差の上限）。
///
/// WHY: score の整数丸めによる誤差は ≈0。1 つの判定の 1 の位を 1 文字誤読した
/// ときの差は Δ = |δ·(w·S/total − 1)| で最大 ≈13.5（COOL δ9・total = S/2.5 の
/// 最悪比率）なので、余裕を持つ 24 を採用し、1 の位 1 文字の誤読はすべて吸収、
/// 10 の位以上のズレ（GOOD δ≥44 など）は検知対象として残す。
/// 相対幅（S の 2% 等）は大きな記録で実害を吸収して検知力を落とすため不採用。
/// ※ 設計確認書 §5 の誤差表は実装時に数式を訂正した（判定合計 S が同じ δ だけ
///   動く点を反映）が、T=24 の採択判断はリード承認どおり不変。
const double kTntTolerance = 24.0;

/// プレイ値（OCR 抽出 or ユーザー入力）の整合性を検証する。
///
/// 発火するルール: VR-2'（スコア⇔判定内訳）・VR-4（メダル⇔BAD）・
/// VR-3'（MAX COMBO ≤ 判定合計）・段階 B の VR-1/VR-3（総ノーツ数との恒等式）。
/// totalNotes は SongEntry v2 computed getter（notesCounts 非空なら max）を
/// UI が matchedSong 経由で解体して渡す。null なら notes 系ルールは欠損 skip。
List<ValidationIssue> validatePlayValues({
  int? score,
  int? cool,
  int? great,
  int? good,
  int? bad,
  int? maxCombo,
  ClearMedalCategory? clearMedal,
  int? totalNotes,
}) {
  final List<ValidationIssue> issues = <ValidationIssue>[];
  final ValidationIssue? scoreIssue = _checkJudgmentScore(
    score: score,
    cool: cool,
    great: great,
    good: good,
    bad: bad,
  );
  if (scoreIssue != null) {
    issues.add(scoreIssue);
  }
  final ValidationIssue? medalIssue = _checkMedalJudgment(
    clearMedal: clearMedal,
    bad: bad,
  );
  if (medalIssue != null) {
    issues.add(medalIssue);
  }
  final ValidationIssue? comboIssue = _checkComboJudgments(
    maxCombo: maxCombo,
    cool: cool,
    great: great,
    good: good,
    bad: bad,
  );
  if (comboIssue != null) {
    issues.add(comboIssue);
  }
  // 段階 B（FR-6）: notes 系ルールは totalNotes が渡されたときだけ評価する。
  // matchedSong 不在（4 パス）や未収録曲は欠損入力として skip（設計 §5）。
  final ValidationIssue? judgmentsNotesIssue = _checkJudgmentsNotes(
    cool: cool,
    great: great,
    good: good,
    bad: bad,
    totalNotes: totalNotes,
  );
  if (judgmentsNotesIssue != null) {
    issues.add(judgmentsNotesIssue);
  }
  final ValidationIssue? comboNotesIssue = _checkComboNotes(
    maxCombo: maxCombo,
    totalNotes: totalNotes,
  );
  if (comboNotesIssue != null) {
    issues.add(comboNotesIssue);
  }
  return issues;
}

/// VR-2': score から逆算した総ノーツと判定合計の整合。
///
/// 恒等式: score = (C + 0.7G + 0.4GOOD) × 100000 / S（S = 判定合計・全ノーツが
/// いずれかの判定になるため S = 総ノーツ）。5 値が揃ったときだけ発火する。
ValidationIssue? _checkJudgmentScore({
  required int? score,
  required int? cool,
  required int? great,
  required int? good,
  required int? bad,
}) {
  // WHY: 欠損を 0 とみなすと判定合計が過小になり誤検知する。恒等式検証は
  // 5 値が揃ったときだけ発火する（設計 §2-1）。
  if (score == null ||
      cool == null ||
      great == null ||
      good == null ||
      bad == null) {
    return null;
  }
  final int judgmentTotal = cool + great + good + bad;
  if (score <= 0 || judgmentTotal <= 0) {
    return null;
  }
  final double weighted =
      cool * kCoolWeight +
      great * kGreatWeight +
      good * kGoodWeight +
      bad * kBadWeight;
  final double backCalcTotalNotes = weighted * 100000 / score;
  final double difference = (backCalcTotalNotes - judgmentTotal).abs();
  if (difference <= kTntTolerance) {
    return null;
  }
  return ValidationIssue(
    rule: ValidationRule.vr2JudgmentScore,
    fieldIds: const <String>['score', 'cool', 'great', 'good', 'bad'],
    // WHY: 旧文言の「逆算総ノーツ」は VR-1 の総ノーツ数（DB 値）と誤解され
    // 得た（smoke test レポート P-9）。リード裁定（2026-11-23）により
    // 「総ノーツ数」の語を使わず、スコア⇔判定の不整合であることを先頭で
    // 述べる文言へ差し替え。数値の小数表示ロジックは現状維持。
    message:
        'スコアから計算したノーツ合計の見込み（${backCalcTotalNotes.toStringAsFixed(1)}）'
        'が判定合計（$judgmentTotal）と一致しません。スコアまたは判定内訳をご確認ください',
  );
}

/// VR-4: BAD=0 ↔ フルコンボ系メダルの一致（双方向）。
///
/// WHY: 優先順位規則（§6）より BAD=0 のプレイは必ず FC 系メダル表示になる。
/// ただしボンバーおじゃまでゲージ喪失の場合は FAILED 表示のまま FC 条件を
/// 満たし得る稀な例外があるため、メッセージに例外を併記して誤指摘を和らげる。
ValidationIssue? _checkMedalJudgment({
  required ClearMedalCategory? clearMedal,
  required int? bad,
}) {
  if (clearMedal == null || bad == null) {
    return null;
  }
  if (clearMedal == ClearMedalCategory.fullComboFamily && bad > 0) {
    return const ValidationIssue(
      rule: ValidationRule.vr4MedalJudgment,
      fieldIds: <String>['bad'],
      message: 'フルコンボ系メダルなのに BAD が 0 ではありません',
    );
  }
  if (clearMedal != ClearMedalCategory.fullComboFamily && bad == 0) {
    return ValidationIssue(
      rule: ValidationRule.vr4MedalJudgment,
      fieldIds: const <String>['bad'],
      message:
          'BAD=0 のためメダルはフルコンボ系のはずです'
          '（現在: ${_medalLabel(clearMedal)}）。ボンバーおじゃまの例外もあります',
    );
  }
  return null;
}

/// VR-3': MAX COMBO は判定合計を超えられない（PM の恒等式・DB 不要）。
ValidationIssue? _checkComboJudgments({
  required int? maxCombo,
  required int? cool,
  required int? great,
  required int? good,
  required int? bad,
}) {
  // WHY: 判定合計が不完全なときの比較は過小値との比較になり誤検知するため、
  // 4 値が揃ったときだけ発火する。
  if (maxCombo == null ||
      cool == null ||
      great == null ||
      good == null ||
      bad == null) {
    return null;
  }
  final int judgmentTotal = cool + great + good + bad;
  if (judgmentTotal <= 0 || maxCombo <= judgmentTotal) {
    return null;
  }
  return ValidationIssue(
    rule: ValidationRule.vr3ComboJudgments,
    fieldIds: const <String>['maxCombo', 'cool', 'great', 'good', 'bad'],
    message: 'MAX COMBO が判定合計を超えています（$maxCombo > $judgmentTotal）',
  );
}

/// VR-1: 判定合計は総ノーツ数を超えられない（SongEntry v2 の totalNotes 経由）。
///
/// WHY（レイヤリング）: VR-2' の盲点（w·r = 1 となる全同種構成 =
/// all-COOL/all-GREAT/all-GOOD は Δ = δ·|w·r − 1| = 0 で不発）は、上方向の
/// 同種誤読なら S′ = N + δ > totalNotes として VR-1 が吸収する。ただし
/// N_chart < max の易しめ譜面での一様上方向誤読（N_chart + δ ≤ max）は
/// VR-1 を通過する — 難易度記録の着地後に精密化する（spec §5.4 残課題）。
ValidationIssue? _checkJudgmentsNotes({
  required int? cool,
  required int? great,
  required int? good,
  required int? bad,
  required int? totalNotes,
}) {
  // WHY: 判定合計が不完全なときの比較は過小値との比較になり誤検知するため、
  // 4 値と totalNotes が揃ったときだけ発火する（欠損 skip 契約の拡張・設計 §5）。
  if (totalNotes == null ||
      cool == null ||
      great == null ||
      good == null ||
      bad == null) {
    return null;
  }
  final int judgmentTotal = cool + great + good + bad;
  if (judgmentTotal <= 0 || judgmentTotal <= totalNotes) {
    return null;
  }
  return ValidationIssue(
    rule: ValidationRule.vr1JudgmentNotes,
    // WHY: score はこのルールの構成要素ではないため 4 判定行のみを
    // ハイライトする（score 行の誘導は VR-2' の役割・設計 §2）。
    fieldIds: const <String>['cool', 'great', 'good', 'bad'],
    message:
        '判定合計（$judgmentTotal）が総ノーツ数（推定 $totalNotes）を'
        '超えています。各判定数をご確認ください',
  );
}

/// VR-3: MAX COMBO は総ノーツ数を超えられない（SongEntry v2 の totalNotes 経由）。
///
/// VR-1 と補完関係: 判定合計が総ノーツ数以下に収まっていても、maxCombo 単体の
/// 超過はこちらで検知する（設計 §3）。
ValidationIssue? _checkComboNotes({
  required int? maxCombo,
  required int? totalNotes,
}) {
  // WHY: maxCombo と totalNotes は 2 値のみの恒等式なので、判定 4 値の欠損の
  // 影響を受けず単体で評価できる（VR-3' と異なり欠損判定では skip しない）。
  if (maxCombo == null || totalNotes == null || maxCombo <= totalNotes) {
    return null;
  }
  return ValidationIssue(
    rule: ValidationRule.vr3ComboNotes,
    fieldIds: const <String>['maxCombo'],
    message: 'MAX COMBO（$maxCombo）が総ノーツ数（推定 $totalNotes）を超えています',
  );
}

/// メダルカテゴリの表示名（メッセージ内で現在値を示すため）。
String _medalLabel(ClearMedalCategory category) {
  switch (category) {
    case ClearMedalCategory.fullComboFamily:
      return 'フルコンボ系';
    case ClearMedalCategory.clear:
      return 'クリア';
    case ClearMedalCategory.assistClear:
      return 'アシストクリア';
    case ClearMedalCategory.easyClear:
      return 'イージークリア';
    case ClearMedalCategory.failed:
      return 'FAILED';
  }
}
