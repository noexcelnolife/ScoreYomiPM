/// Lively スコア画面の幾何。
///
/// WHY: Lively は PC 画面の写真で、パネルの位置・倍率・傾きが画像ごとに違う。
/// H&C 用の `FieldExtractor` は「正規化 dx の窓」で値を拾うが、Lively は
/// ラベル列と値列が 3P 以上離れており同じ窓では届かない。そこでラベルの
/// 実測位置から基準点（`ox` / `oy` / `pitch`）を出し、**すべて P 単位
/// （GREAT/GOOD/BAD のラベル中心間隔 = 1P）** で矩形を決める。
/// 実測値の出所: `docs/lively_extraction_pipeline_2026-11-25.md §3`。
library;

import 'dart:math' as math;
import 'dart:ui';

import '../../models/ocr_models.dart';

/// 数値を読む行。`best` は `NumericFieldKind` に無い（記録に保存しない）が、
/// 2 行ブロックの切り出し範囲を決めるために残す。
enum LivelyRow { score, cool, great, good, bad, combo, best }

/// 1 行分の縦位置（P 単位）。
class LivelyRowSpec {
  const LivelyRowSpec(this.row, this.centerY, this.halfHeight);

  final LivelyRow row;
  final double centerY;
  final double halfHeight;

  double get top => centerY - halfHeight;
  double get bottom => centerY + halfHeight;
}

/// 行ごとの縦位置。値は `docs/lively_extraction_pipeline_2026-11-25.md §3` の
/// 実測表そのまま（半高さも含む）。
const List<LivelyRowSpec> livelyRows = <LivelyRowSpec>[
  LivelyRowSpec(LivelyRow.score, -2.65, 1.05),
  LivelyRowSpec(LivelyRow.cool, -0.85, 0.50),
  LivelyRowSpec(LivelyRow.great, 0.05, 0.50),
  LivelyRowSpec(LivelyRow.good, 0.95, 0.50),
  LivelyRowSpec(LivelyRow.bad, 1.90, 0.52),
  LivelyRowSpec(LivelyRow.combo, 3.20, 0.50),
  LivelyRowSpec(LivelyRow.best, 4.85, 0.50),
];

/// 値列の x 範囲（P 単位）。
///
/// WHY: ラベルの右端は 4.2P を超えず、値は右揃えで 12.2〜12.7P に終わる
/// （実測）。この 1 本の範囲で「ラベル文字を数字として読む」事故を防げる。
const double livelyValueLeftP = 4.20;
const double livelyValueRightP = 13.20;

/// 行ブロックの切り出し範囲（P 単位）。パネル 1 パスと同じ規則で読み直すための
/// 別解像度のビュー。
const Rect livelyCounterBlockP = Rect.fromLTRB(-0.60, -1.35, 13.10, 2.42);
const Rect livelyComboBlockP = Rect.fromLTRB(-0.60, 2.60, 13.10, 5.35);
const Rect livelyScoreBlockP = Rect.fromLTRB(4.60, -3.70, 13.20, -1.60);

/// パネル切り出し枠の余白（ラベル列の高さを 1 とした比）。
///
/// WHY: セル位置の基準にこの枠を使うと、検出できたラベルの種類で外接矩形が
/// 変わる（BEST/SCORE が取れると縦に伸びる）。枠は「パネルを全部含むこと」
/// だけに使い、セル位置はパネル 1 パスで取り直した基準点から決める。
const double livelyPadLeft = 0.30;
const double livelyPadRight = 1.25;
const double livelyPadTop = 0.80;
const double livelyPadBottom = 0.25;

/// ラベル語（ML Kit は `COOL` を `COOT` と返すことがある）。
const Set<String> livelyLabelWords = <String>{
  'COOL',
  'COOT',
  'COOC',
  'COO',
  'GREAT',
  'GOOD',
  'BAD',
  'BEST',
  'SCORE',
  'COMBO',
};

/// 要素テキストから英字だけを残す（`GREAT143` → `GREAT`）。
String livelyWordOf(String text) =>
    text.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');

/// 数値のみの要素か（カンマ・空白は落として判定）。
///
/// WHY: Lively の値は 3 桁区切り（`12,345`）で返ることがある。区切りを
/// 落として全桁が数字なら値として採用する。
bool livelyIsNumeric(String text) {
  final trimmed = text.replaceAll(RegExp(r'[\s,]'), '');
  return trimmed.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(trimmed);
}

