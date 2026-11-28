/// 共通 UI アンカー検出（ST-3.5）。
///
/// 設計: docs/st3_5_ui_anchor_design_confirmation_2026-11-22.md
/// （docs 単独コミット c8c9e00・リード検収承認済み）。
///
/// レイヤー契約（リード受け入れ条件①）:
/// - 幾何層（region_spec.dart）に渡すのは [AnchorRegistration]（純データ）
///   のみ。デコード/NCC 機構は本ファイルに封入し、幾何層は package:image
///   を import しない。
/// - [AnchorRegistration.detect] は前処理後画像（pageResult と同一の
///   クロップ空間・0070184 教訓）に対し pipeline から 1 回だけ呼ぶ。
///
/// 期待効果の正直な範囲（設計 §3）: アンカーは「位置合わせ」を解決する
/// 技術で、stylized フォントの認識限界は別問題。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

/// アンカー種別。
enum AnchorKind {
  /// 縮小画像 NCC（固定ラベルの画素パターン照合）。
  ncc,

  /// 列エッジ（全高の縦構造物・frameRight 枠線）。
  columnEdge,
}

/// アンカー定義（パックに静的に同梱する純データ）。
@immutable
class AnchorDefinition {
  const AnchorDefinition({
    required this.id,
    required this.kind,
    required this.canonicalPosition,
    required this.threshold,
    this.templateAsset,
  });

  /// パック契約 id（幾何層はこの id でヒットを参照する）。
  final String id;

  final AnchorKind kind;

  /// canonical 位置（正規化座標・横 1200x800 基準の実測中央値）。
  final Offset canonicalPosition;

  /// 採用最低スコア（ncc: NCC 0..1・columnEdge: 列強度/255）。
  final double threshold;

  /// NCC テンプレートの asset 相対パス（columnEdge は null）。
  final String? templateAsset;
}

/// 検出済み 1 アンカー（幾何層に渡る純データの最小単位）。
@immutable
class AnchorHit {
  const AnchorHit({
    required this.id,
    required this.position,
    required this.score,
    required this.canonicalPosition,
  });

  final String id;

  /// 検出位置（正規化座標・NCC はテンプレート中心）。
  final Offset position;

  /// スコア（ncc: NCC 0..1・columnEdge: 列強度/255）。
  final double score;

  /// 定義の canonical 位置（幾何層の整合サニティ用の純データ。機構を含ま
  /// ないため幾何層は本値との差分だけでゲート判定できる）。
  final Offset canonicalPosition;
}

/// 1 画像分のアンカー検出結果（純データ・幾何層への契約型）。
@immutable
class AnchorRegistration {
  const AnchorRegistration({required this.hits});

  /// id → ヒット（不成立のアンカーは含まない）。
  final Map<String, AnchorHit> hits;

  /// [id] のヒット（無ければ null）。
  AnchorHit? hitOf(String id) => hits[id];

  /// [imageBytes]（前処理後画像のエンコード済みバイト列）からアンカーを検出する。
  ///
  /// デコード失敗時は null（呼び出し側はアンカーなし = 現行動作・機能 OFF）。
  /// 各アンカーのスコアが named 定数（_nccScoreThreshold /
  /// _columnEdgeMinStrength）未満なら registration に含めない。パックの
  /// AnchorDefinition.threshold はこの定数群のミラー（生成ツールが書き込み、
  /// asset 契約テストで一致を固定する）で、実行時ゲートは本定数で固定する
  ///（受け入れ条件②・呼び出し側のゲート再評価と二重化・設計 §6）。
  static AnchorRegistration? detect(Uint8List imageBytes, AnchorPack pack) {
    // WHY try でデコードも覆う: 呼び出し契約は「検出不能なら null」であり、
    // 壊れた画像や未対応形式でも機能 OFF に落ちるべき。
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) {
        return null;
      }
      final small = img.copyResize(
        image,
        width: image.width ~/ _downscale,
        height: image.height ~/ _downscale,
        interpolation: img.Interpolation.average,
      );
      final w = small.width;
      final h = small.height;
      if (w < 1 || h < 1) {
        return null;
      }
      final gray = _grayscaleOf(small, w, h);
      final hits = <String, AnchorHit>{};
      for (final definition in pack.definitions) {
        final hit = switch (definition.kind) {
          AnchorKind.columnEdge => _detectColumnEdge(definition, gray, w, h),
          AnchorKind.ncc => _detectNcc(
            definition,
            pack.templates[definition.templateAsset],
            gray,
            w,
            h,
          ),
        };
        if (hit != null) {
          hits[definition.id] = hit;
        }
      }
      return AnchorRegistration(hits: hits);
    } on Exception catch (_) {
      // WHY 狭い catch: 機能 OFF 契約（設計 §2.3）。IO/デコード失敗は
      // アンカーなしで現行動作に委ねる。Error 系は握り潰さない。
      return null;
    }
  }
}

