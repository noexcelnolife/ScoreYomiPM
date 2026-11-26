import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// rootBundle の asset キャッシュを実非同期ゾーンで温める（ホーム画面系テスト共通）。
///
/// WHY: HomeScreen の収録曲辞書タイトル行（案A）は表示時にマージ辞書（内蔵シード
/// JSON）を読むため、HomeScreen を pump するテストは rootBundle に触れる。
/// testWidgets は FakeAsync 下で動くので、最初のテストのゾーンで作られた
/// キャッシュ済み Future は後続テストのゾーンでは完了せず、ライブ検索などの
/// await が返らないまま落ちる（実行順で結果が変わる flaky の原因）。
/// setUpAll は FakeAsync の外で走るため、ここで温めておけば全テストが完了済みの
/// Future を参照できる。
Future<void> warmRootBundleAssets() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await rootBundle.loadString('assets/songs/seed_v2.json');
}
