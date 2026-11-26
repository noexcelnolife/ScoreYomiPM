import 'dart:ui';

import '../../models/ocr_models.dart';
import 'lively_geometry.dart';

/// パス（パネル全体 / 行ブロック / スコア）の局所座標を P 単位へ写す関数。
typedef LivelyToP = Offset Function(Offset px);

/// 1 フィールド分の読み取り結果。
class LivelyRead {
  const LivelyRead({
    required this.row,
    required this.value,
    required this.raw,
    required this.evidence,
    required this.boundingBox,
  });

  final LivelyRow row;
  final int value;

  /// 連結する前の認識文字列（診断用）。
  final String raw;

  /// 採用した要素（FR-3 の根拠表示に使う）。
  final List<OcrElement> evidence;

  /// 採用した要素の外接矩形。
  final Rect boundingBox;

  int get elementCount => evidence.length;
}

/// OCR 要素列から行ごとの値を読む。
///
/// WHY: パネル 1 パスも行ブロックパスも「値列 x ∈ [4.20, 13.20] P かつ
/// 行バンド内の数値要素を x 順に連結」という同じ規則で読める。ブロックは
/// 局所座標を P へ逆写像してから同じ規則を通すので、パスごとに別のパーサを
/// 持たずに済む（前回の計測で 3 パスを同じ規則で読んでいたのと同じ）。
class LivelyValueParser {
  const LivelyValueParser();

  /// [rows] に指定した行だけを読む。取れなかった行は結果に含めない。
  Map<LivelyRow, LivelyRead> parse(
    List<OcrElement> elements, {
    required LivelyToP toP,
    required Set<LivelyRow> rows,
  }) {
    final result = <LivelyRow, LivelyRead>{};
    for (final row in rows) {
      final spec = livelyRows.firstWhere((s) => s.row == row);
      final picked = <OcrElement>[];
      for (final e in elements) {
        if (!livelyIsNumeric(e.text)) continue;
        final center = toP(e.boundingBox.center);
        if (center.dx < livelyValueLeftP || center.dx > livelyValueRightP) {
          continue;
        }
        if (center.dy < spec.top || center.dy > spec.bottom) continue;
        picked.add(e);
      }
      final read = _readPicked(row, picked, toP);
      if (read != null) result[row] = read;
    }
    return result;
  }

  LivelyRead? _readPicked(
    LivelyRow row,
    List<OcrElement> picked,
    LivelyToP toP,
  ) {
    if (picked.isEmpty) return null;
    picked.sort(
      (a, b) =>
          toP(a.boundingBox.center).dx.compareTo(toP(b.boundingBox.center).dx),
    );
    final kept = <OcrElement>[];
    for (final e in picked) {
      // 同じ数字を ML Kit が重複して返すことがある。x 範囲が重なる要素は
      // 幅の広いほう（＝数字全体）を残す。
      var merged = false;
      for (var i = 0; i < kept.length; i++) {
        if (!_overlapsX(kept[i], e)) continue;
        if (e.boundingBox.width > kept[i].boundingBox.width) kept[i] = e;
        merged = true;
        break;
      }
      if (!merged) kept.add(e);
    }
    final raw = kept.map((e) => e.text).join();
    final value = livelyParseInt(raw);
    if (value == null) return null;
    if (!_plausible(row, value)) return null;
    var box = kept.first.boundingBox;
    for (final e in kept.skip(1)) {
      box = box.expandToInclude(e.boundingBox);
    }
    return LivelyRead(
      row: row,
      value: value,
      raw: raw,
      evidence: kept,
      boundingBox: box,
    );
  }

  /// 横方向の重なりが短いほうの 60% を超えるか。
  bool _overlapsX(OcrElement a, OcrElement b) {
    final overlap = a.boundingBox.intersect(b.boundingBox).width;
    final shorter = a.boundingBox.width < b.boundingBox.width
        ? a.boundingBox.width
        : b.boundingBox.width;
    return overlap > 0 && overlap > 0.6 * shorter;
  }

  /// 値の妥当性。パネルの行に許されない桁数を弾くだけの弱い検査。
  /// WHY: 強い整合性検査（COOL+GREAT+GOOD+BAD とスコアの関係）は FR-3 の
  /// 確認で人間が見る前提なので、ここでは桁の異常だけを落とす。
  bool _plausible(LivelyRow row, int value) {
    switch (row) {
      case LivelyRow.score:
        return value > 0 && value <= 9999999;
      case LivelyRow.cool:
      case LivelyRow.great:
      case LivelyRow.good:
      case LivelyRow.bad:
      case LivelyRow.combo:
        return value >= 0 && value <= 99999;
      case LivelyRow.best:
        return value >= 0 && value <= 9999999;
    }
  }
}
