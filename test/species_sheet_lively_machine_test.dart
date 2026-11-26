// 種別選択シートの並び順と機種一覧の検証（2026-11-26 のユーザー指示 2 件）。
//
// 指示 1「手入力の選択肢を一番下にしてください」:
//   種別選択シートの「写真なしで手入力」行を最下段へ移す。写真の取り込み導線を
//   上から順に並べたうえで、写真を使わない選択肢だけを最後に置く。
//
// 指示 2「機種選択に Lively を追加してください」:
//   [availableGameVersions] の末尾に 'Lively' を足す。末尾に足すのは、
//   既定機種が「一覧の先頭」で決まる仕様（machine_default_test.dart）を
//   変えないため。既存の ValueKey（index ベース）も先頭側がずれない。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/species_selection_sheet.dart';

/// 既定機種（= [availableGameVersions] の先頭）。
const String _defaultMachine = 'H☆C!!';

ChoiceChip _chip(WidgetTester tester, String keyName) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey<String>(keyName)));

/// 種別選択シートを単体で開き、各入口へ渡された機種を記録する。
Future<void> _pumpSheet(
  WidgetTester tester, {
  void Function(String? machine)? onManualEntry,
  void Function(String? machine)? onLively,
  void Function(String? machine)? onLivelyCamera,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpeciesSelectionSheet(
            onPickPlayShare: (_) {},
            onPickResultGallery: (_) {},
            onPickResultCamera: (_) {},
            onPickLivelyGallery: onLively ?? (_) {},
            onPickLivelyCamera: onLivelyCamera ?? (_) {},
            onManualEntry: onManualEntry ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('機種一覧に Lively を追加', () {
    test('Lively は末尾に並び、既定（先頭）は H☆C!! のまま', () {
      expect(availableGameVersions, <String>[_defaultMachine, 'Lively']);
      expect(
        availableGameVersions.first,
        _defaultMachine,
        reason: '先頭を既定機種として使うため、追加は末尾でなければならない',
      );
    });

    testWidgets('シートの機種 chips に Lively が並ぶ', (WidgetTester tester) async {
      await _pumpSheet(tester);

      expect(
        _chip(tester, 'species-machine-chip-1').label,
        isA<Text>().having((Text t) => t.data, 'data', 'Lively'),
      );
      expect(
        _chip(tester, 'species-machine-chip-0').selected,
        isTrue,
        reason: '機種を増やしても既定の選択は変わらない',
      );
    });

    testWidgets('Lively を選ぶとその機種が入口へ伝播する', (WidgetTester tester) async {
      String? captured;
      await _pumpSheet(
        tester,
        onManualEntry: (String? machine) {
          captured = machine;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('species-machine-chip-1')),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, 'species-machine-chip-1').selected, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-manual-entry')),
      );
      await tester.pumpAndSettle();

      expect(captured, 'Lively');
    });

    // 2026-11-26 のユーザー指示「Lively のスコア画面写真から読み取るを選んで OCR を
    // 始めた場合は編集画面でも Lively を自動で選択していてほしい」。
    // Lively 行は行の選択自体が機種を決めるため、chip が既定（H☆C!!）のままでも
    // Lively を渡す。
    testWidgets('Lively 行は chip の選択より優先して Lively を渡す', (
      WidgetTester tester,
    ) async {
      String? captured;
      await _pumpSheet(
        tester,
        onLively: (String? machine) {
          captured = machine;
        },
      );

      // 既定のまま（H☆C!! が選択されている）で Lively 行をタップする。
      expect(_chip(tester, 'species-machine-chip-0').selected, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-lively-gallery')),
      );
      await tester.pumpAndSettle();

      expect(captured, 'Lively');
    });

    testWidgets('Lively 行は未指定を選んでいても Lively を渡す', (WidgetTester tester) async {
      String? captured;
      await _pumpSheet(
        tester,
        onLively: (String? machine) {
          captured = machine;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('species-machine-chip-none')),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, 'species-machine-chip-none').selected, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-lively-gallery')),
      );
      await tester.pumpAndSettle();

      expect(captured, 'Lively');
    });

    // 2026-11-26 のユーザー指示「HC のカメラで撮影のようにその場で枠線付きの
    // カメラを起動することはできますか」。HC リザルト写真と同じく 2 アクションに
    // し、カメラも同じ機種固定（Lively）で入口へ渡す。
    testWidgets('Lively にカメラで撮影の行があり、Lively を渡す', (WidgetTester tester) async {
      String? captured;
      await _pumpSheet(
        tester,
        onLivelyCamera: (String? machine) {
          captured = machine;
        },
      );

      final Finder cameraRow = find.byKey(
        const ValueKey<String>('species-row-lively-camera'),
      );
      expect(cameraRow, findsOneWidget);

      await tester.tap(cameraRow);
      await tester.pumpAndSettle();

      expect(captured, 'Lively');
    });

    testWidgets('Lively の親行はタップしても何も起きない', (WidgetTester tester) async {
      String? gallery;
      String? camera;
      await _pumpSheet(
        tester,
        onLively: (String? machine) => gallery = machine,
        onLivelyCamera: (String? machine) => camera = machine,
      );

      final ListTile parent = tester.widget<ListTile>(
        find.byKey(const ValueKey<String>('species-row-lively')),
      );
      expect(parent.onTap, isNull);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-lively')),
      );
      await tester.pumpAndSettle();

      expect(gallery, isNull);
      expect(camera, isNull);
    });
  });

  group('手入力の行は最下段', () {
    testWidgets('「写真なしで手入力」は Lively 行より下にある', (WidgetTester tester) async {
      await _pumpSheet(tester);

      final double manualY = tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('species-row-manual-entry')),
          )
          .dy;
      final double livelyY = tester
          .getTopLeft(find.byKey(const ValueKey<String>('species-row-lively')))
          .dy;
      final double resultY = tester
          .getTopLeft(find.byKey(const ValueKey<String>('species-row-result')))
          .dy;

      expect(manualY, greaterThan(livelyY));
      expect(manualY, greaterThan(resultY));
    });
  });
}
