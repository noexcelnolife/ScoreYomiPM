// HomeScreen 実用化（v4 案1・docs/v4_home実用化_design_2026-11-23.md）のテスト。
//
// 検証対象:
// (1) AppBar タイトルから（PoC）表記が除去される（§2.1）
// (2) CTA（画像を取り込む）が収録曲辞書より上に配置される（§2.2）
// (3) FR-8 失効ガイド文言は文言不変で表示される（§2.3）
// (4) SongDbSection は折りたたみ（閉じた状態）がデフォルト（§2.4）
// (5) 最近の記録セクション: 直近 3 件+未確定残数バッジ・タップで記録一覧へ（§2.5）
// (6) 記録 0 件・取得失敗時は最近の記録セクションを非表示（§2.5）
// (7) エクスポート・インポートの導線（タスク 01a20c14・収録曲辞書の直後）

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'root_bundle_warmup.dart';

/// 曲辞書サービスのフェイク（home_screen_test.dart のローカルフェイクと同型）。
class _FakeSongDatabaseService implements SongDatabaseService {
  @override
  Future<String> loadDistributionUrl() async => '';

  @override
  Future<void> saveDistributionUrl(String url) async {}

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async =>
      const SongImportResult(success: false);

  @override
  Future<SongDatabaseStatus> loadStatus() async => const SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );
}

/// テスト用の PlayRecord を組み立てる。
///
/// WHY: repository フェイクの store に直接投入するため id・日時を明示する。
PlayRecord _record({
  required String id,
  required String? songName,
  required int? score,
  required PlayRecordStatus status,
  required DateTime playedAt,
}) {
  return PlayRecord(
    id: id,
    playedAt: playedAt,
    songName: songName,
    score: score,
    cool: null,
    great: null,
    good: null,
    bad: null,
    maxCombo: null,
    level: null,
    status: status,
    source: PlayRecordSource.playshare,
    resultImagePath: 'store://$id.png',
  );
}

/// 最新 3 件が画面に出るよう、古い方に pending を 1 件置いた 4 件を組む。
///
/// WHY: バッジの未確定件数は全件集計・行表示は日時上位 3 件という
/// 両方の契約を 1 つのデータセットで検証する（設計 §2.5）。
FakePlayRecordRepository _fourRecordsRepository() {
  final FakePlayRecordRepository repository = FakePlayRecordRepository();
  repository.store['r-old'] = _record(
    id: 'r-old',
    songName: '曲A',
    score: 100000,
    status: PlayRecordStatus.pending,
    playedAt: DateTime(2026, 11, 20),
  );
  repository.store['r-3'] = _record(
    id: 'r-3',
    songName: '曲B',
    score: 200000,
    status: PlayRecordStatus.confirmed,
    playedAt: DateTime(2026, 11, 21),
  );
  repository.store['r-2'] = _record(
    id: 'r-2',
    songName: '曲C',
    score: 300000,
    status: PlayRecordStatus.confirmed,
    playedAt: DateTime(2026, 11, 22),
  );
  repository.store['r-1'] = _record(
    id: 'r-1',
    songName: '曲D',
    score: 400000,
    status: PlayRecordStatus.confirmed,
    playedAt: DateTime(2026, 11, 23),
  );
  return repository;
}

