// 難易度カラーリング（01a20a53）のテスト。
//
// ユーザー指示（2026-11-24）: ゲーム内の難易度色イメージ
// LIGHT = 明るい青 / NORMAL = 明るい緑 / HYPER = 黄色 / EX = 赤 を
// 入力画面（難易度チップ）・一覧副題・詳細の 3 面で視覚表示する。
//
// 契約:
// - 色の単一真実源は lib/ui/difficulty_color.dart の difficultyColor() 1 本。
//   データ層（enum / JSON / PlayRecord）は無変更・色を持たない。
// - null（不明）は非着色（null 返却）＝従来色のまま。
// - ラベル文字列（LIGHT…大文字）と既存 ValueKey は不変（v5 テスト non-reg）。
//
// 検証ケース:
// (1) ライト明度の 4 色（白背景での判読性を優先した値）
// (2) ダーク明度の 4 色（ゲーム内イメージの明るい色）
// (3) null は両明度で null
// (4) 一覧副題: 難易度語のみ色付き（素テキストは従来どおり）
// (5) 一覧副題: 難易度 null は色付き span を出さない（v5 導入前レコード non-reg）
// (6) 詳細: 難易度値が難易度色
// (7) 入力チップ: 4 チップに色ドット常時表示 + 選択チップは同色ティント
//
// WHY(red-first の同コミット同梱): difficulty_color.dart は本タスクで新設する
// ため、このファイルは赤（コンパイル失敗）から始める。実装と同一コミットに
// 同梱し、赤→緑の中間で analyze を壊した状態をコミットに残さない。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/difficulty_color.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';
import 'package:scoreyomipm/ui/play_records_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// ライト明度の期待値（コード側と二重定義にして値の取り違えを検出する）。
const Color _lightLight = Color(0xFF0277BD);
const Color _lightNormal = Color(0xFF2E7D32);
const Color _lightHyper = Color(0xFFB8860B);
const Color _lightEx = Color(0xFFC62828);

/// ダーク明度の期待値（ゲーム内イメージそのまま）。
const Color _darkLight = Color(0xFF4FC3F7);
const Color _darkNormal = Color(0xFF66BB6A);
const Color _darkHyper = Color(0xFFFBC02D);
const Color _darkEx = Color(0xFFEF5350);

