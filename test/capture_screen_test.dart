// FR-9 撮影ガイド枠（案A）: アプリ内撮影画面のウィジェットテスト。
//
// ユーザー指示（2026-11-24）「撮影ガイド枠を実装してください」。範囲は案A:
// CameraPreview + 静的ガイド枠 + シャッター → 既存 OCR フローへ合流。
//
// 契約（リード裁定 2026-11-24）:
// - 初期化成功: プレビュー + ガイド枠 + シャッターが表示される。
// - 初期化失敗: 既存 image_picker カメラ経路へフォールバック（fallback 通知）。
// - 権限拒否: SnackBar 通知 + ギャラリー選択への誘導。
// - 撮影成功: 画像パスを結果として返し、OCR 側（呼び出し元）が処理する。
//
// WHY セッション注入: カメラ実体はプラットフォームチャネル依存で widget
// テストでは再現できない。CaptureSession という抽象で差し替え、分岐
// （成功・権限拒否・一般失敗）を決定的に検証する（DIP）。
library;

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoreyomipm/ui/capture_guide_overlay.dart';
import 'package:scoreyomipm/ui/capture_screen.dart';

class _FakeSession implements CaptureSession {
  _FakeSession({this.capturedPath = 'captured.jpg'});

  final String? capturedPath;
  int captureCount = 0;
  bool disposed = false;

  @override
  Future<void> initialize() async {}

  @override
  Widget buildPreview(BuildContext context) => const ColoredBox(
    key: ValueKey<String>('fake-preview'),
    color: Color(0xFF223344),
  );

  @override
  Future<String?> capture() async {
    captureCount++;
    return capturedPath;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 撮影画面を開き、pop で返った結果を [outcome] に記録するハーネス。
class _Harness {
  CaptureOutcome? outcome;
}

/// 画面向き制御（`SystemChrome.setPreferredOrientations`）の呼び出しを記録する。
///
/// WHY プラットフォームチャネルをモックするか: 向き固定は Flutter 側の
/// 状態ではなく OS への要求であり、ウィジェットツリーには現れない。要求の
/// 内容と順序を直接観測するのが唯一の検証手段になる。
List<MethodCall> _recordOrientationCalls(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (
        MethodCall call,
      ) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          calls.add(call);
        }
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return calls;
}

/// 向き要求の引数（`DeviceOrientation.*` の名前リスト）を取り出す。
List<String> _orientationArgs(MethodCall call) =>
    (call.arguments as List<Object?>).cast<String>();

Future<_Harness> _openScreen(
  WidgetTester tester,
  CaptureSessionFactory factory,
) async {
  final _Harness harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              harness.outcome = await Navigator.of(context)
                  .push<CaptureOutcome>(
                    MaterialPageRoute<CaptureOutcome>(
                      builder: (_) => CaptureScreen(sessionFactory: factory),
                    ),
                  );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  group('撮影画面（案A）', () {
    testWidgets('初期化成功でプレビュー・ガイド枠・シャッターが表示される', (WidgetTester tester) async {
      final _FakeSession session = _FakeSession();
      await _openScreen(tester, () async => session);

      expect(
        find.byKey(const ValueKey<String>('fake-preview')),
        findsOneWidget,
      );
      final Finder guide = find.byKey(
        const ValueKey<String>('capture-guide-overlay'),
      );
      expect(guide, findsOneWidget);
      expect(
        tester.widget<CustomPaint>(guide).painter,
        isA<CaptureGuidePainter>(),
      );
      expect(
        find.byKey(const ValueKey<String>('capture-shutter-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('capture-gallery-button')),
        findsOneWidget,
      );
    });

    testWidgets('シャッターで撮影し、画像パスを結果として返す', (WidgetTester tester) async {
      final _FakeSession session = _FakeSession();
      final _Harness harness = await _openScreen(tester, () async => session);

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-shutter-button')),
      );
      await tester.pumpAndSettle();

      expect(session.captureCount, 1);
      expect(session.disposed, isTrue, reason: '画面離脱でセッションを解放する契約');
      expect(harness.outcome?.kind, CaptureOutcomeKind.captured);
      expect(harness.outcome?.path, 'captured.jpg');
      // 撮影画面は閉じ、呼び出し元（OCR 側）へ戻る。
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('権限拒否は SnackBar 通知 + ギャラリー誘導で permissionDenied を返す', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _openScreen(
        tester,
        () async => throw CameraException('CameraAccessDenied', 'denied'),
      );
      await tester.pumpAndSettle();

      expect(harness.outcome?.kind, CaptureOutcomeKind.permissionDenied);
      expect(find.textContaining('ギャラリー'), findsOneWidget);
    });

    testWidgets('初期化失敗（その他）は fallback を返し既存ピッカー経路へ委ねる', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _openScreen(
        tester,
        () async => throw Exception('camera unavailable'),
      );
      await tester.pumpAndSettle();

      expect(harness.outcome?.kind, CaptureOutcomeKind.fallback);
      expect(find.textContaining('カメラ'), findsOneWidget);
    });

    testWidgets('ギャラリーボタンは gallery を返して閉じる', (WidgetTester tester) async {
      final _FakeSession session = _FakeSession();
      final _Harness harness = await _openScreen(tester, () async => session);

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-gallery-button')),
      );
      await tester.pumpAndSettle();

      expect(harness.outcome?.kind, CaptureOutcomeKind.gallery);
      expect(session.disposed, isTrue);
    });

    testWidgets('撮影失敗（null 返却）は閉じずに通知のみ', (WidgetTester tester) async {
      final _FakeSession session = _FakeSession(capturedPath: null);
      final _Harness harness = await _openScreen(tester, () async => session);

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-shutter-button')),
      );
      await tester.pumpAndSettle();

      expect(session.captureCount, 1);
      expect(harness.outcome, isNull);
      expect(
        find.byKey(const ValueKey<String>('capture-shutter-button')),
        findsOneWidget,
      );
    });
  });

