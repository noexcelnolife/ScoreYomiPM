import '../../models/ocr_models.dart';
import '../field_extractor.dart';
import 'lively_geometry.dart';
import 'lively_value_parser.dart';

/// 統合ストラテジーの突き合わせ。
///
/// WHY: 同じセルを「パネル全体」「行ブロック」の別解像度で読み、片方が落とした
/// 桁をもう片方が拾う（実測で 1 パス 66 セル → 統合 75 セル）。食い違ったときは
/// パネル側を採る。これは計測時に優先順を入れ替えても合計が 75 で変わらな
/// かったため（どちらを採っても同じ）で、加えて FR-3 で全フィールドを目視
/// 確認してから登録するので、ここで捨てて再現率を落とす理由がない。
class LivelyMergedExtractor {
  const LivelyMergedExtractor();

  /// 4 パスの読み取りを突き合わせて 1 画像分の結果にする。
  ///
  /// スコアは専用パスとパネルパスの 2 本、判定数はパネルパスと行ブロックの
  /// 2 本で突き合わせる（ブロックは 4 行と 2 行に分かれている）。
  FieldExtractionResult extract({
    required Map<LivelyRow, LivelyRead> panel,
    required Map<LivelyRow, LivelyRead> counterBlock,
    required Map<LivelyRow, LivelyRead> comboBlock,
    required Map<LivelyRow, LivelyRead> scoreBlock,
    required int sourceElementCount,
  }) {
    final fields = <NumericFieldKind, ExtractedField>{};
    _add(fields, NumericFieldKind.score, LivelyRow.score, scoreBlock, panel);
    _add(fields, NumericFieldKind.cool, LivelyRow.cool, panel, counterBlock);
    _add(fields, NumericFieldKind.great, LivelyRow.great, panel, counterBlock);
    _add(fields, NumericFieldKind.good, LivelyRow.good, panel, counterBlock);
    _add(fields, NumericFieldKind.bad, LivelyRow.bad, panel, counterBlock);
    _add(fields, NumericFieldKind.maxCombo, LivelyRow.combo, panel, comboBlock);
    return FieldExtractionResult(
      numericFields: fields,
      sourceElementCount: sourceElementCount,
    );
  }

  /// 2 パスを突き合わせて 1 フィールドを確定する（無ければ何もしない）。
  void _add(
    Map<NumericFieldKind, ExtractedField> fields,
    NumericFieldKind kind,
    LivelyRow row,
    Map<LivelyRow, LivelyRead> primary,
    Map<LivelyRow, LivelyRead> secondary,
  ) {
    final read = primary[row] ?? secondary[row];
    if (read == null) return;
    final valid = _isValid(kind, read.value);
    fields[kind] = ExtractedField(
      kind: kind,
      value: read.value,
      rawText: read.raw,
      confidence: _confidenceOf(read.evidence),
      boundingBox: read.boundingBox,
      isValid: valid,
      validationMessage: valid ? null : _rangeMessage(kind),
      evidence: read.evidence,
    );
  }

  /// 根拠要素の信頼度平均。1 つでも不明なら「不明」を保つ
  /// （不明を低い値と偽装しない）。
  double _confidenceOf(List<OcrElement> evidence) {
    if (evidence.isEmpty) return OcrElement.confidenceUnknown;
    if (evidence.any((e) => e.hasUnknownConfidence)) {
      return OcrElement.confidenceUnknown;
    }
    final sum = evidence.fold<double>(0, (acc, e) => acc + e.confidence);
    return sum / evidence.length;
  }

  bool _isValid(NumericFieldKind kind, int value) {
    switch (kind) {
      case NumericFieldKind.score:
        return value > 0 && value <= 100000;
      case NumericFieldKind.maxCombo:
      case NumericFieldKind.cool:
      case NumericFieldKind.great:
      case NumericFieldKind.good:
      case NumericFieldKind.bad:
        return value >= 0 && value <= 9999;
      case NumericFieldKind.level:
        return value >= 1 && value <= 50;
    }
  }

  String _rangeMessage(NumericFieldKind kind) => switch (kind) {
    NumericFieldKind.score => 'スコアの範囲外（1〜100000）',
    NumericFieldKind.level => 'レベルの範囲外（1〜50）',
    _ => '判定数の範囲外（0〜9999）',
  };
}
