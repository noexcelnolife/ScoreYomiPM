// ac_v1 アンカーパックの asset 契約テスト（01a2060d Phase 7・実測校正）。
//
// WHY asset 契約テスト: 生成ツール（tool/generate_ac_anchor_templates.dart）
// が書いたパック JSON/PNG と lib 側の named 定数・実測 canonical の整合を
// 固定する。生成ツールは ui_anchor.dart を import せず定数をミラー保持する
// ため、形式・定数・canonical の齟齬はこのテストで検知する。
// 実測 canonical は主群 4:3横バケット（23 枚・aspect [1.25,1.45]）の
// ML Kit 実測中央値（tool/ac_generate_output.txt の derive 行と一致）。
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/ocr/ui_anchor.dart';

void main() {
  test('ac_v1 アンカーパックは実測校正値とテンプレート 7 枚を保持する', () async {
    // WHY binding 初期化: flutter test の test() 本文で rootBundle を使う
    // には TestWidgetsFlutterBinding の初期化が必要（未初期化だと
    // 「Binding has not yet been initialized」で機能 OFF 経路に落ちる）。
    TestWidgetsFlutterBinding.ensureInitialized();
    final pack = await AnchorPack.loadFromAssets('ac_v1');
    expect(pack, isNotNull);
    final p = pack!;

    final ids = p.definitions.map((d) => d.id).toSet();
    expect(
      ids,
      containsAll(const [
        'frameRight',
        'labelScore',
        'labelBest',
        'labelCool',
        'labelGreat',
        'labelGood',
        'labelBad',
        'labelCombo',
      ]),
    );
    expect(p.definitions, hasLength(8));

    final byId = {for (final d in p.definitions) d.id: d};
    // NCC アンカーの閾値は ui_anchor.dart _nccScoreThreshold のミラー（0.55）。
    const nccIds = [
      'labelScore',
      'labelBest',
      'labelCool',
      'labelGreat',
      'labelGood',
      'labelBad',
      'labelCombo',
    ];
    for (final id in nccIds) {
      expect(byId[id]!.kind, AnchorKind.ncc, reason: id);
      expect(byId[id]!.threshold, 0.55, reason: id);
      final asset = byId[id]!.templateAsset;
      expect(asset, isNotNull, reason: id);
      // テンプレートは loadFromAssets 内で /4 縮小済みで保持される。
      expect(p.templates[asset], isNotNull, reason: '$id テンプレート PNG が欠落/壊れ');
    }
    expect(byId['frameRight']!.kind, AnchorKind.columnEdge);
    expect(byId['frameRight']!.templateAsset, isNull);
    // columnEdge 閾値は _columnEdgeMinStrength(25) の正規化ミラー。
    expect(byId['frameRight']!.threshold * 255, closeTo(25, 1e-6));

    // canonical は生成ツールが主群バケット 23 枚から導出した実測 median
    //（tool/ac_generate_output.txt の derive 行と一致・asset 契約で固定）。
    expect(byId['frameRight']!.canonicalPosition.dx, closeTo(0.8633, 1e-4));
    expect(byId['frameRight']!.canonicalPosition.dy, closeTo(0.5, 1e-6));
    expect(byId['labelScore']!.canonicalPosition.dx, closeTo(0.4028, 1e-4));
    expect(byId['labelScore']!.canonicalPosition.dy, closeTo(0.5365, 1e-4));
    expect(byId['labelBest']!.canonicalPosition.dx, closeTo(0.3940, 1e-4));
    expect(byId['labelBest']!.canonicalPosition.dy, closeTo(0.6110, 1e-4));
    expect(byId['labelCool']!.canonicalPosition.dx, closeTo(0.4180, 1e-4));
    expect(byId['labelCool']!.canonicalPosition.dy, closeTo(0.6673, 1e-4));
    expect(byId['labelGreat']!.canonicalPosition.dx, closeTo(0.4250, 1e-4));
    expect(byId['labelGreat']!.canonicalPosition.dy, closeTo(0.7122, 1e-4));
    expect(byId['labelGood']!.canonicalPosition.dx, closeTo(0.4185, 1e-4));
    expect(byId['labelGood']!.canonicalPosition.dy, closeTo(0.7553, 1e-4));
    expect(byId['labelBad']!.canonicalPosition.dx, closeTo(0.4103, 1e-4));
    expect(byId['labelBad']!.canonicalPosition.dy, closeTo(0.7975, 1e-4));
    expect(byId['labelCombo']!.canonicalPosition.dx, closeTo(0.4246, 1e-4));
    expect(byId['labelCombo']!.canonicalPosition.dy, closeTo(0.8411, 1e-4));

    // 縮小済みテンプレートが非空であること（デコード成功の実証）。
    for (final id in nccIds) {
      final t = p.templates[byId[id]!.templateAsset]!;
      expect(t.width, greaterThan(0), reason: id);
      expect(t.height, greaterThan(0), reason: id);
      expect(t.gray, hasLength(t.width * t.height), reason: id);
    }
  });
}