void main() {
  setUpAll(warmRootBundleAssets);

  /// 共通の HomeScreen 構築。
  Widget homeWidget(FakePlayRecordRepository repository) {
    return MaterialApp(
      home: HomeScreen(
        ocrEngine: FakeOcrEngine(),
        songDatabaseService: _FakeSongDatabaseService(),
        playRecordRepository: repository,
      ),
    );
  }

  testWidgets('(1) AppBar タイトルから（PoC）表記が除去される', (WidgetTester tester) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    expect(find.text('スコアヨミPM'), findsOneWidget);
    expect(find.textContaining('（PoC）'), findsNothing);
  });

  testWidgets('(2) CTA が収録曲辞書セクションより上に配置される', (WidgetTester tester) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    // WHY: 折りたたみ中の ExpansionTile 本体は可視なので矩形比較が成立する。
    final Rect ctaRect = tester.getRect(find.text('画像を取り込む'));
    final Rect songDbRect = tester.getRect(find.text('収録曲辞書'));
    expect(ctaRect.top, lessThan(songDbRect.top));
  });

  testWidgets('(3) FR-8 失効ガイドの文言を完全一致で固定する', (WidgetTester tester) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    expect(find.text('プレーシェアは一定期間で見られなくなるため、お早めに取り込みください'), findsOneWidget);
  });

  testWidgets('(4) SongDbSection は折りたたみがデフォルトで、展開すると入力欄が出る', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    // WHY: 既定は閉じた状態 → 入力欄は画面に存在しない（offstage を既定の
    // finder はスキップする）。
    expect(
      find.byKey(const ValueKey<String>('song-db-url-field')),
      findsNothing,
    );

    await tester.ensureVisible(find.text('収録曲辞書'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('収録曲辞書'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('song-db-url-field')),
      findsOneWidget,
    );
  });

  testWidgets('(5) 最近の記録: 直近 3 件+未確定バッジ表示・タップで記録一覧へ', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(homeWidget(_fourRecordsRepository()));
    await tester.pumpAndSettle();

    expect(find.text('最近の記録'), findsOneWidget);
    // WHY: 日時降順の上位 3 件のみ。最古の曲A（pending）は行には出ないが
    // バッジ件数には数える。
    expect(find.text('曲D'), findsOneWidget);
    expect(find.text('曲C'), findsOneWidget);
    expect(find.text('曲B'), findsOneWidget);
    expect(find.text('曲A'), findsNothing);
    expect(find.text('未確定 1件'), findsOneWidget);

    await tester.ensureVisible(find.text('曲D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲D'));
    await tester.pumpAndSettle();

    expect(find.text('記録一覧'), findsOneWidget);
  });

  testWidgets('(6a) 記録 0 件では最近の記録セクションを表示しない', (WidgetTester tester) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    expect(find.text('最近の記録'), findsNothing);
  });

  testWidgets('(6b) 取得失敗時も最近の記録セクションを表示しない', (WidgetTester tester) async {
    await tester.pumpWidget(
      homeWidget(FakePlayRecordRepository(failOnList: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('最近の記録'), findsNothing);
  });

  testWidgets('(7a) エクスポート・インポートは折りたたみで、展開すると 3 項目が出る', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    // WHY: maintainState 既定 false の ExpansionTile は、閉じている間は
    // 子ウィジェットを組み立てない（曲辞書の (4) と同じ前提）。
    expect(find.text('ZIP でバックアップ'), findsNothing);

    await tester.ensureVisible(find.text('エクスポート・インポート'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('エクスポート・インポート'));
    await tester.pumpAndSettle();

    expect(find.text('ZIP でバックアップ'), findsOneWidget);
    expect(find.text('CSV で出力'), findsOneWidget);
    expect(find.text('バックアップから復元'), findsOneWidget);
  });

  testWidgets('(7b) 復元の遷移: PlayRecordBulkWriter 未実装なら利用不可と表示する', (
    WidgetTester tester,
  ) async {
    // WHY: ホームが持つ型は PlayRecordRepository で、BulkWriter の実装保証が
    // 型に無い。実装していない場合は復元させず、画面側で理由を出す。
    await tester.pumpWidget(homeWidget(FakePlayRecordRepository()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('エクスポート・インポート'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('エクスポート・インポート'));
    await tester.pumpAndSettle();
    // WHY: 曲辞書の直後に置いたため、展開すると復元の項目が画面外に出る。
    await tester.ensureVisible(find.text('バックアップから復元'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('バックアップから復元'));
    await tester.pumpAndSettle();

    expect(find.text('バックアップ'), findsOneWidget);
    expect(find.text('この端末では復元を利用できません'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('backup-import')), findsNothing);
  });
}
