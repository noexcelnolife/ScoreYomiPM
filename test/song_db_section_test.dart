// SongDbSection のウィジェットテスト（fake サービス＋fake ピッカーで検証）。
import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/song_db_section.dart';

/// テスト用の SongDatabaseService fake（呼び出し記録と結果の注入ができる）。
class _FakeSongDatabaseService implements SongDatabaseService {
  _FakeSongDatabaseService({
    this.storedUrl = '',
    this.updateResult = const SongDbUpdateResult(
      status: SongDbUpdateStatus.upToDate,
    ),
    this.importResult = const SongImportResult(success: true, songCount: 3),
    SongDatabaseStatus? status,
  }) : status = status ?? _emptyStatus;

  /// 未取得（ファイルが無い）状態。
  static const SongDatabaseStatus _emptyStatus = SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );

  /// 最終操作の記録に載せる時刻。
  ///
  /// WHY: ローカル時刻で作れば toLocal() を経ても表示がずれない。
  static final DateTime operationAt = DateTime(2026, 11, 25, 9, 12);

  /// loadDistributionUrl が返す（saveDistributionUrl が更新する）URL。
  String storedUrl;

  /// updateFromConfiguredUrl が返す結果。
  SongDbUpdateResult updateResult;

  /// importAdditionalJson が返す結果。
  SongImportResult importResult;

  /// loadStatus が返す状態。更新・取り込みのたびに実装と同じ規約で最終操作の
  /// 記録を書き換える（UI が再取得できていなければ最終操作行が出ない）。
  SongDatabaseStatus status;

  /// true にすると loadStatus が IO 例外を投げる（UI 側ガードの検証用）。
  bool failStatusLoad = false;

  /// 設定すると更新処理の完了をこの Completer で制御できる。
  ///
  /// WHY: 即時完了する fake では busy 状態が 1 フレームも続かず、
  /// 進捗インジケーター表示を検証できないため。
  Completer<void>? updateGate;

  int loadUrlCallCount = 0;
  int saveUrlCallCount = 0;
  int updateCallCount = 0;
  int importCallCount = 0;
  int loadStatusCallCount = 0;

  @override
  Future<String> loadDistributionUrl() async {
    loadUrlCallCount++;
    return storedUrl;
  }

  @override
  Future<void> saveDistributionUrl(String url) async {
    saveUrlCallCount++;
    storedUrl = url;
  }

  @override
  Future<SongDatabaseStatus> loadStatus() async {
    loadStatusCallCount++;
    if (failStatusLoad) {
      throw const FileSystemException('settings.json を読めない');
    }
    return status;
  }

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async {
    updateCallCount++;
    final Completer<void>? gate = updateGate;
    if (gate != null) {
      await gate.future;
    }
    final SongDbUpdateResult result = updateResult;
    status = SongDatabaseStatus(
      distributionUrl: storedUrl,
      main: status.main,
      additional: status.additional,
      lastOperation: _updateOperation(result),
    );
    return result;
  }

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async {
    updateCallCount++;
    return updateResult;
  }

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
  }) async {
    importCallCount++;
    final SongImportResult result = importResult;
    status = SongDatabaseStatus(
      distributionUrl: storedUrl,
      main: status.main,
      additional: result.success
          ? SongDbSourceStatus(exists: true, songCount: result.songCount)
          : status.additional,
      lastOperation: SongDbLastOperation(
        kind: SongDbOperationKind.importAdditional,
        outcome: result.success
            ? SongDbOperationOutcome.success
            : SongDbOperationOutcome.failure,
        at: operationAt,
        message: result.success ? null : result.message,
        songCount: result.songCount,
        sourceFileName: fileName,
      ),
    );
    return result;
  }

  /// 更新結果を最終操作の記録へ変換する（lib/songdb の実装と同じ規約）。
  SongDbLastOperation _updateOperation(SongDbUpdateResult result) {
    return SongDbLastOperation(
      kind: SongDbOperationKind.update,
      outcome: _outcomeOf(result.status),
      at: operationAt,
      message: _messageOf(result.status, result.message),
      songCount: result.songCount,
      dbVersion: result.dbVersion,
    );
  }

  static SongDbOperationOutcome _outcomeOf(SongDbUpdateStatus status) {
    switch (status) {
      case SongDbUpdateStatus.applied:
      case SongDbUpdateStatus.upToDate:
        return SongDbOperationOutcome.success;
      case SongDbUpdateStatus.skippedNoUrl:
        return SongDbOperationOutcome.skipped;
      case SongDbUpdateStatus.failed:
        return SongDbOperationOutcome.failure;
    }
  }

  static String? _messageOf(SongDbUpdateStatus status, String? message) {
    switch (status) {
      case SongDbUpdateStatus.skippedNoUrl:
        return message ?? '配信 URL が未設定です';
      case SongDbUpdateStatus.failed:
        return message;
      case SongDbUpdateStatus.applied:
      case SongDbUpdateStatus.upToDate:
        return null;
    }
  }

}