/// 縮小グレースケールのテンプレート画像（純データ）。
@immutable
class UiAnchorTemplate {
  const UiAnchorTemplate({
    required this.width,
    required this.height,
    required this.gray,
  });

  final int width;
  final int height;

  /// row-major の輝度値（0..255）。
  final Uint8List gray;
}

/// バージョン単位のアンカーパック。
///
/// WHY バージョン単位: ゲームバージョンで UI レイアウトが変わり得るため
/// `assets/anchors/<version>/` で隔離し、欠落時は機能 OFF（設計 §2.3）。
@immutable
class AnchorPack {
  const AnchorPack({
    required this.version,
    required this.definitions,
    required this.templates,
  });

  /// パックのバージョン id（`assets/anchors/<version>/` と一致）。
  final String version;
  final List<AnchorDefinition> definitions;
  final Map<String, UiAnchorTemplate> templates;

  /// アンカーパックの遅延読み込みキャッシュ（asset は実行中に不変のため）。
  static final Map<String, Future<AnchorPack?>> _assetCache = {};

  /// assets/anchors/[version]/anchor_pack.json とテンプレ PNG からパックを
  /// 読む（結果キャッシュ済み・欠落/壊れ時は null = 機能 OFF・設計 §2.3）。
  ///
  /// WHY キャッシュ: home_screen が OCR 実行ごとにパイプラインを生成しても
  /// テンプレ再デコード（3 枚 × 数十 ms）を繰り返さないため。
  /// WHY テンプレはロード時に縮小: asset にはフル解像度クロップ（生成由来
  /// を manifest で追跡可能にする）を保存し、探索と同じ縮小率で一度だけ
  /// 変換する（探索側は縮小スケールのみを知る）。
  static Future<AnchorPack?> loadFromAssets(String version) {
    return _assetCache.putIfAbsent(version, () async {
      try {
        final json = jsonDecode(
          await rootBundle.loadString(
            'assets/anchors/$version/anchor_pack.json',
          ),
        ) as Map<String, dynamic>;
        final definitions = <AnchorDefinition>[];
        final templates = <String, UiAnchorTemplate>{};
        for (final raw in json['definitions'] as List<dynamic>) {
          final map = raw as Map<String, dynamic>;
          final canonical = map['canonical'] as Map<String, dynamic>;
          final definition = AnchorDefinition(
            id: map['id'] as String,
            kind: map['kind'] == 'ncc' ? AnchorKind.ncc : AnchorKind.columnEdge,
            canonicalPosition: Offset(
              (canonical['x'] as num).toDouble(),
              (canonical['y'] as num).toDouble(),
            ),
            threshold: (map['threshold'] as num).toDouble(),
            templateAsset: map['template'] as String?,
          );
          definitions.add(definition);
          final templateAsset = definition.templateAsset;
          if (templateAsset == null) {
            continue;
          }
          final bytes = await rootBundle.load(
            'assets/anchors/$version/$templateAsset',
          );
          final image = img.decodeImage(bytes.buffer.asUint8List());
          if (image == null) {
            continue; // テンプレ壊れ → その定義のみスキップ（クラッシュ回避）。
          }
          final small = img.copyResize(
            image,
            width: image.width ~/ _downscale,
            height: image.height ~/ _downscale,
            interpolation: img.Interpolation.average,
          );
          templates[templateAsset] = UiAnchorTemplate(
            width: small.width,
            height: small.height,
            gray: _grayscaleOf(small, small.width, small.height),
          );
        }
        return AnchorPack(
          version: version,
          definitions: definitions,
          templates: templates,
        );
      } catch (_) {
        // パック欠落/JSON 壊れ = 機能 OFF（設計 §2.3・現行動作を維持）。
        return null;
      }
    });
  }
}

