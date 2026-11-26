// 自己ベスト判定（FR-7）純粋関数 resolver のテスト。
//
// 検証対象:
// (a) 初回記録（同キー 1 件）は自動的に best
// (b) 後発の高スコアが best になり、先行の低スコアは best を外れる
// (c) 同点は最古の記録のみ best（後発の同点は外れる）
// (d) 別キーの記録は互いに影響しない
// (e) 未確定（key null）・score null は比較対象外
// (f) 全レコードが対象外なら空集合
// (g) 同点かつ同時刻は id の辞書順で決定的に 1 件に決まる
//
// WHY: resolver の結果は FR-11 詳細の「自己ベスト」表示に直結するため、
// 決定性（同入力 → 同出力）をテストで固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/best/self_best_resolver.dart';

SelfBestCandidate _c({
  required String id,
  String? key,
  int? score,
  DateTime? at,
}) {
  return SelfBestCandidate(
    id: id,
    key: key,
    score: score,
    playedAt: at ?? DateTime(2026, 11, 22),
  );
}

void main() {
  final DateTime t1 = DateTime(2026, 11, 20);
  final DateTime t2 = DateTime(2026, 11, 21);
  final DateTime t3 = DateTime(2026, 11, 22);

  group('resolveSelfBestIds', () {
    test('初回記録（同キー1件・scoreあり）は best になる', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: 'テスト曲', score: 90000, at: t1),
      ]);
      expect(best, <String>{'r-1'});
    });

    test('後発の高スコアのみ best になり、先行の低スコアは外れる', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: 'テスト曲', score: 90000, at: t1),
        _c(id: 'r-2', key: 'テスト曲', score: 95000, at: t2),
      ]);
      expect(best, <String>{'r-2'});
    });

    test('同点は最古の記録のみ best（後発同点は外れる）', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: 'テスト曲', score: 90000, at: t1),
        _c(id: 'r-2', key: 'テスト曲', score: 90000, at: t2),
      ]);
      expect(best, <String>{'r-1'});
    });

    test('別キーの記録は互いに影響しない', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: '曲A', score: 90000, at: t1),
        _c(id: 'r-2', key: '曲A', score: 95000, at: t2),
        _c(id: 'r-3', key: '曲A', score: 80000, at: t3),
        _c(id: 'r-4', key: '曲B', score: 99000, at: t3),
      ]);
      expect(best, <String>{'r-2', 'r-4'});
    });

    test('未確定（key null）と score null は比較対象外', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: 'テスト曲', score: 90000, at: t1),
        _c(id: 'r-2', key: null, score: 99999, at: t2),
        _c(id: 'r-3', key: 'テスト曲', score: null, at: t3),
      ]);
      expect(best, <String>{'r-1'});
    });

    test('全レコードが対象外なら空集合', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-1', key: null, score: 90000, at: t1),
        _c(id: 'r-2', key: 'テスト曲', score: null, at: t2),
      ]);
      expect(best, isEmpty);
    });

    test('同点かつ同時刻は id の辞書順で 1 件に決定する', () {
      final Set<String> best = resolveSelfBestIds(<SelfBestCandidate>[
        _c(id: 'r-b', key: 'テスト曲', score: 90000, at: t1),
        _c(id: 'r-a', key: 'テスト曲', score: 90000, at: t1),
      ]);
      expect(best, <String>{'r-a'});
    });
  });
}
