import 'dart:io';
import 'dart:ui';

import 'package:image/image.dart' as img;

import '../../models/ocr_models.dart';
import '../field_extractor.dart';
import '../ocr_engine.dart';
import '../region_ocr.dart';
import '../region_spec.dart';
import 'lively_geometry.dart';
import 'lively_image_ops.dart';
import 'lively_merged_extractor.dart';
import 'lively_panel_rectifier.dart';
import 'lively_value_parser.dart';

/// Lively 1 枚分の出力。既存経路（H&C）と同じ 2 つを返す。
class LivelyOcrOutcome {
  const LivelyOcrOutcome({
    required this.extraction,
    required this.regionOcr,
    this.failureReason,
  });

  /// 数値フィールド。取れなかった場合は null（FR-3 で手入力に落ちる）。
  final FieldExtractionResult? extraction;

  /// 曲名帯（ベストエフォート）。
  final RegionOcrResult regionOcr;

  /// 抽出を諦めた理由（計測・デバッグ用）。
  final String? failureReason;
}

/// Lively のスコア画面写真から数値を読む（統合ストラテジー）。
///
/// WHY 4 パスか（実測）: 1 パスでは 66/126 セル、2 倍 + 行ブロックを足した
/// 統合で 75/126（59.5%）まで上がる。パネル全体と行ブロックでは拾える桁が
/// 違うため、同じセルを別解像度で読み直して突き合わせる。
/// 出所: `docs/lively_ocr_strategy_comparison_2026-11-25.md`。
class LivelyOcrRoute {
  const LivelyOcrRoute({
    required this.engine,
    this.rectifier = const LivelyPanelRectifier(),
    this.parser = const LivelyValueParser(),
    this.merger = const LivelyMergedExtractor(),
    this.blockHeight = 900,
    this.cellHeight = 260,
    this.jpegQuality = 92,
  });

  final OcrEngine engine;
  final LivelyPanelRectifier rectifier;
  final LivelyValueParser parser;
  final LivelyMergedExtractor merger;
  final int blockHeight;
  final int cellHeight;
  final int jpegQuality;

  /// パネル 1 パスで読む対象（BEST は保存しないので読まない）。
  static const Set<LivelyRow> panelRows = <LivelyRow>{
    LivelyRow.score,
    LivelyRow.cool,
    LivelyRow.great,
    LivelyRow.good,
    LivelyRow.bad,
    LivelyRow.combo,
  };

  Future<LivelyOcrOutcome> run({
    required File imageFile,
    required OcrPageResult pageResult,
  }) async {
    final photo = img.decodeImage(await imageFile.readAsBytes());
    if (photo == null) {
      return LivelyOcrOutcome(
        extraction: null,
        regionOcr: _emptyRegion(),
        failureReason: '画像を読み込めませんでした',
      );
    }
    final box = LivelyPanelBox.fromLabels(
      pageResult.elements,
      imageWidth: pageResult.imageWidth ?? photo.width,
      imageHeight: pageResult.imageHeight ?? photo.height,
    );
    final titleRegion = _titleRegion(pageResult, box);
    if (box == null) {
      return LivelyOcrOutcome(
        extraction: null,
        regionOcr: titleRegion,
        failureReason: 'パネルのラベル（COOL/GREAT/GOOD/BAD）が見つかりません',
      );
    }
    final panel = rectifier.rectify(photo, box.rect);
    if (panel == null) {
      return LivelyOcrOutcome(
        extraction: null,
        regionOcr: titleRegion,
        failureReason: 'パネルを切り出せませんでした',
      );
    }
    final dir = Directory.systemTemp.createTempSync('lively_ocr_');
    try {
      final panelResult = await _recognize(dir, 'panel', panel);
      final anchor = LivelyAnchor.detect(panelResult.elements);
      if (anchor == null) {
        return LivelyOcrOutcome(
          extraction: null,
          regionOcr: titleRegion,
          failureReason: 'パネル内の行ラベルから基準点を作れませんでした',
        );
      }
      final panelValues = parser.parse(
        panelResult.elements,
        toP: (c) => Offset(anchor.pOfX(c.dx), anchor.pOfY(c.dy)),
        rows: panelRows,
      );
      final counters = await _readBlock(
        dir,
        panel,
        anchor,
        livelyCounterBlockP,
        blockHeight,
        const <LivelyRow>{
          LivelyRow.cool,
          LivelyRow.great,
          LivelyRow.good,
          LivelyRow.bad,
        },
      );
      final combos = await _readBlock(
        dir,
        panel,
        anchor,
        livelyComboBlockP,
        blockHeight,
        const <LivelyRow>{LivelyRow.combo},
      );
      final scoreValues = await _readBlock(
        dir,
        panel,
        anchor,
        livelyScoreBlockP,
        cellHeight,
        const <LivelyRow>{LivelyRow.score},
      );
      final extraction = merger.extract(
        panel: panelValues,
        counterBlock: counters,
        comboBlock: combos,
        scoreBlock: scoreValues,
        sourceElementCount: pageResult.elements.length,
      );
      return LivelyOcrOutcome(extraction: extraction, regionOcr: titleRegion);
    } finally {
      _deleteQuietly(dir);
    }
  }

