// ST-5 レーベンシュタイン距離
//
// 2文字列の編集距離を動的計画法で計算する。
// spec.md §5 ST-5 曲名辞書照合で使用。
//
// 計算量: O(m*n) 時間、O(min(m,n)) 空間（行ごとローリング）

library;

/// [a] と [b] のレーベンシュタイン距離を返す。
///
/// 挿入・削除・置換の各操作コストは 1。
int levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  // 短い方を行にして空間を節約
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;

  final previous = <int>[];
  for (int i = 0; i <= shorter.length; i++) {
    previous.add(i);
  }
  final current = <int>[];

  for (int i = 1; i <= longer.length; i++) {
    current.clear();
    current.add(i);
    final ch = longer[i - 1];
    for (int j = 1; j <= shorter.length; j++) {
      final cost = shorter[j - 1] == ch ? 0 : 1;
      current.add(
        _min3(
          previous[j] + 1, // 削除
          current[j - 1] + 1, // 挿入
          previous[j - 1] + cost, // 置換
        ),
      );
    }
    final temp = previous;
    previous.clear();
    previous.addAll(current);
    current.clear();
    current.addAll(temp);
  }

  return previous[shorter.length];
}

int _min3(int a, int b, int c) {
  final m = a < b ? a : b;
  return m < c ? m : c;
}