  // ユーザー実機フィードバック（2026-11-24）「撮影画面をデフォルトで横に」。
  // リザルト画面は横長で、縦長画面の中央帯に写すと上下が無駄になり OCR へ
  // 渡るリザルト領域の画素が減る。横向き固定 + 離脱時の縦復帰を契約とする。
  group('撮影画面の向き（デフォルト横向き）', () {
    testWidgets('表示時に横向き（左右両対応）を要求する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(tester, () async => _FakeSession());

      expect(calls, isNotEmpty, reason: '表示時に必ず向きを要求する');
      final List<String> requested = _orientationArgs(calls.first);
      expect(
        requested,
        containsAll(<String>[
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
      );
      expect(
        requested,
        isNot(contains('DeviceOrientation.portraitUp')),
        reason: '縦向きを混ぜると端末の持ち方によっては縦のまま起動し得る',
      );
    });

    testWidgets('シャッター成功で閉じる前に縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(tester, () async => _FakeSession());

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-shutter-button')),
      );
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });

    testWidgets('ギャラリーボタンで閉じる前に縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(tester, () async => _FakeSession());

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-gallery-button')),
      );
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });

    testWidgets('閉じるボタンで閉じる前に縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(tester, () async => _FakeSession());

      await tester.tap(
        find.byKey(const ValueKey<String>('capture-close-button')),
      );
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });

    testWidgets('権限拒否で閉じる前に縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(
        tester,
        () async => throw CameraException('CameraAccessDenied', 'denied'),
      );
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });

    testWidgets('初期化失敗（フォールバック）で閉じる前に縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(
        tester,
        () async => throw Exception('camera unavailable'),
      );
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });

    testWidgets('システムバック相当の破棄でも縦向きへ復帰する', (WidgetTester tester) async {
      final List<MethodCall> calls = _recordOrientationCalls(tester);
      await _openScreen(tester, () async => _FakeSession());

      // 画面内ボタンを経由せず route を破棄する（OS の戻る操作相当）。
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pop();
      await tester.pumpAndSettle();

      _expectRestoredPortrait(calls);
    });
  });
}

/// 最後の向き要求が縦向き復帰（portraitUp を含む）であることを検証する。
void _expectRestoredPortrait(List<MethodCall> calls) {
  expect(calls, isNotEmpty);
  final List<String> last = _orientationArgs(calls.last);
  expect(last, <String>[
    'DeviceOrientation.portraitUp',
  ], reason: '離脱後は縦へ戻す（他画面は縦前提のレイアウトのため）');
}
