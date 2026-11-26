// 自己ベスト（FR-7）判定の純粋関数モジュール。
//
// WHY: UI やストアから切り離した純粋関数にすることで、FR-11 詳細・FR-10 一覧・
// 将来の F-1 上達支援（一覧 ★ / フィルタ）のどこからでも同じ判定を再利用できる
//（DIP・FR-7 設計確認書 §2.1 / §7）。比較キーは 1 本の String 抽象（key）で受け取り、
// v1 では songName 完全一致、将来 song_id + difficulty 着地時は「組み立て側」だけ
// 差し替えて resolver 自体は不変にする。
//
// v1 の既知限界: 同 key（songName）内では難易度をまたぐスコアが比較競合する
//（v1 は difficulty 未記録のため）。song_id + difficulty 着地時に解消する課題
//（FR-7 設計確認書 §1.2・リード承認条件 2026-11-22）。
//
// スコアスケールは HC 期で共通（100000 点満点）のため version は比較キーに含めない。
// シリーズ横断（hc_prev 世代等の独自スケール）比較は将来課題（設計確認書 §1.3）。
import 'package:flutter/foundation.dart';

/// 自己ベスト判定の入力候補 1 件。
///
/// WHY: PlayRecord を直接受けず plain 値のみで受けることで UI / ストアに依存せず、
/// key（v1: songName・将来: songId + difficulty）の組み立て側を自由に差し替えられる。
@immutable
class SelfBestCandidate {
  const SelfBestCandidate({
    required this.id,
    required this.key,
    required this.score,
    required this.playedAt,
  });

  /// レコード id。
  final String id;

  /// 比較キー（v1: songName。未確定は null）。
  final String? key;

  /// スコア（null なら比較対象外）。
  final int? score;

  /// 記録日時（同点時の「先行」判定に使用）。
  final DateTime playedAt;
}

/// 自己ベストとみなすレコード id の集合を返す。
///
/// 規約（FR-7 設計確認書 §2・リード承認済み）:
/// - key null（未確定・v1 では songName null）・score null は比較対象外
///   （best にもならない・他のレコードの判定にも影響しない）
/// - key ごとに独立に判定する（別キーは互いに影響しない）
/// - 同点は最古（playedAt）を best 維持し、後発の同点は外れる
/// - 同点かつ同時刻は id の辞書順で決定的に 1 件に決まる
Set<String> resolveSelfBestIds(List<SelfBestCandidate> candidates) {
  final Map<String, List<SelfBestCandidate>> groups =
      <String, List<SelfBestCandidate>>{};
  for (final SelfBestCandidate candidate in candidates) {
    final String? key = candidate.key;
    if (key == null || candidate.score == null) {
      continue;
    }
    (groups[key] ??= <SelfBestCandidate>[]).add(candidate);
  }
  final Set<String> bestIds = <String>{};
  for (final List<SelfBestCandidate> entries in groups.values) {
    final String? bestId = _pickBestId(entries);
    if (bestId != null) {
      bestIds.add(bestId);
    }
  }
  return bestIds;
}

/// 同キー記録群から best 1 件を決定する（最大スコア → 最古 → id 辞書順）。
String? _pickBestId(List<SelfBestCandidate> entries) {
  int? maxScore;
  for (final SelfBestCandidate entry in entries) {
    final int score = entry.score!;
    if (maxScore == null || score > maxScore) {
      maxScore = score;
    }
  }
  if (maxScore == null) {
    return null;
  }
  SelfBestCandidate? best;
  for (final SelfBestCandidate entry in entries) {
    if (entry.score != maxScore) {
      continue;
    }
    if (best == null || _isOlderThan(entry, best)) {
      best = entry;
    }
  }
  return best?.id;
}

/// 同点の「先行」判定（最古優先・同時刻は id 辞書順で決定的に）。
bool _isOlderThan(SelfBestCandidate a, SelfBestCandidate b) {
  if (a.playedAt.isBefore(b.playedAt)) {
    return true;
  }
  if (a.playedAt.isAfter(b.playedAt)) {
    return false;
  }
  return a.id.compareTo(b.id) < 0;
}
