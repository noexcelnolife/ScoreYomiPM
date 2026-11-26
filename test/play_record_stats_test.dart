// lib/data/play_record_stats.dart の単体テスト（v4 案3・設計確認書 §4・v2 改訂版）。
//
// v2 改訂（ユーザー指示・docs/v4_list_best_stats_design_2026-11-23.md 冒頭）:
// 自己ベストのグループキーを (曲名, レベル) から (曲名, 難易度) へ変更。
// レベルはバージョンによって変更され得るため比較の識別子に使わない。
//
// 検証対象:
// (1) 同一 (曲名, 難易度) 3 件のうち最高スコアの行のみベスト
// (2) 同点の最高スコアは両行ベスト
// (3) 同曲名で難易度が異なる → 別グループとして両方ベスト。
//     同一曲名で難易度が同じならレベルが違っても同じグループ（v2 改訂の正例）
// (4) pending / songName null / score null は対象外（score 全 null グループは
//     ベストなし）。difficulty null 同士は同一キー（未指定グループ）
// (5) countUniqueSongs: 重複曲名は 1 曲・null 除外
// (6) countFullCombo: fullComboFamily のみ数える（他メダル・null・unknown 除外）
//
// WHY(red-first・v4 案3 運用): 本テストは play_record_stats.dart 実装前に
// 作成し、import 不能＝赤を確認している。赤→緑の 2 コミット割りはリポジトリ
// 中間状態の analyze を壊すため、リードの 0d29308（案2）前例に従い赤実行の
// 証拠をレポートに残した上で実装と同コミットとする（逸脱の記録）。
// v2 再実装でも同方針: 難易度キーへの切替実装前に本改訂版を走らせ、
// レベルキー実装（保全 WIP）に対して (3)(4) が実行時失敗＝赤であることを
// 確認してから実装に入る。

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_stats.dart';

/// テスト用レコードを直接組み立てるヘルパー。
///
/// WHY: ドラフト経由（toPlayRecord）だと正規化が挟まるため、集計ロジックの
/// 入力境界（score null・songName null・未知メダル文字列）を素の値で制御する。
PlayRecord _rec({
  required String id,
  String? songName,
  int? level,
  GameDifficulty? difficulty,
  int? score,
  PlayRecordStatus status = PlayRecordStatus.confirmed,
  String? clearMedal,
  DateTime? playedAt,
}) {
  return PlayRecord(
    id: id,
    playedAt: playedAt ?? DateTime(2026, 11, 20),
    songName: songName,
    score: score,
    cool: null,
    great: null,
    good: null,
    bad: null,
    maxCombo: null,
    level: level,
    difficulty: difficulty,
    clearMedal: clearMedal,
    status: status,
    source: PlayRecordSource.playshare,
    resultImagePath: '',
  );
}

