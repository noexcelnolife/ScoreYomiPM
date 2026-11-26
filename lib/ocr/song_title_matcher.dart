// ST-5 曲名辞書照合（レーベンシュタイン距離）
//
// OCR で抽出した曲名を辞書と照合し、最も近い候補を返す。
// spec.md §5.3 ST-5 に整合:
//   - 候補1件なら自動決定
//   - 不確実時は候補TopK返し（FR-3 に委ねる）
//
// ST-6: SongDictionary ではなく SongRepository 抽象を受け取る（契約を壊さない）。

import 'levenshtein.dart';
import 'song_repository.dart';
import 'song_title_normalizer.dart';

/// 曲名照合の結果。
class SongMatchResult {
  /// OCR で抽出した生テキスト（正規化前）。
  final String rawOcrText;

  /// 正規化済み OCR テキスト。
  final String normalizedOcrText;

  /// 最も近い辞書エントリ（正規化済み）。マッチなしの場合 null。
  final String? bestMatchNormalized;

  /// 最も近い辞書エントリの元表記。マッチなしの場合 null。
  final String? bestMatchOriginal;

  /// bestMatchNormalized とのレーベンシュタイン距離。
  /// マッチなしの場合 null。
  final int? bestDistance;

  /// TopK 候補（距離昇順）。各エントリ: [normalizedTitle, originalTitle, distance]。
  final List<SongMatchCandidate> topCandidates;

  /// 自動決定フラグ（距離 ≤ autoThreshold かつ候補が1件のみの場合 true）。
  final bool autoDecided;

  const SongMatchResult({
    required this.rawOcrText,
    required this.normalizedOcrText,
    required this.bestMatchNormalized,
    required this.bestMatchOriginal,
    required this.bestDistance,
    required this.topCandidates,
    required this.autoDecided,
  });

  /// 辞書照合に成功したか（ベストマッチが存在するか）。
  bool get hasMatch => bestMatchNormalized != null;

  @override
  String toString() =>
      'SongMatchResult(raw: $rawOcrText, best: $bestMatchOriginal '
      '(dist: $bestDistance), auto: $autoDecided, '
      'candidates: ${topCandidates.length})';
}

/// 曲名照合の候補エントリ。
class SongMatchCandidate {
  /// 正規化済みタイトル。
  final String normalizedTitle;

  /// 元の表記。
  final String originalTitle;

  /// レーベンシュタイン距離。
  final int distance;

  const SongMatchCandidate({
    required this.normalizedTitle,
    required this.originalTitle,
    required this.distance,
  });
}

/// 曲名辞書照合エンジン。
///
/// [SongRepository] 抽象を受け取るため、bundledSeed/downloadedMain/
// localAdditional のいずれのソースでも照合可能。
class SongTitleMatcher {
  /// 自動決定の閾値（距離 ≤ この値で、かつ候補1件なら自動決定）。
  static const int autoThreshold = 1;

  /// TopK 候補を返す最大距離閾値（距離 ≤ この値で候補として列挙）。
  static const int candidateThreshold = 3;

  /// TopK 候補の最大件数。
  static const int maxCandidates = 3;

  final SongRepository _repository;

  SongTitleMatcher(SongRepository repository) : _repository = repository;

  /// [ocrText] を辞書と照合して [SongMatchResult] を返す。
  SongMatchResult match(String ocrText) {
    final normalized = normalizeSongTitle(ocrText);

    if (normalized.isEmpty) {
      return const SongMatchResult(
        rawOcrText: '',
        normalizedOcrText: '',
        bestMatchNormalized: null,
        bestMatchOriginal: null,
        bestDistance: null,
        topCandidates: [],
        autoDecided: false,
      );
    }

    // 完全一致チェック（正規化後）
    if (_repository.containsNormalizedKey(normalized)) {
      final entry = _repository.findByNormalizedKey(normalized);
      return SongMatchResult(
        rawOcrText: ocrText,
        normalizedOcrText: normalized,
        bestMatchNormalized: normalized,
        bestMatchOriginal: entry?.title ?? normalized,
        bestDistance: 0,
        topCandidates: [
          SongMatchCandidate(
            normalizedTitle: normalized,
            originalTitle: entry?.title ?? normalized,
            distance: 0,
          ),
        ],
        autoDecided: true,
      );
    }

    // 全辞書エントリとの距離を計算
    final candidates = <SongMatchCandidate>[];
    final seenTitles = <String>{};
    for (final entry in _repository.allSongs) {
      final distance = levenshteinDistance(normalized, entry.normalizedKey);
      // WHY: seed には同名異曲（例: Homesick Pt.2&3 の通常版とLONG版）が同じ
      // normalizedKey で複数件入ることがある（実 seed で確認・2026-11-22）。
      // 照合上は同一候補なので 1 件に畳む。畳まないと「候補1件なら自動決定」
      // の契約（autoDecided = topK.length == 1）が崩れ、同名異曲を含む曲の
      // 自動決定がすべて失敗する。
      if (distance <= candidateThreshold &&
          seenTitles.add(entry.normalizedKey)) {
        candidates.add(
          SongMatchCandidate(
            normalizedTitle: entry.normalizedKey,
            originalTitle: entry.title,
            distance: distance,
          ),
        );
      }
    }

    // 距離昇順でソート、同距離は辞書順（安定ソート）
    candidates.sort((a, b) {
      final d = a.distance - b.distance;
      if (d != 0) return d;
      return a.normalizedTitle.compareTo(b.normalizedTitle);
    });

    // TopK に制限
    final topK = candidates.take(maxCandidates).toList();

    // 自動決定: 候補が1件のみかつ距離 ≤ autoThreshold
    final autoDecided =
        topK.length == 1 && topK.first.distance <= autoThreshold;

    final best = topK.isNotEmpty ? topK.first : null;

    return SongMatchResult(
      rawOcrText: ocrText,
      normalizedOcrText: normalized,
      bestMatchNormalized: best?.normalizedTitle,
      bestMatchOriginal: best?.originalTitle,
      bestDistance: best?.distance,
      topCandidates: topK,
      autoDecided: autoDecided,
    );
  }
}