/// 数値要素から整数を取り出す（カンマ区切りは連結する）。
int? livelyParseInt(String text) {
  final digits = text.replaceAll(RegExp('[^0-9]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}

/// 行ラベルの P 上の中心 y。
double livelyRowCenterP(LivelyRow row) =>
    livelyRows.firstWhere((s) => s.row == row).centerY;

/// パネルの基準点。`ox` は GREAT ラベルの左端 x、`oy` は GREAT の中心 y。
///
/// WHY: P はラベル間隔の実測値なので、画像の解像度・パネルの倍率に依存しない。
/// これが無いとセル矩形が決まらないため、取れなければ抽出を諦める
/// （誤った値を登録するより FR-3 で手入力させるほうが安全）。
class LivelyAnchor {
  const LivelyAnchor({
    required this.ox,
    required this.oy,
    required this.pitch,
    this.labelCount = 0,
  });

  final double ox;
  final double oy;
  final double pitch;

  /// pitch の算出に使えたラベルの数（診断用）。
  final int labelCount;

  double xOf(double p) => ox + p * pitch;

  double yOf(double p) => oy + p * pitch;

  /// P 単位の矩形を px に変換する。
  Rect rectOf(Rect p) =>
      Rect.fromLTRB(xOf(p.left), yOf(p.top), xOf(p.right), yOf(p.bottom));

  /// 行の値セル（ラベルを含まない値列だけ）。
  Rect valueCellOf(LivelyRow row) {
    final spec = livelyRows.firstWhere((s) => s.row == row);
    return rectOf(
      Rect.fromLTRB(livelyValueLeftP, spec.top, livelyValueRightP, spec.bottom),
    );
  }

  /// パネル 1 パスの要素座標を P へ写す。
  double pOfY(double y) => (y - oy) / pitch;

  double pOfX(double x) => (x - ox) / pitch;

  /// ラベル要素列から基準点を作る。
  ///
  /// 行ラベルは `GREAT` を必須とし、`COOL`/`GOOD`/`BAD` のうち取れたものと
  /// 最小二乗で `oy`・`pitch` を決める（ラベルの欠けに強い）。
  static LivelyAnchor? detect(List<OcrElement> elements) {
    final byWord = <String, OcrElement>{};
    for (final e in elements) {
      final word = livelyWordOf(e.text);
      if (!_rowWords.containsKey(word)) continue;
      final prev = byWord[word];
      if (prev == null || _area(e.boundingBox) > _area(prev.boundingBox)) {
        byWord[word] = e;
      }
    }
    final great = byWord['GREAT'];
    if (great == null) return null;
    final fit = _fitAnchor(byWord);
    if (fit == null) return null;
    // ox は行ラベルの左端の中央値。ラベルは左揃えなので、1 つだけ取れた
    // 場合でも GREAT の左端に一致する（`GREAT` 単独より欠けに強い）。
    final lefts = <double>[
      for (final w in _rowWords.keys)
        if (byWord[w] != null) byWord[w]!.boundingBox.left,
    ]..sort();
    final leftMedian = lefts[lefts.length ~/ 2];
    return LivelyAnchor(
      ox: leftMedian,
      oy: fit.oy,
      pitch: fit.pitch,
      labelCount: fit.count,
    );
  }

  static ({double oy, double pitch, int count})? _fitAnchor(
    Map<String, OcrElement> byWord,
  ) {
    final samples = <List<double>>[];
    for (final entry in _rowWords.entries) {
      final element = byWord[entry.key];
      if (element == null) continue;
      samples.add(<double>[entry.value, element.boundingBox.center.dy]);
    }
    if (samples.length < 2) return null;
    var meanP = 0.0;
    var meanY = 0.0;
    for (final s in samples) {
      meanP += s[0];
      meanY += s[1];
    }
    meanP /= samples.length;
    meanY /= samples.length;
    var num = 0.0;
    var den = 0.0;
    for (final s in samples) {
      num += (s[0] - meanP) * (s[1] - meanY);
      den += (s[0] - meanP) * (s[0] - meanP);
    }
    if (den == 0) return null;
    final pitch = num / den;
    if (!pitch.isFinite || pitch <= 0) return null;
    return (oy: meanY - pitch * meanP, pitch: pitch, count: samples.length);
  }

  static double _area(Rect r) => r.width * r.height;
}

/// 単語 → 行の P 上の中心 y（最小二乗の標本）。
const Map<String, double> _rowWords = <String, double>{
  'COOL': -0.85,
  'COOT': -0.85,
  'COOC': -0.85,
  'COO': -0.85,
  'GREAT': 0.05,
  'GOOD': 0.95,
  'BAD': 1.90,
};

/// パネルを全部含む切り出し枠（px）。ラベル矩形の外接矩形 + 余白。
class LivelyPanelBox {
  const LivelyPanelBox(this.rect);

  final Rect rect;

  /// ラベル要素（`livelyLabelWords`）の外接矩形から作る。
  static LivelyPanelBox? fromLabels(
    List<OcrElement> elements, {
    int? imageWidth,
    int? imageHeight,
  }) {
    Rect? cluster;
    for (final e in elements) {
      if (!livelyLabelWords.contains(livelyWordOf(e.text))) continue;
      cluster = cluster == null
          ? e.boundingBox
          : cluster.expandToInclude(e.boundingBox);
    }
    if (cluster == null) return null;
    final h = cluster.height;
    if (h <= 0) return null;
    var rect = Rect.fromLTRB(
      cluster.left - livelyPadLeft * h,
      cluster.top - livelyPadTop * h,
      cluster.right + livelyPadRight * h,
      cluster.bottom + livelyPadBottom * h,
    );
    if (rect.width <= 2 || rect.height <= 2) return null;
    if (imageWidth != null && imageHeight != null) {
      rect = Rect.fromLTRB(
        math.max(0, rect.left),
        math.max(0, rect.top),
        math.min(imageWidth.toDouble(), rect.right),
        math.min(imageHeight.toDouble(), rect.bottom),
      );
    }
    return LivelyPanelBox(rect);
  }
}
