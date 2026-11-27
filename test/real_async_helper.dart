import 'package:flutter_test/flutter_test.dart';

/// 実 I/O（`dart:io` の読み書き）を伴う処理が終わるまで待つ。
///
/// WHY 必要か: `testWidgets` の本体は FakeAsync の下で動くため、`File.readAsBytes`
/// のような実 I/O の Future は「時間」を pump しても完了しない。`runAsync` の
/// 中でだけ実時間が進むので、そこで少しずつ待っては pump して再描画させる。
///
/// WHY 回数を絞るか: 1 回の待ち時間を長くすると、実時間に依存した不安定さが
/// 増す。短い待ちを数回繰り返す方が、完了した時点で先に進めるぶん速い。
Future<void> pumpThroughRealIo(
  WidgetTester tester, {
  int steps = 8,
  Duration step = const Duration(milliseconds: 25),
}) async {
  for (int i = 0; i < steps; i++) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
