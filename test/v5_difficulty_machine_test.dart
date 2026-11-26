// v5 機能 A（docs/v5_difficulty_machine_design_2026-11-23.md）のテスト。
//
// ユーザー裁定を反映した確定仕様:
// - 難易度は 4 種のみ（LIGHT / NORMAL / HYPER / EX）。UPPER は選択肢に含めない。
// - 機種は 2 択（未指定 / H☆C!!）。正式名称（HC）は UI ラベルにも
//   格納値にも使わない（商標回避）。
//
// 検証ケース（設計 §6 の 7 ケース構成）:
// (1) PlayRecordDraft → toPlayRecord の difficulty/machine 素通し・既定 null
// (2) toJson/fromJson ラウンドトリップ・旧スキーマ欠落→null・未知難易度名→null
// (3) copyWith の保持・明示設定（clearMedal と同じ「指定時のみ設定」規約）
// (4) 画像なし手入力: 既定保存→両方 null / EX+機種選択保存→そのまま記録
// (5) 修正モード復元: difficulty/machine の chips が選択状態で開く
// (6) 種別選択シートの機種 chips→コールバック素通し・route(initialMachine) prefill
// (7) 詳細画面: 難易度実値・機種行表示（null→'—'）
//
// WHY(red-first の同コミット同梱): GameDifficulty や新 ValueKey は実装前に
// 存在しないため、このファイルは赤（コンパイル失敗）から始める。red→green の
// 中間で analyze を壊したコミットを残さないよう、実装と同一コミットに同梱する
// （リードの 0d29308 前例準拠）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';
import 'package:scoreyomipm/ui/species_selection_sheet.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';

PlayRecord _record({
  required String id,
  GameDifficulty? difficulty,
  String? machine,
  String songName = '曲A',
  int? score = 98765,
}) {
  return PlayRecord(
    id: id,
    playedAt: DateTime(2026, 11, 23, 10),
    songName: songName,
    score: score,
    cool: null,
    great: null,
    good: null,
    bad: null,
    maxCombo: null,
    level: 45,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
    resultImagePath: '',
    difficulty: difficulty,
    machine: machine,
  );
}

ChoiceChip _chip(WidgetTester tester, String keyName) {
  return tester.widget<ChoiceChip>(find.byKey(ValueKey<String>(keyName)));
}