  /// パネル内の 1 ブロックを切り出して読み、P 単位へ写して返す。
  ///
  /// WHY 失敗を握りつぶすか: ブロック 1 本が落ちても他のパスで読める
  /// （統合の意味がそこにある）。落ちたことは値が欠けることで現れる。
  Future<Map<LivelyRow, LivelyRead>> _readBlock(
    Directory dir,
    img.Image panel,
    LivelyAnchor anchor,
    Rect blockP,
    int height,
    Set<LivelyRow> rows,
  ) async {
    final rect = anchor.rectOf(blockP);
    final crop = LivelyImageOps.cropEnhanced(panel, rect, height);
    if (crop == null) return const {};
    try {
      final result = await _recognize(dir, 'block', crop);
      final width = (result.imageWidth ?? crop.width).toDouble();
      final heightPx = (result.imageHeight ?? crop.height).toDouble();
      if (width <= 0 || heightPx <= 0) return const {};
      return parser.parse(
        result.elements,
        toP: (c) => Offset(
          blockP.left + c.dx / width * blockP.width,
          blockP.top + c.dy / heightPx * blockP.height,
        ),
        rows: rows,
      );
    } on OcrEngineException {
      return const {};
    }
  }

  Future<OcrPageResult> _recognize(
    Directory dir,
    String name,
    img.Image image,
  ) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name.jpg');
    await file.writeAsBytes(img.encodeJpg(image, quality: jpegQuality));
    return engine.recognize(file);
  }

  /// パネルより上を曲名帯として渡す（曲名はパネルの外にある）。
  ///
  /// WHY ベストエフォートか: Lively の曲名はパネル切り出しに含まれないため、
  /// 写真全体の OCR 結果からパネル上方の要素を拾うしかない。取れなければ
  /// FR-3 で手動選択する（既存の曲名照合は空入力でも落ちない）。
  RegionOcrResult _titleRegion(OcrPageResult pageResult, LivelyPanelBox? box) {
    if (box == null) return _emptyRegion();
    final clusterHeight =
        box.rect.height / (livelyPadTop + 1 + livelyPadBottom);
    final cutoff = box.rect.top + livelyPadTop * clusterHeight;
    final elements = pageResult.elements
        // 曲名は日本語のことが多いので「英字を含む」では絞らない。数値だけの
        // 要素（スコアの一部など）を除くだけにする。
        .where((e) => e.boundingBox.bottom < cutoff && !livelyIsNumeric(e.text))
        .toList();
    if (elements.isEmpty) return _emptyRegion();
    final imageHeight = (pageResult.imageHeight ?? 1).toDouble();
    final spec = RegionSpec(
      target: RegionTarget.songTitle,
      region: Rect.fromLTRB(0, 0, 1, (cutoff / imageHeight).clamp(0.0, 1.0)),
      script: OcrScript.japanese,
      reason: 'Lively: パネル上方の帯（曲名はパネルの外）',
    );
    return RegionOcrResult(
      specs: <RegionSpec>[spec],
      results: <RegionTarget, OcrPageResult>{
        RegionTarget.songTitle: OcrPageResult(
          elements: elements,
          fullText: elements.map((e) => e.text).join(' '),
          imageWidth: pageResult.imageWidth,
          imageHeight: pageResult.imageHeight,
        ),
      },
      failures: const <String, String>{},
    );
  }

  RegionOcrResult _emptyRegion() => RegionOcrResult(
    specs: const <RegionSpec>[],
    results: const <RegionTarget, OcrPageResult>{},
    failures: const <String, String>{},
  );

  void _deleteQuietly(Directory dir) {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 一時ファイルの掃除失敗は処理結果に影響しない。
    }
  }
}