/// 探索・テンプレート共通の縮小率。
///
/// WHY 4: 設計 §1.2 のプローブ実測（/4 縮小グレースケール 1200x800→300x200
/// で GAUGE 25/30・中心誤差 avg 9.8px・5.2ms/search ホスト実測）。
/// /8 は中心誤差が倍になる恐れ、/2 はコストが 4 倍になるため /4。
const int _downscale = 4;

/// NCC 探索窓の半径（canonical 予測中心から・正規化前 px）。
///
/// WHY 96: 設計 §1.2（GT 中心 ±96px の窓で GAUGE 25/30・NORMAL 24/30）。
/// ラベル位置の実測 spread（GAUGE cy ±0.004 ≈ ±3px・設定バンド NORMAL
/// cy ±0.024 ≈ ±19px）を覆い、ヘッダー行（cy≈0.35）と設定バンド
/// （cy≈0.79）の GAUGE 2 実例を空間分離できる（0.44H ≫ ±96px）。
const double _nccSearchRadiusPx = 96;

/// NCC 採用最低スコア。
///
/// WHY 0.55: 設計 §1.4（横テンプレを縦バンドへ適用する最悪条件で 18/18・
/// avgNCC 0.78・下限 0.495=0.55×0.9 で全成功）。正ヒット ≈0.78 に対し
/// 無地/誤構造物は ≈0 のため誤検出側に十分な余裕。
const double _nccScoreThreshold = 0.55;

/// columnEdge 探索の半径（canonical 列から・正規化前 px）。
///
/// WHY 12: 設計 §1.1（per-image local-peak 整合 ±12px 窓で 28/30）。
const double _columnEdgeSearchRadiusPx = 12;

/// columnEdge 採用最低列強度（列平均 |dx|・0-255 スケール）。
///
/// WHY 25: 設計 §1.1（枠線列の実測強度中央値 79・誤ピーク x516-532 でも
/// 63-68）。25 は無地/ノイズを排除する保守的下限で、実枠線（79 以上）と
/// 十分离れている。integration red の 39 枚実測で再検証する。
const double _columnEdgeMinStrength = 25;

/// [image] を 0..255 の輝度 row-major 配列へ変換する。
///
/// WHY Pixel 反復: package:image v4 では Image.getLuminance が廃止され、
/// Pixel.luminance（getPixel 相当）が正解 API。反復順は row-major 保証。
Uint8List _grayscaleOf(img.Image image, int w, int h) {
  final gray = Uint8List(w * h);
  var i = 0;
  for (final p in image) {
    final lum = p.luminance.toInt();
    gray[i++] = lum < 0 ? 0 : (lum > 255 ? 255 : lum);
  }
  return gray;
}

/// 全高列エッジの検出（frameRight 枠線）。
///
/// 列ごとの平均勾配強度（平均 |dx|）を全列で先に計算してから、canonical
/// 近傍の探索窓内で最強列を選ぶ（WHY 全列事前計算: 探索窓内外で値を使い
/// 回す余地は今はないが、1 パスで済む実装が最短で一貫する）。
AnchorHit? _detectColumnEdge(
  AnchorDefinition definition,
  Uint8List gray,
  int w,
  int h,
) {
  if (w < 2 || h < 1) {
    return null;
  }
  final strengths = Float64List(w);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w - 1; x++) {
      strengths[x] += (gray[y * w + x + 1] - gray[y * w + x]).abs();
    }
  }
  for (var x = 0; x < w - 1; x++) {
    strengths[x] /= h;
  }
  final predicted = definition.canonicalPosition.dx * w;
  final radius = (_columnEdgeSearchRadiusPx / _downscale).ceil();
  final minCol = (predicted - radius).floor().clamp(0, w - 2).toInt();
  final maxCol = (predicted + radius).floor().clamp(0, w - 2).toInt();
  var bestX = -1;
  var bestStrength = 0.0;
  for (var x = minCol; x <= maxCol; x++) {
    if (strengths[x] > bestStrength) {
      bestStrength = strengths[x];
      bestX = x;
    }
  }
  if (bestX < 0 || bestStrength < _columnEdgeMinStrength) {
    return null;
  }
  return AnchorHit(
    id: definition.id,
    // 列エッジに y 方向の意味はないため canonical の y を通す（契約）。
    position: Offset(bestX / w, definition.canonicalPosition.dy),
    score: (bestStrength / 255).clamp(0.0, 1.0).toDouble(),
    canonicalPosition: definition.canonicalPosition,
  );
}