PlayRecord _record(
  File image, {
  required String id,
  GameDifficulty? difficulty,
}) {
  return PlayRecordDraft(
    songName: '曲A',
    score: 98108,
    level: 42,
    difficulty: difficulty,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(
    id: id,
    resultImagePath: image.path,
    playedAt: DateTime(2026, 11, 25, 10),
  );
}

/// 一覧副題の Text.rich から難易度語の span を取り出す（見つからなければ null）。
TextSpan? _difficultySpan(Text subtitle) {
  final InlineSpan? root = subtitle.textSpan;
  if (root is! TextSpan) {
    return null;
  }
  for (final InlineSpan span in root.children ?? <InlineSpan>[]) {
    if (span is TextSpan && span.text?.trim() == 'HYPER') {
      return span;
    }
  }
  return null;
}

void main() {
  group('難易度色（単一真実源）', () {
    test('ライト明度: LIGHT=青 / NORMAL=緑 / HYPER=黄 / EX=赤', () {
      expect(difficultyColor(GameDifficulty.light), _lightLight);
      expect(difficultyColor(GameDifficulty.normal), _lightNormal);
      expect(difficultyColor(GameDifficulty.hyper), _lightHyper);
      expect(difficultyColor(GameDifficulty.ex), _lightEx);
    });

    test('ダーク明度: ゲーム内イメージの明るい 4 色', () {
      expect(
        difficultyColor(GameDifficulty.light, brightness: Brightness.dark),
        _darkLight,
      );
      expect(
        difficultyColor(GameDifficulty.normal, brightness: Brightness.dark),
        _darkNormal,
      );
      expect(
        difficultyColor(GameDifficulty.hyper, brightness: Brightness.dark),
        _darkHyper,
      );
      expect(
        difficultyColor(GameDifficulty.ex, brightness: Brightness.dark),
        _darkEx,
      );
    });

    test('不明（null）は両明度で非着色（null 返却）', () {
      expect(difficultyColor(null), isNull);
      expect(difficultyColor(null, brightness: Brightness.dark), isNull);
    });

    test('4 種の色は明度ごとに相互に区別できる', () {
      final Set<Color> light = GameDifficulty.values
          .map((GameDifficulty d) => difficultyColor(d)!)
          .toSet();
      final Set<Color> dark = GameDifficulty.values
          .map(
            (GameDifficulty d) =>
                difficultyColor(d, brightness: Brightness.dark)!,
          )
          .toSet();
      expect(light.length, GameDifficulty.values.length);
      expect(dark.length, GameDifficulty.values.length);
    });
  });

  group('一覧副題（記録一覧）', () {
    testWidgets('難易度語のみ難易度色になり、残りの素テキストは従来どおり', (WidgetTester tester) async {
      final File image = createTestImageFile();
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['p-1'] = _record(
          image,
          id: 'p-1',
          difficulty: GameDifficulty.hyper,
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayRecordsScreen(
              playRecordRepository: repository,
              ocrEngine: FakeOcrEngine(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Text subtitle = tester.widget<Text>(
        find.textContaining('HYPER Lv42'),
      );
      final TextSpan? label = _difficultySpan(subtitle);
      expect(label, isNotNull, reason: '難易度語の span が見つからない');
      expect(label!.style?.color, difficultyColor(GameDifficulty.hyper));
      // 文字列そのものは v5 導入時の形式「日付 / HYPER Lv42 / …」を保つ。
      expect(
        subtitle.textSpan!.toPlainText(),
        startsWith('2026/11/25 / HYPER Lv42 / '),
      );
    });

    testWidgets('難易度 null は色付き span を出さない（従来の Lv のみ表示）', (
      WidgetTester tester,
    ) async {
      final File image = createTestImageFile();
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['p-1'] = _record(image, id: 'p-1');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayRecordsScreen(
              playRecordRepository: repository,
              ocrEngine: FakeOcrEngine(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Text subtitle = tester.widget<Text>(find.textContaining('Lv42'));
      expect(
        subtitle.textSpan!.toPlainText(),
        startsWith('2026/11/25 / Lv42 / '),
      );
      expect(_difficultySpan(subtitle), isNull);
    });
  });

  group('詳細（記録詳細）', () {
    testWidgets('難易度の実値が難易度色で表示される', (WidgetTester tester) async {
      final File image = createTestImageFile();
      final FakePlayRecordRepository repository = FakePlayRecordRepository()
        ..store['p-1'] = _record(
          image,
          id: 'p-1',
          difficulty: GameDifficulty.ex,
        );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayRecordDetailScreen(
            playRecordRepository: repository,
            ocrEngine: FakeOcrEngine(),
            recordId: 'p-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 01a20b17: 詳細画面の難易度はコピー可能化に伴い SelectableText で描画
      // される（着色は style で維持）。検証の意図「難易度色で表示される」は
      // 変えず、ウィジェット型だけ追随する。
      final SelectableText value = tester.widget<SelectableText>(
        find.widgetWithText(SelectableText, 'EX'),
      );
      expect(value.style?.color, difficultyColor(GameDifficulty.ex));
    });
  });

  group('入力画面（難易度チップ）', () {
    testWidgets('4 チップに色ドットを常時表示し、選択チップは同色ティント', (WidgetTester tester) async {
      final FakePlayRecordRepository repository = FakePlayRecordRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                OcrResultScreen.route(
                  playRecordRepository: repository,
                  appBarTitle: 'スコア手入力',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      for (final GameDifficulty d in GameDifficulty.values) {
        final ChoiceChip chip = tester.widget<ChoiceChip>(
          find.byKey(ValueKey<String>('difficulty-chip-${d.name}')),
        );
        final Color? expected = difficultyColor(d);
        final CircleAvatar? dot = chip.avatar as CircleAvatar?;
        expect(dot, isNotNull, reason: '${d.name} チップに色ドットがない');
        expect(dot!.backgroundColor, expected);
        // 選択状態に関係なく色見本が見えることが契約。選択時はチェックマークが
        // avatar 位置に重なるため、同色ティントの背景でも色を維持する。
        expect(chip.selectedColor, expected!.withValues(alpha: 0.22));
      }

      final ChoiceChip none = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey<String>('difficulty-chip-none')),
      );
      expect(none.avatar, isNull);
      expect(none.selectedColor, isNull);
    });
  });
}
