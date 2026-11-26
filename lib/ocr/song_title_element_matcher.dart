// ST-5 本実装: 曲名照合の genre 行混入対策（要素単位照合）。
//
// 曲名バンド（songTitle リージョン）のクロップにはジャンル行
// （例 SOFT ROCK LONG）と曲名行が同写りになる。従来の全文 join 照合は
// ジャンル接頭辞でレーベンシュタイン距離が膨らみ、自動決定が破綻する
// （実測: join 全文 0/7 vs 行単位 5/7、docs/st5_title_matching_verification_plan.md）。
//
// 本クラスは OCR 要素を垂直方向の中心（cy）近接度で行にクラスタリングし、
// 「行連結テキスト＋単一要素」を照合候補として既存 [SongTitleMatcher] に
// 投げ、全体最良（距離最小）の結果を採用する。SongTitleMatcher の契約は
// 変更しない（委譲で利用）。
//
// 実 fixture で確認された要素構造の要点:
// - 曲名は同一行内で複数要素に分割される（例 Homesiok + Pt.2&3）
//   → 行内連結候補が必須
// - genre 行と曲名行の中心差は 32〜57px、同一行内差は ≤2.5px
//   （クロップ高≈114px）→ 中心Y近接クラスタリングで分離可能
import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';

/// 照合候補。行の平均中心 Y（rowCy）はタイブレーク（下側の行優先）に使う。
class _SongTitleCandidate {
  final String text;
  final double rowCy;

  /// WHY: 単一要素行は行連結と同文になるため行連結候補として登録され、
  /// 複数要素行から生成された単一要素候補（＝行の断片）のみ false になる。
  /// 断片は全文でない分ノイズ度が高いため、最小長ガード
  /// （[_SongTitleElementMatcher._isEligible]）の閾値を分ける区別として使う。
  final bool isRowJoined;

  const _SongTitleCandidate(this.text, this.rowCy, {required this.isRowJoined});
}

/// songTitle リージョンの OCR 要素から曲名を要素単位で照合する。
class SongTitleElementMatcher {
  final SongTitleMatcher _matcher;

  SongTitleElementMatcher(this._matcher);

  /// songTitle リージョンの OCR 要素から曲名を照合する。
  ///
  /// 候補（行連結＋単一要素）ごとに [SongTitleMatcher.match] を実行し、
  /// 全体最良（距離最小・同距離は後述のタイブレーク）を採用する。
  /// 全候補が不一致の場合は従来動作（全要素 join の全文照合）へ
  /// フォールバックし、FR-3 表示用の rawOcrText を保全する。
  /// 要素が空または全て空白のみの場合は不一致結果を返す。
  SongMatchResult match(List<OcrElement> elements) {
    final candidates = _buildCandidates(elements);
    SongMatchResult? best;
    var bestRowCy = 0.0;
    var anyMatched = false;
    for (final candidate in candidates) {
      final result = _matcher.match(candidate.text);
      // 不一致候補・最小長ガード不適合候補は最良候補の選定対象外
      // （anyMatched を立てないため、全文 join フォールバックへ転落する）
      if (!result.hasMatch || !_isEligible(result, candidate.isRowJoined)) {
        continue;
      }
      anyMatched = true;
      if (_isBetter(best, bestRowCy, result, candidate.rowCy)) {
        best = result;
        bestRowCy = candidate.rowCy;
      }
    }
    if (!anyMatched) {
      // WHY: 全候補不一致でも全文 join にフォールバックする。
      // 曲名自体の OCR 誤読（距離 4 程度）のケースで FR-3 表示用
      // rawOcrText と TopK 候補の可能性を保全するため（従来動作と同等）。
      return _matcher.match(_joinAllTexts(elements));
    }
    return best!;
  }

  /// 候補 result を最良候補の選定対象にしてよいか（最小長ガード）。
  ///
  /// WHY: 短い無関係要素（EX/PET/M/CORE/UP 等）が短い辞書キー（朧/o†o は
  /// 1〜3 字）に dist≤3 で誤マッチし、曲名行の正候補を crowd-out する
  /// 実害が r3 計測で 9 枚観測された（行連結 4+単一 5・
  /// docs/st5_e_min_length_guard_design_confirmation_2026-11-22.md §1.3）。
  /// 閾値根拠は 2100 曲 DB（db/popn_hc_main_v1.json・unique normalizedKey
  /// 2086）の実測: 正規化キー長 ≤3 は全体の 5.3% で、dist≤3 の曖昧性は
  /// len4 が膝（n≤3 中央 5/max 28 → len5 で中央 1）。よって行連結は
  /// dist≤1 なら 2 字以上（朧1→朧 等 dist1 の短い正当一致を保護）、
  /// dist2-3 なら 4 字以上（実データの dist2-3 正解は 6 字以上で
  /// 安全マージン込み）とする。複数要素行の断片は全文でない分
  /// ノイズ度が高いため dist≥1 を一律 5 字以上。dist 0 は完全一致で
  /// 常に採用（短キー実在の保護・o†o への oto 直一致など）。
  static bool _isEligible(SongMatchResult result, bool isRowJoined) {
    final dist = result.bestDistance;
    if (dist == null) {
      return true; // 防御: 現行 SongTitleMatcher では hasMatch なら非 null
    }
    if (dist == 0) {
      return true;
    }
    if (!isRowJoined) {
      return result.normalizedOcrText.length >= 5;
    }
    if (dist == 1) {
      return result.normalizedOcrText.length >= 2;
    }
    return result.normalizedOcrText.length >= 4;
  }

