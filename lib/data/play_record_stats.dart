// 記録一覧の統計・自己ベスト集計（v4 案3・設計確認書 §1・v2 改訂:
// ベストのグループキーを (曲名, 難易度) とする—レベルはバージョンで
// 変わり得るため識別子にしない）。
//
// WHY 純 Dart 分離: UI（play_records_screen.dart）から独立して単体テストできる
// ようにするため。一覧画面のリビルドごとに再計算しても CSV 保存規模（数百件）
// では体感差なし（設計確認書 §2 の再計算方針）。
//
// WHY リポジトリ不変: ソート・ベスト計算は画面側で完結させ、保存契約
// （PlayRecordRepository.listAll の実施日新しい順）は変更しない（スコープ最小化）。
import '../validation/validation_issue.dart';
import 'play_record.dart';

/// (曲名, 難易度) 別グループの最高スコアを持つレコード ID の集合を返す。
///
/// 母集団は `status == confirmed && songName != null && score != null` の行のみ。
/// 同点の最高スコアは全行がベストになる（決定的なタイブレーク規約がないため、
/// 実測が同じものを「最高記録」と呼ぶのは違和感がある—設計確認書 §1 の裁定）。
///
/// WHY 難易度キー（v2 改訂・ユーザー指示 2026-11-23）: spec §4.1 のとおり
/// レベルはバージョンによって変更され得るため比較の識別子にしない。
/// 旧案3 v1 のレベルキーでは、同一難易度でレベルだけ違う行（バージョン
/// 更新での格上げ）が別グループ化され自己ベストが分断される誤りがあった。
/// WHY 曲名キー: songId は現行実装で常時 null のため併用して識別する
///（同名異曲は現状維持裁定・設計確認書 §1）。
/// WHY difficulty null: 未指定同士は同一キー扱い。v5 導入前の旧レコードは
/// すべて null でひとまとまりになり、旧データでもベスト判定が成立する。
/// WHY score null 除外: 未確定・スコア不明の間にベスト判定はできない。
/// score 全 null のグループはベストなしとなる。
Set<String> personalBestRecordIds(List<PlayRecord> records) {
  final Map<(String, GameDifficulty?), int> bestScores =
      <(String, GameDifficulty?), int>{};
  final Map<(String, GameDifficulty?), Set<String>> bestIds =
      <(String, GameDifficulty?), Set<String>>{};

  for (final PlayRecord record in records) {
    if (record.status != PlayRecordStatus.confirmed) {
      continue;
    }
    final String? songName = record.songName;
    final int? score = record.score;
    if (songName == null || score == null) {
      continue;
    }
    final (String, GameDifficulty?) key = (songName, record.difficulty);
    final int? currentBest = bestScores[key];
    if (currentBest == null || score > currentBest) {
      bestScores[key] = score;
      bestIds[key] = <String>{record.id};
    } else if (score == currentBest) {
      bestIds[key]!.add(record.id);
    }
  }

  return bestIds.values.expand((Set<String> ids) => ids).toSet();
}

/// 確定記録に含まれる重複なしの曲名数を返す。
///
/// WHY: 「何曲プレイしたか」の要約表示（設計確認書 §1）。songName null
/// （曲名未入力の pending）と pending 自体は曲数の母集団から除外する。
int countUniqueSongs(List<PlayRecord> records) {
  final Set<String> songNames = <String>{
    for (final PlayRecord record in records)
      if (record.status == PlayRecordStatus.confirmed &&
          record.songName != null)
        record.songName!,
  };
  return songNames.length;
}

/// クリアメダル「フルコンボ系」の記録数を返す（status 横断・全レコード母集団）。
///
/// WHY メダルのみ・status 横断: メダルは譜面達成の事実であり、曲名 OCR に
/// 失敗しただけの未確定行の達成を数え落とさないため（設計確認書 §1・案1 で
/// 既出の裁定を踏襲）。
int countFullCombo(List<PlayRecord> records) {
  final String fullComboName = ClearMedalCategory.fullComboFamily.name;
  return records
      .where((PlayRecord record) => record.clearMedal == fullComboName)
      .length;
}
