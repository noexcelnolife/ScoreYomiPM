// v1.3.0 機種デフォルト H☆C!! 化（01a20b04）の検証。
//
// ユーザー指示（2026-11-24）「機種の選択は現在未指定がデフォルトになっていますが、
// H☆C!! をデフォルト選択にしてください」への対応。対象は**新規入力フローの 3 入口**:
//   (1) 種別選択シートの機種 chips
//   (2) OCR 結果確認画面（種別シート経由の機種引き継ぎ + 共有インテント経路の既定）
//   (3) 写真なし手入力（= OCR 結果確認画面の手入力モード。home_screen_species_sheet_test
//       の入口テストが担う）
//
// 不変条件（non-reg）:
//   - 「未指定」は選択肢として残り、明示的に外せる（= 保存値 null も表現可能）
//   - **既存レコードの編集画面は既定を適用しない**（保存済みの値を表示する）
//   - データ層・enum・JSON・key・ラベルは無変更（UI の初期値だけを変える）
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/species_selection_sheet.dart';

import 'fake_play_record_repository.dart';

/// 既定機種（UI 初期値）。データ層の [availableGameVersions] 先頭と一致する。
const String _defaultMachine = 'H☆C!!';

ChoiceChip _chip(WidgetTester tester, String keyName) =>
    tester.widget<ChoiceChip>(find.byKey(ValueKey<String>(keyName)));

/// 編集復元用のレコード（machine だけ差し替えられる最小構成）。
PlayRecord _record({required String id, String? machine}) => PlayRecord(
  id: id,
  playedAt: DateTime(2026, 11, 24, 10),
  songName: '曲A',
  score: 98765,
  cool: null,
  great: null,
  good: null,
  bad: null,
  maxCombo: null,
  level: 45,
  status: PlayRecordStatus.confirmed,
  source: PlayRecordSource.playshare,
  resultImagePath: '',
  machine: machine,
);

/// 種別選択シートを単体で開く。
Future<void> _pumpSheet(
  WidgetTester tester, {
  void Function(String? machine)? onManualEntry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpeciesSelectionSheet(
            onPickPlayShare: (_) {},
            onPickResultGallery: (_) {},
            onPickResultCamera: (_) {},
            onPickLivelyGallery: (_) {},
            onPickLivelyCamera: (_) {},
            onManualEntry: onManualEntry ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// OCR 結果確認画面を開く（[initialMachine] 未指定 = 共有インテント等の経路）。
Future<void> _pumpResultScreen(
  WidgetTester tester, {
  String? initialMachine,
  FakePlayRecordRepository? repository,
  String? existingRecordId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  OcrResultScreen.route(
                    playRecordRepository:
                        repository ?? FakePlayRecordRepository(),
                    appBarTitle: 'スコア入力',
                    initialMachine: initialMachine,
                    existingRecordId: existingRecordId,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('(1) 種別選択シートの機種初期値', () {
    testWidgets('開いた直後は H☆C!! が選択されている', (WidgetTester tester) async {
      await _pumpSheet(tester);

      expect(_chip(tester, 'species-machine-chip-0').selected, isTrue);
      expect(_chip(tester, 'species-machine-chip-none').selected, isFalse);
    });

    testWidgets('「未指定」は選択肢として残り、明示的に外せる', (WidgetTester tester) async {
      String? captured = 'sentinel';
      await _pumpSheet(
        tester,
        onManualEntry: (String? machine) {
          captured = machine;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('species-machine-chip-none')),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, 'species-machine-chip-none').selected, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-manual-entry')),
      );
      await tester.pumpAndSettle();

      expect(captured, isNull, reason: '未指定を選び直せば null が伝播する');
    });

    testWidgets('既定のまま手入力へ進むと H☆C!! が伝播する', (WidgetTester tester) async {
      String? captured;
      await _pumpSheet(
        tester,
        onManualEntry: (String? machine) {
          captured = machine;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-manual-entry')),
      );
      await tester.pumpAndSettle();

      expect(captured, _defaultMachine);
    });
  });

  group('(2) OCR 結果確認画面の機種初期値', () {
    testWidgets('機種未指定で開いても（共有インテント経路）H☆C!! が選択される', (
      WidgetTester tester,
    ) async {
      await _pumpResultScreen(tester);

      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
      expect(_chip(tester, 'machine-chip-none').selected, isFalse);
    });

    testWidgets('シートから引き継いだ機種が優先される', (WidgetTester tester) async {
      await _pumpResultScreen(tester, initialMachine: _defaultMachine);

      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
    });

    testWidgets('画面側で「未指定」へ切り替えられる（既定は強制しない）', (WidgetTester tester) async {
      await _pumpResultScreen(tester);

      // 機種 chips はフォーム下部にあるため、スクロールして可視化してから押す。
      final Finder noneChip = find.byKey(
        const ValueKey<String>('machine-chip-none'),
      );
      await tester.ensureVisible(noneChip);
      await tester.pumpAndSettle();
      await tester.tap(noneChip);
      await tester.pumpAndSettle();

      expect(_chip(tester, 'machine-chip-none').selected, isTrue);
      expect(_chip(tester, 'machine-chip-0').selected, isFalse);
    });
  });

  group('(3) 既存レコードの編集は既定を適用しない', () {
    testWidgets('保存済み machine が H☆C!! のレコードはそのまま表示', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r1'] = _record(id: 'r1', machine: _defaultMachine);

      await _pumpResultScreen(
        tester,
        repository: repository,
        existingRecordId: 'r1',
      );

      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
    });

    testWidgets('保存済み machine が null の旧レコードは「未指定」のまま表示', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r1'] = _record(id: 'r1', machine: null);

      await _pumpResultScreen(
        tester,
        repository: repository,
        existingRecordId: 'r1',
      );

      expect(
        _chip(tester, 'machine-chip-none').selected,
        isTrue,
        reason: '編集画面で既定を適用すると保存済みデータを書き換えてしまう',
      );
      expect(_chip(tester, 'machine-chip-0').selected, isFalse);
    });
  });
}