void main() {
  Future<void> pumpSection(
    WidgetTester tester,
    _FakeSongDatabaseService service, {
    Future<PickedFile?> Function()? picker,
    int? seedCount,
    int? totalCount,
    VoidCallback? onDictionaryChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SongDbSection(
            songDatabaseService: service,
            pickAdditionalFile: picker ?? () async => null,
            seedSongCount: seedCount == null ? null : () async => seedCount,
            totalSongCount: totalCount == null ? null : () async => totalCount,
            onDictionaryChanged: onDictionaryChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('URL 未設定で起動 → 自動更新も通知も行わない（サイレント）', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      storedUrl: '',
    );
    await pumpSection(tester, service);

    expect(service.updateCallCount, 0);
    expect(find.byType(SnackBar), findsNothing);
    // 常設ステータス行は開いた時点から必ず出る（旧 _statusMessage の置き換え）。
    expect(find.text('配信DB 未取得'), findsOneWidget);
    expect(find.text('追加DB 未取得'), findsOneWidget);
    expect(find.byKey(const ValueKey('song-db-last-operation')), findsNothing);
  });

  testWidgets('URL 設定済みで起動 → 自動更新 1 回と最終操作行を表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      storedUrl: 'https://example.test/db.json',
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.upToDate,
        dbVersion: 4,
      ),
    );
    await pumpSection(tester, service);

    expect(service.updateCallCount, 1);
    expect(find.text('最終更新: 11/25 09:12 成功（dbVersion 4）'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('ボタン押下 → URL を保存して更新し、最終操作行に成功を表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.applied,
        dbVersion: 7,
        songCount: 120,
      ),
    );
    await pumpSection(tester, service);

    await tester.enterText(
      find.byKey(const ValueKey('song-db-url-field')),
      'https://example.test/main_v1.json',
    );
    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(service.saveUrlCallCount, 1);
    expect(service.storedUrl, 'https://example.test/main_v1.json');
    expect(service.updateCallCount, 1);
    expect(find.text('最終更新: 11/25 09:12 成功（dbVersion 7・120曲）'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('更新失敗 → SnackBar と失敗理由の最終操作行を表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.failed,
        message: '辞書の取得に失敗しました: offline',
      ),
    );
    await pumpSection(tester, service);

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('辞書の取得に失敗しました: offline'), findsOneWidget);
    expect(
      find.text('最終更新: 11/25 09:12 失敗（辞書の取得に失敗しました: offline）'),
      findsOneWidget,
    );
  });

  testWidgets('URL 未入力で更新がスキップされたら SnackBar で案内する（P-5）', (tester) async {
    // WHY: URL 空により DB 更新をスキップする経路はサイレントで分からない
    // （smoke test レポート P-5）。リード裁定（2026-11-23）により 1 行の
    // SnackBar 案内を足す。インライン表示は成功時の体裁と同様に出さない。
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      storedUrl: '',
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.skippedNoUrl,
        message: null,
      ),
    );
    await pumpSection(tester, service);

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('配信 URL が未入力のため更新をスキップしました'), findsOneWidget);
    // スキップは時刻を持たないため「—」で表す（案B）。
    expect(find.text('最終更新: — スキップ（配信 URL が未設定です）'), findsOneWidget);
  });

  testWidgets('処理中は LinearProgressIndicator を表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService();
    final Completer<void> gate = Completer<void>();
    service.updateGate = gate;
    await pumpSection(tester, service);

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pump(); // 更新処理の完了を待たずに 1 フレームだけ進める。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('追加DB取り込み → ピッカーのパスで取り込み、最終取込行に表示する', (tester) async {
    int notifyCount = 0;
    final _FakeSongDatabaseService service = _FakeSongDatabaseService();
    await pumpSection(
      tester,
      service,
      picker: () async => PickedFile(name: 'additional.json', bytes: Uint8List(4)),
      onDictionaryChanged: () => notifyCount++,
    );

    await tester.tap(find.byKey(const ValueKey('song-db-import-button')));
    await tester.pumpAndSettle();

    expect(service.importCallCount, 1);
    expect(
      find.text('最終取込: 11/25 09:12 成功（「additional.json」から 3曲）'),
      findsOneWidget,
    );
    expect(notifyCount, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('追加DB取り込み失敗 → SnackBar と失敗理由の最終取込行を表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      importResult: const SongImportResult(
        success: false,
        message: 'JSON の形式が不正です',
      ),
    );
    await pumpSection(
      tester,
      service,
      picker: () async => PickedFile(name: 'broken.json', bytes: Uint8List(4)),
    );

    await tester.tap(find.byKey(const ValueKey('song-db-import-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('JSON の形式が不正です'), findsOneWidget);
    expect(find.text('最終取込: 11/25 09:12 失敗（JSON の形式が不正です）'), findsOneWidget);
  });

  testWidgets('追加DB取り込みでキャンセル → 何もしない', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService();
    await pumpSection(tester, service);

    await tester.tap(find.byKey(const ValueKey('song-db-import-button')));
    await tester.pumpAndSettle();

    expect(service.importCallCount, 0);
    expect(find.byKey(const ValueKey('song-db-last-operation')), findsNothing);
    expect(find.text('追加DB 未取得'), findsOneWidget);
  });

  testWidgets('ステータス行 → 内蔵シード・配信DB・追加DB・合計を常設表示する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      status: SongDatabaseStatus(
        distributionUrl: 'https://example.test/db.json',
        main: SongDbSourceStatus(
          exists: true,
          songCount: 3180,
          dbVersion: 12,
          updatedAt: DateTime(2026, 11, 20, 14, 32),
        ),
        additional: SongDbSourceStatus(
          exists: true,
          songCount: 42,
          updatedAt: DateTime(2026, 11, 24, 20, 10),
        ),
      ),
    );
    await pumpSection(tester, service, seedCount: 33, totalCount: 3201);

    expect(find.text('内蔵シード 33曲'), findsOneWidget);
    expect(
      find.text('配信DB 3,180曲（dbVersion 12・11/20 14:32 更新）'),
      findsOneWidget,
    );
    expect(find.text('追加DB 42曲（11/24 20:10 取込）'), findsOneWidget);
    expect(find.text('合計 3,201曲（サジェスト対象）'), findsOneWidget);
  });

  testWidgets('exists かつ songCount が null なら「読込失敗」を表示する', (tester) async {
    // WHY: 権限・ロック・壊れた JSON は exists=true かつ songCount=null になる
    // （lib/songdb の 2 段構えの判定）。「未取得」と区別して表示する。
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      status: const SongDatabaseStatus(
        distributionUrl: '',
        main: SongDbSourceStatus(exists: true),
        additional: SongDbSourceStatus(exists: true),
      ),
    );
    await pumpSection(tester, service);

    expect(find.text('配信DB 読込失敗'), findsOneWidget);
    expect(find.text('追加DB 読込失敗'), findsOneWidget);
  });

  testWidgets('loadStatus が IO 例外でも落ちず「—」表示に倒す', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService()
      ..failStatusLoad = true;
    await pumpSection(tester, service);

    expect(tester.takeException(), isNull);
    expect(find.text('内蔵シード —'), findsOneWidget);
    expect(find.text('配信DB —'), findsOneWidget);
    expect(find.text('追加DB —'), findsOneWidget);
    expect(find.text('合計 —（サジェスト対象）'), findsOneWidget);
    expect(find.byKey(const ValueKey('song-db-last-operation')), findsNothing);
  });

  testWidgets('更新後は loadStatus を再取得して行を最新化する', (tester) async {
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.applied,
        dbVersion: 13,
        songCount: 3200,
      ),
    );
    await pumpSection(tester, service);
    final int beforeTap = service.loadStatusCallCount;

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(service.loadStatusCallCount, greaterThan(beforeTap));
    expect(
      find.text('最終更新: 11/25 09:12 成功（dbVersion 13・3,200曲）'),
      findsOneWidget,
    );
  });

  testWidgets('辞書が差し替わったら親へ通知する（適用時のみ）', (tester) async {
    int notifyCount = 0;
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.applied,
        dbVersion: 13,
      ),
    );
    await pumpSection(
      tester,
      service,
      onDictionaryChanged: () => notifyCount++,
    );

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(notifyCount, 1);
  });

  testWidgets('最新（upToDate）では親へ通知しない', (tester) async {
    // WHY: 辞書が変わっていないのでライブ検索キャッシュを捨てる必要がない。
    int notifyCount = 0;
    final _FakeSongDatabaseService service = _FakeSongDatabaseService(
      updateResult: const SongDbUpdateResult(
        status: SongDbUpdateStatus.upToDate,
        dbVersion: 13,
      ),
    );
    await pumpSection(
      tester,
      service,
      onDictionaryChanged: () => notifyCount++,
    );

    await tester.tap(find.byKey(const ValueKey('song-db-update-button')));
    await tester.pumpAndSettle();

    expect(notifyCount, 0);
  });

  group('SongDbTotalCountSubtitle', () {
    Future<void> pumpSubtitle(
      WidgetTester tester,
      Future<int?> Function() loadTotalCount, {
      int refreshToken = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongDbTotalCountSubtitle(
              loadTotalCount: loadTotalCount,
              refreshToken: refreshToken,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('総曲数を 3 桁区切りで表示する', (tester) async {
      await pumpSubtitle(tester, () async => 3201);

      expect(find.text('3,201曲'), findsOneWidget);
    });

    testWidgets('取得できない場合は「—」を表示する', (tester) async {
      await pumpSubtitle(
        tester,
        () async => throw const FileSystemException('辞書を読めない'),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('refreshToken が変わると再取得する', (tester) async {
      int calls = 0;
      Future<int?> load() async {
        calls++;
        return 3200 + calls;
      }

      await pumpSubtitle(tester, load);
      expect(find.text('3,201曲'), findsOneWidget);

      await pumpSubtitle(tester, load, refreshToken: 1);

      expect(calls, 2);
      expect(find.text('3,202曲'), findsOneWidget);
    });
  });
}