void main() {
  group('(1) ドラフト→レコードの素通し', () {
    test('difficulty/machine は toPlayRecord でそのまま引き継がれる', () {
      final PlayRecord record = PlayRecordDraft(
        songName: '曲X',
        score: '98765',
        cool: null,
        great: null,
        good: null,
        bad: null,
        maxCombo: null,
        level: null,
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
        difficulty: GameDifficulty.ex,
        machine: 'H☆C!!',
      ).toPlayRecord(id: 'r1', resultImagePath: '');

      expect(record.difficulty, GameDifficulty.ex);
      expect(record.machine, 'H☆C!!');
    });

    test('未指定なら difficulty/machine は null のまま（旧挙動非破壊）', () {
      final PlayRecord record = PlayRecordDraft(
        songName: '曲X',
        score: '98765',
        cool: null,
        great: null,
        good: null,
        bad: null,
        maxCombo: null,
        level: null,
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ).toPlayRecord(id: 'r1', resultImagePath: '');

      expect(record.difficulty, isNull);
      expect(record.machine, isNull);
    });

    // 2026-11-26 のユーザー指示「機種選択に Lively を追加」で 2 機種になった。
    // 追加は末尾（先頭 = 既定機種 H☆C!! を変えないため）。
    test('availableGameVersions は H☆C!! と Lively の 2 機種（既定は先頭）', () {
      expect(availableGameVersions, <String>['H☆C!!', 'Lively']);
      expect(availableGameVersions.first, 'H☆C!!');
    });
  });

  group('(2) JSON 永続化の耐障害性', () {
    test('toJson/fromJson ラウンドトリップで difficulty/machine が保持される', () {
      final PlayRecord record = _record(
        id: 'r1',
        difficulty: GameDifficulty.hyper,
        machine: 'H☆C!!',
      );

      final PlayRecord restored = PlayRecord.fromJson(record.toJson());

      expect(restored.difficulty, GameDifficulty.hyper);
      expect(restored.machine, 'H☆C!!');
    });

    test('旧スキーマ（キー欠落）は null として読める', () {
      final Map<String, dynamic> legacyJson = _record(id: 'r1').toJson()
        ..remove('difficulty')
        ..remove('machine');

      final PlayRecord restored = PlayRecord.fromJson(legacyJson);

      expect(restored.difficulty, isNull);
      expect(restored.machine, isNull);
    });

    test('未知の難易度名（除外された upper 等）は null にフォールバック', () {
      // WHY: UPPER は裁定により enum 不在。将来他ビルドが 'upper' を書いた
      // 即便も asNameMap 許容で読み込み全体を壊さない。
      final Map<String, dynamic> json = _record(id: 'r1').toJson()
        ..['difficulty'] = 'upper';

      expect(PlayRecord.fromJson(json).difficulty, isNull);
    });
  });

  group('(3) copyWith', () {
    test('他フィールド変更で difficulty/machine が保持される', () {
      final PlayRecord record = _record(
        id: 'r1',
        difficulty: GameDifficulty.normal,
        machine: 'H☆C!!',
      );

      final PlayRecord renamed = record.copyWith(songName: '曲Y');

      expect(renamed.difficulty, GameDifficulty.normal);
      expect(renamed.machine, 'H☆C!!');
    });

    test('明示指定で難易度だけ上書きできる', () {
      final PlayRecord record = _record(
        id: 'r1',
        difficulty: GameDifficulty.normal,
        machine: 'H☆C!!',
      );

      final PlayRecord edited = record.copyWith(
        difficulty: GameDifficulty.light,
      );

      expect(edited.difficulty, GameDifficulty.light);
      expect(edited.machine, 'H☆C!!');
    });
  });

  group('(4) 画像なし手入力での chips 操作', () {
    late FakePlayRecordRepository repository;

    setUp(() {
      repository = FakePlayRecordRepository();
    });

    Future<void> pumpManualEntry(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      OcrResultScreen.route(
                        playRecordRepository: repository,
                        appBarTitle: 'スコア手入力',
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

    Future<void> saveWith(
      WidgetTester tester,
      String songName,
      String score,
    ) async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-songName')),
        songName,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('field-input-score')),
        score,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('save-record-button')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('初期状態は難易度「なし」・機種 H☆C!! が選択', (WidgetTester tester) async {
      await pumpManualEntry(tester);

      expect(_chip(tester, 'difficulty-chip-none').selected, isTrue);
      // 2026-11-24 ユーザー指示で機種の既定を H☆C!! へ変更（旧: 未指定）。
      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
      expect(_chip(tester, 'machine-chip-none').selected, isFalse);
      // 裁定: 難易度 chips は 4 種のみ。UPPER は作らない。
      expect(
        find.byKey(const ValueKey<String>('difficulty-chip-upper')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('difficulty-chip-light')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('difficulty-chip-normal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('difficulty-chip-hyper')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('difficulty-chip-ex')),
        findsOneWidget,
      );
    });

    testWidgets('未選択保存→難易度 null・機種 H☆C!!、続く選択保存→EX・H☆C!! が記録される', (
      WidgetTester tester,
    ) async {
      await pumpManualEntry(tester);

      // 1 回目: chips を触らず保存 → 難易度は null（既定）、機種は既定の
      // H☆C!!（2026-11-24 ユーザー指示で未指定→H☆C!! へ変更）。
      await saveWith(tester, '曲無難易度', '1000');
      expect(repository.store, hasLength(1));
      final PlayRecord first = repository.store.values.single;
      expect(first.difficulty, isNull);
      expect(first.machine, 'H☆C!!');

      // 連続入力モードでフォームがリセットされている前提。
      expect(_chip(tester, 'difficulty-chip-none').selected, isTrue);
      expect(_chip(tester, 'machine-chip-0').selected, isTrue);

      // 2 回目: EX + H☆C!! を選んで保存 → そのまま記録。
      // WHY ensureVisible（01a20b34・項目順変更への追随）: 難易度 chips は
      // フォーム先頭側（メダルの直後）へ移ったため、直前の保存で末尾まで
      // スクロールした状態では表示領域外にあり、tap が空振りする。
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('difficulty-chip-ex')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('difficulty-chip-ex')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('machine-chip-0')));
      await tester.pumpAndSettle();
      await saveWith(tester, '曲EX', '987654');

      expect(repository.store, hasLength(2));
      final PlayRecord second = repository.store.values.toList()[1];
      expect(second.songName, '曲EX');
      expect(second.difficulty, GameDifficulty.ex);
      expect(second.machine, 'H☆C!!');
    });
  });

  group('(5) 修正モードの編集復元', () {
    testWidgets('既存レコードの difficulty/machine が chips の選択状態で復元される', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store['r1'] = _record(
        id: 'r1',
        difficulty: GameDifficulty.ex,
        machine: 'H☆C!!',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      OcrResultScreen.route(
                        playRecordRepository: repository,
                        existingRecordId: 'r1',
                        appBarTitle: '記録の修正',
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

      expect(_chip(tester, 'difficulty-chip-ex').selected, isTrue);
      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
      expect(_chip(tester, 'difficulty-chip-none').selected, isFalse);
    });
  });

  group('(6) 種別選択シートの機種選択', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required void Function(String? machine) onManualEntry,
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
                onManualEntry: onManualEntry,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('機種の既定は H☆C!!（未指定を選び直せば null が伝播）', (
      WidgetTester tester,
    ) async {
      String? captured = 'sentinel';
      await pumpSheet(
        tester,
        onManualEntry: (String? machine) {
          captured = machine;
        },
      );

      // 2026-11-24 ユーザー指示で既定を H☆C!! へ変更（旧: 未指定）。
      // 選択肢は未指定 / H☆C!! の 2 つのまま。
      expect(_chip(tester, 'species-machine-chip-0').selected, isTrue);

      // 明示的に「未指定」を選び直せば従来どおり null が伝播する。
      await tester.tap(
        find.byKey(const ValueKey<String>('species-machine-chip-none')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-manual-entry')),
      );
      await tester.pumpAndSettle();

      expect(captured, isNull);
    });

    testWidgets('H☆C!! を選んで手入力→機種がコールバックへ伝播する', (WidgetTester tester) async {
      String? captured;
      await pumpSheet(
        tester,
        onManualEntry: (String? machine) {
          captured = machine;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('species-machine-chip-0')),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, 'species-machine-chip-0').selected, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('species-row-manual-entry')),
      );
      await tester.pumpAndSettle();

      expect(captured, 'H☆C!!');
    });

    testWidgets('route(initialMachine) で開くと機種 chip が選択された状態', (
      WidgetTester tester,
    ) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      OcrResultScreen.route(
                        playRecordRepository: repository,
                        appBarTitle: 'スコア手入力',
                        initialMachine: 'H☆C!!',
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

      expect(_chip(tester, 'machine-chip-0').selected, isTrue);
      expect(_chip(tester, 'machine-chip-none').selected, isFalse);
    });
  });

  group('(7) 詳細画面の難易度・機種表示', () {
    Future<void> pumpDetail(WidgetTester tester, PlayRecord record) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      repository.store[record.id] = record;

      await tester.pumpWidget(
        MaterialApp(
          home: PlayRecordDetailScreen(
            playRecordRepository: repository,
            ocrEngine: FakeOcrEngine(),
            recordId: record.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('難易度実値と機種行が難易度行の直後に表示される', (WidgetTester tester) async {
      await pumpDetail(
        tester,
        _record(id: 'r1', difficulty: GameDifficulty.ex, machine: 'H☆C!!'),
      );

      expect(find.text('EX'), findsOneWidget);
      expect(find.text('機種'), findsOneWidget);
      expect(find.text('H☆C!!'), findsOneWidget);
    });

    testWidgets('未記録なら難易度・機種とも「—」', (WidgetTester tester) async {
      await pumpDetail(tester, _record(id: 'r1'));

      expect(find.text('機種'), findsOneWidget);
      expect(find.text('EX'), findsNothing);
      expect(find.text('H☆C!!'), findsNothing);
    });
  });
}