void main() {
  group('personalBestRecordIds（キー: 曲名・難易度）', () {
    test('同一 (曲名, 難易度) 3 件のうち最高スコアの行のみベスト', () {
      final List<PlayRecord> records = <PlayRecord>[
        _rec(
          id: 'hi',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          score: 100000,
        ),
        _rec(
          id: 'mid',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          score: 99999,
        ),
        _rec(
          id: 'low',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          score: 1,
        ),
      ];

      expect(personalBestRecordIds(records), <String>{'hi'});
    });

    test('同点の最高スコアは両行ベスト', () {
      // WHY: 決定的なタイブレーク規約がないため、実測が同じ全行をベストとする
      //（設計確認書 §1）。
      final List<PlayRecord> records = <PlayRecord>[
        _rec(
          id: 't1',
          songName: 'A',
          difficulty: GameDifficulty.ex,
          score: 100000,
        ),
        _rec(
          id: 't2',
          songName: 'A',
          difficulty: GameDifficulty.ex,
          score: 100000,
        ),
        _rec(
          id: 'under',
          songName: 'A',
          difficulty: GameDifficulty.ex,
          score: 99999,
        ),
      ];

      expect(personalBestRecordIds(records), <String>{'t1', 't2'});
    });

    test('同曲名で難易度が異なるなら別グループ・難易度同一ならレベル違っても同一グループ', () {
      // WHY: v2 改訂の核心。レベルはバージョンで変わり得るため識別子に使わない
      //（ユーザー指示）。難易度キーなら EXH/MAX 相当（現行 4 種では EX と HYPER）
      // は別グループ、同一難易度内でレベルだけ違う行は同一グループ。
      final List<PlayRecord> records = <PlayRecord>[
        _rec(
          id: 'hyper-lv42',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          level: 42,
          score: 90000,
        ),
        // 同一曲名・同一難易度・レベル違い → 同じグループ（下位スコアなのでベストは 1 行のみ）。
        _rec(
          id: 'hyper-lv45',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          level: 45,
          score: 80000,
        ),
        // 難易度違い → 別グループとして各自ベスト。
        _rec(
          id: 'ex',
          songName: 'A',
          difficulty: GameDifficulty.ex,
          level: 45,
          score: 70000,
        ),
      ];

      expect(personalBestRecordIds(records), <String>{'hyper-lv42', 'ex'});
    });

    test('pending・songName null・score null は対象外。difficulty null 同士は同一キー', () {
      final List<PlayRecord> records = <PlayRecord>[
        _rec(
          id: 'pend',
          songName: 'A',
          difficulty: GameDifficulty.hyper,
          score: 100000,
          status: PlayRecordStatus.pending,
        ),
        _rec(
          id: 'nosong',
          songName: null,
          difficulty: GameDifficulty.hyper,
          score: 100000,
        ),
        // 曲名 B・difficulty null・score 全 null → ベストなし。
        _rec(id: 'b-nullscore', songName: 'B', difficulty: null, score: null),
        // 曲名 C・difficulty null グループ: 500 の行のみベスト（score null は比較対象外）。
        _rec(id: 'c-hi', songName: 'C', difficulty: null, score: 500),
        _rec(id: 'c-null', songName: 'C', difficulty: null, score: null),
        // 曲名 C・difficulty 指定ありは別グループ（同一キー未指定グループと分離）。
        _rec(
          id: 'c-ex',
          songName: 'C',
          difficulty: GameDifficulty.ex,
          score: 300,
        ),
      ];

      // pending と曲名 null は最高スコアでも除外。曲名 C は null グループ 500 と
      // EX グループ 300 が各自行ベスト（難易度未指定=同一キーの扱い）。
      expect(personalBestRecordIds(records), <String>{'c-hi', 'c-ex'});
    });
  });

  group('countUniqueSongs', () {
    test('重複曲名は 1 曲・null・pending は除外', () {
      final List<PlayRecord> records = <PlayRecord>[
        _rec(id: 'a1', songName: 'A', score: 1),
        _rec(id: 'a2', songName: 'A', score: 2),
        _rec(id: 'b1', songName: 'B', score: 3),
        _rec(id: 'nullsong', songName: null, score: 4),
        _rec(
          id: 'pending',
          songName: 'C',
          score: 5,
          status: PlayRecordStatus.pending,
        ),
      ];

      expect(countUniqueSongs(records), 2);
    });
  });

  group('countFullCombo', () {
    test('fullComboFamily のみ数える（他メダル・null・unknown 除外・pending も含む）', () {
      final List<PlayRecord> records = <PlayRecord>[
        _rec(id: 'fc1', songName: 'A', clearMedal: 'fullComboFamily'),
        _rec(
          id: 'fc2-pending',
          songName: null,
          clearMedal: 'fullComboFamily',
          status: PlayRecordStatus.pending,
        ),
        _rec(id: 'clear', songName: 'B', clearMedal: 'clear'),
        _rec(id: 'none', songName: 'C', clearMedal: null),
        _rec(id: 'unknown', songName: 'D', clearMedal: 'unknown'),
      ];

      // WHY: メダルは譜面達成の事実。曲名未入力（pending）の間に手入力した
      // メダルも達成記録として数える（設計確認書 §1・母集団=全レコード）。
      expect(countFullCombo(records), 2);
    });
  });
}