  /// 照合候補のテキスト列を返す（テスト・デバッグ用）。
  ///
  /// 各行について「行連結 → 単一要素」の順で、行は上から下の順。
  List<String> candidateTexts(List<OcrElement> elements) =>
      _buildCandidates(elements).map((c) => c.text).toList();

  /// 照合候補を生成する（重複排除済み）。
  List<_SongTitleCandidate> _buildCandidates(List<OcrElement> elements) {
    final candidates = <_SongTitleCandidate>[];
    final seen = <String>{};
    for (final row in clusterRows(elements)) {
      final rowCy = _meanCenterY(row);
      final texts = <String>[];
      final joined = row
          .map((e) => e.text.trim())
          .where((t) => t.isNotEmpty)
          .join(' ');
      if (joined.isNotEmpty) {
        texts.add(joined);
      }
      for (final element in row) {
        final text = element.text.trim();
        if (text.isNotEmpty) {
          texts.add(text);
        }
      }
      for (var i = 0; i < texts.length; i++) {
        final text = texts[i];
        // 単一要素行は連結テキストと同一テキストになるため重複を排除する
        if (seen.add('$rowCy\x00$text')) {
          // WHY: texts の先頭は行連結テキスト（単一要素行では同文）。
          // 以降は複数要素行の単一要素候補（断片）→ isRowJoined=false。
          candidates.add(_SongTitleCandidate(text, rowCy, isRowJoined: i == 0));
        }
      }
    }
    return candidates;
  }

  /// OCR 要素を垂直中心（cy）近接度で行にクラスタリングする。
  ///
  /// 返す各行は左→右ソート、行リストは上→下順。
  /// 許容差は平均要素高の半分とする。実データ（クロップ高≈114px）では
  /// genre 行と曲名行の中心差が 32〜57px、同一行内の要素差が ≤2.5px で
  /// あるため、平均要素高の半分（≈20px）で十分に行を分離できる。
  static List<List<OcrElement>> clusterRows(List<OcrElement> elements) {
    if (elements.isEmpty) {
      return const [];
    }
    final sorted = [...elements]..sort(_compareVertical);
    final totalHeight = sorted.fold<double>(0, (sum, e) => sum + _height(e));
    final tolerance = totalHeight / sorted.length / 2;
    final rows = <List<OcrElement>>[];
    var rowCy = 0.0;
    for (final element in sorted) {
      final cy = _centerY(element);
      if (rows.isEmpty || (cy - rowCy).abs() > tolerance) {
        rows.add([element]);
        rowCy = cy;
      } else {
        rows.last.add(element);
        rowCy = _meanCenterY(rows.last);
      }
    }
    // 各行内は左→右で並べ替え（行連結テキストの読み順を保証）
    for (final row in rows) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    }
    return rows;
  }

  /// 候補 result の方が現行 best より良い場合に true を返す。
  ///
  /// 優先順: ①レーベンシュタイン距離が小さい ②正規化テキストが長い
  /// ③行の中心 Y が大きい（画面下側）④先着（決定性保証）。
  static bool _isBetter(
    SongMatchResult? best,
    double bestRowCy,
    SongMatchResult result,
    double rowCy,
  ) {
    if (best == null || best.bestDistance == null) {
      return true;
    }
    final dist = result.bestDistance;
    if (dist == null) {
      return false;
    }
    final bestDist = best.bestDistance!;
    if (dist != bestDist) {
      return dist < bestDist;
    }
    // WHY: 同距離ではより具体的（正規化長が長い）な候補を優先する。
    // ジャンル断片（例 'pet'）が短い曲名キー（実 seed に '朧' の 1 字キーが
    // 存在）と偶然同距離になる誤照合を緩和するため。
    final lengthDiff =
        result.normalizedOcrText.length - best.normalizedOcrText.length;
    if (lengthDiff != 0) {
      return lengthDiff > 0;
    }
    // WHY: 同距離・同長では画面下側の行を優先する。
    // 【レイアウト前提】プレーシェアは genre 行が曲名行の上にある固定
    // レイアウトであり、この優先規則はその前提に依存する。将来
    // プレーシェア以外のレイアウト（例: 実機撮影）へ対応する際は、
    // genre 行の位置が逆になる可能性があるため本規則の再検討が必要。
    return rowCy > bestRowCy;
  }

  static int _compareVertical(OcrElement a, OcrElement b) {
    final byCy = _centerY(a).compareTo(_centerY(b));
    if (byCy != 0) {
      return byCy;
    }
    return a.boundingBox.left.compareTo(b.boundingBox.left);
  }

  static double _centerY(OcrElement element) =>
      (element.boundingBox.top + element.boundingBox.bottom) / 2;

  static double _height(OcrElement element) =>
      element.boundingBox.bottom - element.boundingBox.top;

  static double _meanCenterY(List<OcrElement> row) {
    var sum = 0.0;
    for (final element in row) {
      sum += _centerY(element);
    }
    return sum / row.length;
  }

  static String _joinAllTexts(List<OcrElement> elements) =>
      elements.map((e) => e.text.trim()).where((t) => t.isNotEmpty).join(' ');
}
