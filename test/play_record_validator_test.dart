import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/validation/play_record_validator.dart';
import 'package:scoreyomipm/validation/validation_issue.dart';

/// FR-6（ST-6）整合性検証の純粋ロジックテスト。
///
/// 設計: docs/fr6_validation_design_confirmation_2026-11-22.md §7。
/// 数値例の基準レコード: C=1200, G=300, GOOD=80, BAD=20（S=1600・total=1442）,
/// score=90125（= 1442×100000/1600 のちょうどの値 → tnt'=1600.0・整合）。
void main() {
  /// 基準レコード（整合済み）のパラメータを一部だけ差し替えるヘルパー。
  Map<String, int?> base({
    int? score = 90125,
    int? cool = 1200,
    int? great = 300,
    int? good = 80,
    int? bad = 20,
    int? maxCombo,
  }) {
    return <String, int?>{
      'score': score,
      'cool': cool,
      'great': great,
      'good': good,
      'bad': bad,
      'maxCombo': maxCombo,
    };
  }

  List<ValidationIssue> validate(
    Map<String, int?> values, {
    ClearMedalCategory? medal,
    int? totalNotes,
  }) {
    return validatePlayValues(
      score: values['score'],
      cool: values['cool'],
      great: values['great'],
      good: values['good'],
      bad: values['bad'],
      maxCombo: values['maxCombo'],
      clearMedal: medal,
      totalNotes: totalNotes,
    );
  }

  group('VR-2′ スコア⇔判定内訳の相互整合', () {
    test('整合する 3 例（typical / 全 COOL / 全 GREAT）では issue を出さない', () {
      // typical: tnt' = 1442×100000/90125 = 1600.0 → 差 0。
      expect(validate(base()), isEmpty);
      // 全 COOL: tnt' = 1500×100000/100000 = 1500 → 差 0。
      expect(
        validate(base(cool: 1500, great: 0, good: 0, bad: 0, score: 100000)),
        isEmpty,
      );
      // 全 GREAT: tnt' = 1400×100000/70000 = 2000 → 差 0。
      expect(
        validate(base(great: 2000, cool: 0, good: 0, bad: 0, score: 70000)),
        isEmpty,
      );
    });

    test('GOOD を誤読（+100）すると vr2 の issue を出す', () {
      // good=180: total=1482・S=1700 → tnt'=1644.4 → 差 55.6 > 24。
      final List<ValidationIssue> issues = validate(base(good: 180));
      expect(issues, hasLength(1));
      final ValidationIssue issue = issues.single;
      expect(issue.rule, ValidationRule.vr2JudgmentScore);
      // どの判定が誤読かは式から確定できないため 5 行すべてを確認対象にする。
      expect(issue.fieldIds, <String>['score', 'cool', 'great', 'good', 'bad']);
      // WHY: 文言固定（v2 UX #11・P-9・リード裁定 2026-11-23）。旧文言の
      // 「逆算総ノーツ」は VR-1 の総ノーツ数（DB 値）と誤解され得るため、
      // 「総ノーツ数」の語を使わずスコア⇔判定の不整合を先頭で述べる。
      expect(
        issue.message,
        'スコアから計算したノーツ合計の見込み（1644.4）が判定合計（1700）'
        'と一致しません。スコアまたは判定内訳をご確認ください',
      );
    });

    test('許容差 T=24 の境界（GOOD ±30 は吸収・±50 は検知・両方向）', () {
      // good=110: S=1630・total=1454 → tnt'=1613.3 → 差 16.7 ≤ 24。
      expect(validate(base(good: 110)), isEmpty);
      // good=50: S=1570・total=1430 → tnt'=1586.2 → 差 16.2 ≤ 24。
      expect(validate(base(good: 50)), isEmpty);
      // good=130: S=1650・total=1462 → tnt'=1622.2 → 差 27.8 > 24。
      expect(
        validate(base(good: 130)).single.rule,
        ValidationRule.vr2JudgmentScore,
      );
      // good=30: S=1550・total=1422 → tnt'=1577.5 → 差 27.5 > 24。
      expect(
        validate(base(good: 30)).single.rule,
        ValidationRule.vr2JudgmentScore,
      );
      // BAD の 1 の位 1 文字誤読（+9）は吸収域（差 9.0）。
      expect(validate(base(bad: 29)), isEmpty);
    });

    test('5 値のいずれかが欠損・score≤0・判定合計≤0 ではスキップする', () {
      // 欠損を 0 とみなすと判定合計が過小になり誤検知するため全スキップ。
      expect(validate(base(score: null)), isEmpty);
      expect(validate(base(cool: null)), isEmpty);
      expect(validate(base(great: null)), isEmpty);
      expect(validate(base(good: null)), isEmpty);
      expect(validate(base(bad: null)), isEmpty);
      // score=0 は逆算不可能。
      expect(validate(base(score: 0)), isEmpty);
      // 判定合計 0（全 BAD で score のみ入力）もスキップ。
      expect(validate(base(cool: 0, great: 0, good: 0, bad: 0)), isEmpty);
    });
  });

  group('VR-4 BAD=0 ↔ FC 系メダルの一致', () {
    test('fullComboFamily ∧ BAD=0 は整合', () {
      expect(
        validate(
          base(bad: 0, score: 91375),
          medal: ClearMedalCategory.fullComboFamily,
        ),
        isEmpty,
      );
    });

    test('fullComboFamily ∧ BAD>0 は矛盾', () {
      final List<ValidationIssue> issues = validate(
        base(),
        medal: ClearMedalCategory.fullComboFamily,
      );
      expect(issues.single.rule, ValidationRule.vr4MedalJudgment);
      expect(issues.single.fieldIds, <String>['bad']);
      expect(issues.single.message, contains('フルコンボ系メダル'));
    });

    test('BAD=0 なのに非 FC 系メダルは矛盾（クリア / アシスト）', () {
      for (final ClearMedalCategory medal in <ClearMedalCategory>[
        ClearMedalCategory.clear,
        ClearMedalCategory.assistClear,
        ClearMedalCategory.easyClear,
      ]) {
        final List<ValidationIssue> issues = validate(
          base(bad: 0, score: 91375),
          medal: medal,
        );
        expect(issues.single.rule, ValidationRule.vr4MedalJudgment);
        expect(issues.single.message, contains('BAD=0'));
      }
    });

    test('非 FC 系メダル ∧ BAD>0 は整合（failed 含む）', () {
      expect(validate(base(), medal: ClearMedalCategory.clear), isEmpty);
      expect(validate(base(), medal: ClearMedalCategory.failed), isEmpty);
    });

    test('メダル未確定（null）・BAD 欠損ではスキップ', () {
      // 段階 A の UI 経路は medal=null（メダル OCR 未着地）のため常に不発。
      expect(validate(base()), isEmpty);
      expect(
        validate(base(bad: null), medal: ClearMedalCategory.clear),
        isEmpty,
      );
    });
  });

  group('VR-3′ MAX COMBO ≤ 判定合計（DB 不要の恒等式）', () {
    test('コンボ ≤ 判定合計 は整合（同値を含む）', () {
      expect(validate(base(maxCombo: 1600)), isEmpty);
      expect(validate(base(maxCombo: 900)), isEmpty);
    });

    test('コンボ > 判定合計 は vr3′ の issue', () {
      final List<ValidationIssue> issues = validate(base(maxCombo: 1601));
      expect(issues.single.rule, ValidationRule.vr3ComboJudgments);
      expect(issues.single.fieldIds, contains('maxCombo'));
      expect(issues.single.message, contains('1601'));
      expect(issues.single.message, contains('1600'));
    });

    test('コンボ未入力・判定 4 値が不完全ならスキップ', () {
      // 判定合計が不完全なときの比較は過小値との比較になり誤検知する。
      expect(validate(base(maxCombo: null)), isEmpty);
      final Map<String, int?> incomplete = base(cool: null);
      incomplete['maxCombo'] = 9999;
      expect(validate(incomplete), isEmpty);
    });
  });

  group('VR-1/VR-3 総ノーツ数との恒等式（段階 B）', () {
    // 設計: docs/fr6_stage_b_vr1_vr3_design_confirmation_2026-11-22.md §2/§3/§5/§7。
    // 基準レコードの判定合計 S = 1600。既存全ケース（totalNotes 引数なし）が
    // そのまま回帰ガードとなる（欠損 skip 契約の拡張で挙動不変）。

    test('VR-1 発火: 判定合計 > totalNotes は notes 系 issue を出す', () {
      // S=1600 > totalNotes=1599（SongEntry v2 getter は max(values)＝最も緩い上限）。
      final List<ValidationIssue> issues = validate(base(), totalNotes: 1599);
      expect(issues, hasLength(1));
      final ValidationIssue issue = issues.single;
      expect(issue.rule, ValidationRule.vr1JudgmentNotes);
      // score は VR-1 の構成要素ではないため 4 判定行のみハイライト（設計 §2）。
      expect(issue.fieldIds, <String>['cool', 'great', 'good', 'bad']);
      // 「推定」表記は max(values) 意味論（記録譜面の上界に過ぎない）と整合
      // させる旨がリード確認済み（bfa1405 検収返信）。
      expect(issue.message, contains('判定合計（1600）'));
      expect(issue.message, contains('総ノーツ数（推定 1599）'));
    });

    test('VR-1 境界不発: 判定合計 == totalNotes', () {
      // 上限いっぱいまで叩く記録は正当。
      expect(validate(base(), totalNotes: 1600), isEmpty);
    });

    test('VR-3 発火: 判定 4 値が不完全でも maxCombo 単体で評価する', () {
      // maxCombo と totalNotes は 2 値のみの恒等式なので欠損判定の影響を受けない
      // （判定合計は使わない・設計 §3）。VR-3′（判定合計との恒等式）は skip のまま。
      final Map<String, int?> incomplete = base(cool: null, maxCombo: 1601);
      final List<ValidationIssue> issues = validate(
        incomplete,
        totalNotes: 1600,
      );
      expect(issues, hasLength(1));
      final ValidationIssue issue = issues.single;
      expect(issue.rule, ValidationRule.vr3ComboNotes);
      expect(issue.fieldIds, <String>['maxCombo']);
      expect(issue.message, contains('MAX COMBO（1601）'));
      expect(issue.message, contains('総ノーツ数（推定 1600）'));
    });

    test('VR-3 境界不発: maxCombo == totalNotes', () {
      // maxCombo=1600 は VR-3′ 境界（== S）でも不発・VR-1 は S == totalNotes で不発。
      expect(validate(base(maxCombo: 1600), totalNotes: 1600), isEmpty);
    });

    test('skip 契約: totalNotes = null では VR-1/VR-3 を評価しない', () {
      // matchedSong 不在（4 パス）・未収録曲はルールの欠損入力として skip（設計 §5）。
      expect(validate(base()), isEmpty);
      // VR-3′（判定合計との恒等式・DB 不要）は従来どおり発火する（段階 A 回帰）。
      final List<ValidationIssue> issues = validate(
        base(maxCombo: 1601),
        totalNotes: null,
      );
      expect(issues.single.rule, ValidationRule.vr3ComboJudgments);
    });

    test('同時発火: VR-1 と VR-3 は既存 issue の後に VR-1 → VR-3 の順で並ぶ', () {
      // maxCombo=1600 は S=1600 で VR-3′ 境界不発・totalNotes=1599 で VR-1/VR-3 両発火。
      final List<ValidationIssue> issues = validate(
        base(maxCombo: 1600),
        totalNotes: 1599,
      );
      expect(
        issues.map((ValidationIssue i) => i.rule).toList(),
        <ValidationRule>[
          ValidationRule.vr1JudgmentNotes,
          ValidationRule.vr3ComboNotes,
        ],
      );
    });
  });

  test('全項目 null でも例外を投げず空リストを返す', () {
    expect(
      validate(
        base(score: null, cool: null, great: null, good: null, bad: null),
      ),
      isEmpty,
    );
  });

  group('ValidationIssue の値としての同値性', () {
    test('同じ rule・fieldIds・message は等しい', () {
      const ValidationIssue a = ValidationIssue(
        rule: ValidationRule.vr2JudgmentScore,
        fieldIds: <String>['score', 'cool'],
        message: 'x',
      );
      const ValidationIssue b = ValidationIssue(
        rule: ValidationRule.vr2JudgmentScore,
        fieldIds: <String>['score', 'cool'],
        message: 'x',
      );
      const ValidationIssue c = ValidationIssue(
        rule: ValidationRule.vr2JudgmentScore,
        fieldIds: <String>['score'],
        message: 'x',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