/// 縮小 NCC による固定ラベル検出。
///
/// 探索は canonical 予測中心 ±[radius] のスライディング窓で Pearson 相関
/// （正規化クロス相関）を全位置計算し最良を取る。テンプレート中心を
/// ヒット位置とする（WHY 中心: 設計 §1.2 の誤差評価が「テンプレート中心
/// vs GT 中心」で統一されているため）。
AnchorHit? _detectNcc(
  AnchorDefinition definition,
  UiAnchorTemplate? template,
  Uint8List gray,
  int w,
  int h,
) {
  if (template == null) {
    // テンプレ未登録の定義はスキップ（パック整合の防御・クラッシュさせない）。
    return null;
  }
  final tw = template.width;
  final th = template.height;
  if (tw < 1 || th < 1 || w < tw || h < th) {
    return null;
  }
  final n = tw * th;
  var tSum = 0;
  var tSumSq = 0;
  for (var i = 0; i < n; i++) {
    final v = template.gray[i];
    tSum += v;
    tSumSq += v * v;
  }
  final tMean = tSum / n;
  final tVar = tSumSq / n - tMean * tMean;
  if (tVar <= 0) {
    // 一様テンプレートは相関が定義できない（score 0 = 不成立）。
    return null;
  }
  final predictedCx = definition.canonicalPosition.dx * w;
  final predictedCy = definition.canonicalPosition.dy * h;
  final radius = (_nccSearchRadiusPx / _downscale).ceil();
  final uMin = (predictedCx - radius - tw / 2).floor().clamp(0, w - tw).toInt();
  final uMax = (predictedCx + radius - tw / 2).floor().clamp(0, w - tw).toInt();
  final vMin = (predictedCy - radius - th / 2).floor().clamp(0, h - th).toInt();
  final vMax = (predictedCy + radius - th / 2).floor().clamp(0, h - th).toInt();

  var bestScore = 0.0;
  var bestU = -1;
  var bestV = -1;
  for (var v = vMin; v <= vMax; v++) {
    for (var u = uMin; u <= uMax; u++) {
      final score = _nccAt(template, gray, w, u, v, n, tMean, tVar);
      if (score > bestScore) {
        bestScore = score;
        bestU = u;
        bestV = v;
      }
    }
  }
  if (bestU < 0 || bestScore < _nccScoreThreshold) {
    return null;
  }
  return AnchorHit(
    id: definition.id,
    position: Offset((bestU + (tw - 1) / 2) / w, (bestV + (th - 1) / 2) / h),
    score: bestScore,
    canonicalPosition: definition.canonicalPosition,
  );
}

/// (u, v) を左上とする窓とテンプレートの Pearson 相関（0..1・不成立は 0）。
double _nccAt(
  UiAnchorTemplate template,
  Uint8List gray,
  int w,
  int u,
  int v,
  int n,
  double tMean,
  double tVar,
) {
  var iSum = 0;
  var iSumSq = 0;
  var cross = 0;
  var k = 0;
  for (var y = v; y < v + template.height; y++) {
    var idx = y * w + u;
    for (var x = 0; x < template.width; x++) {
      final t = template.gray[k];
      final pixel = gray[idx];
      iSum += pixel;
      iSumSq += pixel * pixel;
      cross += t * pixel;
      k++;
      idx++;
    }
  }
  final iMean = iSum / n;
  final iVar = iSumSq / n - iMean * iMean;
  if (iVar <= 0) {
    return 0; // 無地窓は相関を定義できない（score 0 = 不成立）。
  }
  final numerator = cross / n - tMean * iMean;
  final denominator = math.sqrt(tVar * iVar);
  final score = numerator / denominator;
  if (score.isNaN) {
    return 0;
  }
  return score.clamp(0.0, 1.0).toDouble();
}
