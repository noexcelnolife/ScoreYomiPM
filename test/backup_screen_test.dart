// バックアップ画面の widget テスト（タスク 01a20c14・red-first）。
//
// WHY(フェイク注入): file_selector / flutter_file_dialog / path_provider は
// プラットフォームチャネルを使うため widget テストから直接呼べない。画面は
// [FileExportGateway] とサービスをコンストラクタ注入で受け取るので、ここでは
// 入出力だけをフェイクに差し替え、ZIP/CSV の生成と復元は本物のサービスを通す
//（データ層との結線まで含めて壊れていないことを確認する）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/app_info.dart';
import 'package:scoreyomipm/backup/backup_export_service.dart';
import 'package:scoreyomipm/backup/backup_format_exception.dart';
import 'package:scoreyomipm/backup/backup_import_service.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_bulk_writer.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/file_export_gateway.dart';
import 'package:scoreyomipm/ui/backup_screen.dart';

import 'fake_play_record_repository.dart';

/// 保存/選択の結果を握るフェイク。呼ばれた回数と引数を記録する。
class _FakeGateway implements FileExportGateway {
  _FakeGateway({this.savePath = '/sdcard/Download/saved'});

  XFile? zipResult;
  String? savePath;

  int pickCount = 0;
  int saveCount = 0;
  Uint8List? savedBytes;
  String? savedFileName;
  String? savedMimeType;

  @override
  Future<XFile?> pickZip() async {
    pickCount++;
    return zipResult;
  }

  @override
  Future<String?> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    saveCount++;
    savedBytes = bytes;
    savedFileName = fileName;
    savedMimeType = mimeType;
    return savePath;
  }
}

/// 一括書き込みのフェイク。結果だけを差し替える。
class _FakeWriter implements PlayRecordBulkWriter {
  _FakeWriter({
    this.result = const BulkImportResult(
      imported: 2,
      skipped: 0,
      missingImages: 0,
    ),
  });

  BulkImportResult result;
  bool? lastReplaceAll;

  @override
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
    Map<String, Uint8List?>? imageBytesById,
  }) async {
    lastReplaceAll = replaceAll;
    return result;
  }
}

/// 画面と差し替え対象をまとめて持つテスト用ハーネス。
class _Harness {
  _Harness({
    required this.exportService,
    required this.importService,
    required this.writer,
    required this.gateway,
    required this.existingCount,
  });

  final BackupExportService exportService;
  final BackupImportService importService;
  final _FakeWriter writer;
  final _FakeGateway gateway;
  final int existingCount;
}

_Harness _harness({
  List<PlayRecord> exportRecords = const <PlayRecord>[],
  List<PlayRecord> existingRecords = const <PlayRecord>[],
  BulkImportResult outcome = const BulkImportResult(
    imported: 2,
    skipped: 0,
    missingImages: 0,
  ),
  String? savePath = '/sdcard/Download/saved',
}) {
  final FakePlayRecordRepository repository = FakePlayRecordRepository();
  for (final PlayRecord record in exportRecords) {
    repository.store[record.id] = record;
  }
  final _FakeWriter writer = _FakeWriter(result: outcome);
  return _Harness(
    exportService: BackupExportService(
      repository: repository,
      appVersion: kAppVersion,
      songDatabaseService: FakeSongDatabaseServiceForTest(),
    ),
    importService: BackupImportService(
      listRecords: () async => existingRecords,
      writer: writer,
      songDatabaseService: FakeSongDatabaseServiceForTest(),
    ),
    writer: writer,
    gateway: _FakeGateway(savePath: savePath),
    existingCount: existingRecords.length,
  );
}

PlayRecord _record(String id, {String songName = 'Harmonia'}) => PlayRecord(
  id: id,
  playedAt: DateTime(2026, 11, 24, 12, 30),
  songName: songName,
  score: 98108,
  cool: 975,
  great: 58,
  good: 2,
  bad: 1,
  maxCombo: 733,
  level: 44,
  status: PlayRecordStatus.confirmed,
  source: PlayRecordSource.playshare,
  resultImagePath: '',
);

/// ファイル名の日時を固定するための時計（テストの決定性のため）。
DateTime _fixedNow() => DateTime(2026, 11, 24, 12, 30);

Widget _screen(
  _Harness harness, {
  bool withImport = true,
  BackupAction? initialAction,
}) {
  return MaterialApp(
    home: BackupScreen(
      exportService: harness.exportService,
      importService: withImport ? harness.importService : null,
      fileGateway: harness.gateway,
      existingRecordCount: () async => harness.existingCount,
      initialAction: initialAction,
      now: _fixedNow,
    ),
  );
}

/// 復元サービスは一時ディレクトリの作成と削除という実 I/O を 2 回行う。
/// fake async は実 I/O を進めないため、実時間の待機と描画を交互に繰り返して
/// 完了させる（pumpAndSettle だけでは永久に終わらない）。
Future<void> _pumpThroughRealIo(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// ZIP を選んだ状態にしてからインポート導線を押し、プレビューまで進める。
Future<void> _openImportPreview(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(_screen(harness));
  await tester.tap(find.byKey(const ValueKey<String>('backup-import')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('3 つの導線（ZIP / CSV / 復元）が表示される', (WidgetTester tester) async {
    await tester.pumpWidget(_screen(_harness()));

    expect(
      find.byKey(const ValueKey<String>('backup-export-zip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('backup-export-csv')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('backup-import')), findsOneWidget);
    expect(find.text('ZIP でバックアップ（画像込み）'), findsOneWidget);
    expect(find.text('CSV で出力（画像なし）'), findsOneWidget);
    expect(find.text('バックアップから復元'), findsOneWidget);
  });

  testWidgets('ZIP エクスポートの成功で保存が呼ばれ、完了メッセージにファイル名が出る', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
    );
    await tester.pumpWidget(_screen(harness));

    await tester.tap(find.byKey(const ValueKey<String>('backup-export-zip')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(harness.gateway.saveCount, 1);
    expect(harness.gateway.savedFileName, 'scoreman-20261124-1230.zip');
    expect(harness.gateway.savedMimeType, 'application/zip');
    expect(harness.gateway.savedBytes, isNotNull);
    expect(harness.gateway.savedBytes!.isNotEmpty, isTrue);
    expect(find.text('保存しました: scoreman-20261124-1230.zip'), findsOneWidget);
  });

  testWidgets('CSV エクスポートは BOM を 1 つだけ含む UTF-8 で保存する', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
    );
    await tester.pumpWidget(_screen(harness));

    await tester.tap(find.byKey(const ValueKey<String>('backup-export-csv')));
    await tester.pumpAndSettle();

    final Uint8List bytes = harness.gateway.savedBytes!;
    expect(harness.gateway.savedMimeType, 'text/csv');
    expect(harness.gateway.savedFileName, endsWith('.csv'));
    // WHY: BOM はエンコーダが付ける。UI 側で足すと 2 連 BOM になるため 1 個だけ。
    expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
    expect(bytes.sublist(3, 6), isNot(<int>[0xEF, 0xBB, 0xBF]));
    // WHY(バイト列で数える): dart:convert の utf8.decode は先頭 BOM を読み捨てる
    // ため、復号後の文字列では BOM の有無を判定できない（実測で確認済み）。
    // 有効な UTF-8 本文に U+FEFF 以外で BOM 列は現れないので、バイト列の出現数が
    // そのまま BOM の個数になる。
    int bomCount = 0;
    for (int i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0xEF && bytes[i + 1] == 0xBB && bytes[i + 2] == 0xBF) {
        bomCount++;
      }
    }
    expect(bomCount, 1, reason: 'BOM はエンコーダ付与の 1 個だけ（二重付与しない）');
    expect(utf8.decode(bytes).startsWith('実施日時'), isTrue);
    expect(utf8.decode(bytes).contains('\uFEFF'), isFalse);
  });

  testWidgets('保存ダイアログのキャンセルでは何も表示しない', (WidgetTester tester) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
      savePath: null,
    );
    await tester.pumpWidget(_screen(harness));

    await tester.tap(find.byKey(const ValueKey<String>('backup-export-zip')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(harness.gateway.saveCount, 1);
    expect(find.textContaining('保存しました'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('backup-error-dialog')),
      findsNothing,
    );
  });

  testWidgets('インポートのプレビューに件数・重複件数・アプリ版が出る', (WidgetTester tester) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1'), _record('r2')],
      existingRecords: <PlayRecord>[_record('r1')],
    );
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );

    await _openImportPreview(tester, harness);

    expect(
      find.byKey(const ValueKey<String>('backup-preview-dialog')),
      findsOneWidget,
    );
    expect(find.text('記録: 2 件'), findsOneWidget);
    expect(find.text('重複（既存と同一）: 1 件'), findsOneWidget);
    expect(find.text('メモのテンプレート: 0 件'), findsOneWidget);
    expect(find.text('既存の記録: 1 件'), findsOneWidget);
    expect(find.text('アプリ版: $kAppVersion'), findsOneWidget);
  });

  testWidgets('置換を選ぶと赤字の警告が出て実行ボタンの文言が変わる', (WidgetTester tester) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
      existingRecords: <PlayRecord>[_record('r1')],
    );
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );

    await _openImportPreview(tester, harness);
    await tester.tap(find.text('置換（既存をすべて削除して復元）'));
    await tester.pumpAndSettle();

    expect(find.textContaining('元に戻せません'), findsOneWidget);
    expect(find.text('置換して復元'), findsOneWidget);
    expect(find.text('復元する'), findsNothing);
  });

  testWidgets('インポート成功で結果ダイアログに 5 つの数値が出る', (WidgetTester tester) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1'), _record('r2')],
    );
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );
    await _openImportPreview(tester, harness);

    await tester.tap(find.text('復元する'));
    await _pumpThroughRealIo(tester);

    expect(
      find.byKey(const ValueKey<String>('backup-result-dialog')),
      findsOneWidget,
    );
    expect(find.text('取り込み: 2 件'), findsOneWidget);
    expect(find.text('スキップ: 0 件'), findsOneWidget);
    expect(find.text('画像復元: 0 枚'), findsOneWidget);
    expect(find.text('画像欠落: 0 件'), findsOneWidget);
    expect(find.text('テンプレート追加: 0 件'), findsOneWidget);
    // 既定は「追加」なので replaceAll は false で渡る。
    expect(harness.writer.lastReplaceAll, isFalse);
  });

  testWidgets('復元が成功すると true を返して画面を閉じる（一覧再読込の契機）', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
    );
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );
    bool? closedWith;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey<String>('open-backup'),
                onPressed: () async {
                  closedWith = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => BackupScreen(
                        exportService: harness.exportService,
                        importService: harness.importService,
                        fileGateway: harness.gateway,
                        existingRecordCount: () async => harness.existingCount,
                        now: _fixedNow,
                      ),
                    ),
                  );
                },
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('backup-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('復元する'));
    await _pumpThroughRealIo(tester);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(closedWith, isTrue);
    expect(find.byKey(const ValueKey<String>('open-backup')), findsOneWidget);
  });

  testWidgets('形式不正は BackupFormatException の message をそのまま出す', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _harness();
    final Uint8List broken = Uint8List.fromList(utf8.encode('これは ZIP ではない'));
    harness.gateway.zipResult = XFile.fromData(broken, name: 'broken.zip');
    String expected = '';
    try {
      await harness.importService.preview(broken);
    } on BackupFormatException catch (error) {
      expected = error.message;
    }
    expect(expected, isNotEmpty, reason: '前提: 壊れた ZIP は例外になる');

    await tester.pumpWidget(_screen(harness));
    await tester.tap(find.byKey(const ValueKey<String>('backup-import')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('backup-error-dialog')),
      findsOneWidget,
    );
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('ファイル選択のキャンセルでは何も起きない', (WidgetTester tester) async {
    final _Harness harness = _harness();
    harness.gateway.zipResult = null;

    await _openImportPreview(tester, harness);

    expect(harness.gateway.pickCount, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('復元サービスが無い端末ではインポート節を利用不可として出す', (WidgetTester tester) async {
    await tester.pumpWidget(_screen(_harness(), withImport: false));

    expect(
      find.byKey(const ValueKey<String>('backup-import-unavailable')),
      findsOneWidget,
    );
    expect(find.text('この端末では復元を利用できません'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('backup-import')), findsNothing);
  });

  testWidgets('ZIP 内が 0 件なら置換を選べない（全消去の防止）', (WidgetTester tester) async {
    final _Harness harness = _harness(exportRecords: const <PlayRecord>[]);
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );

    await _openImportPreview(tester, harness);

    expect(find.text('記録: 0 件'), findsOneWidget);
    final RadioListTile<ImportMode> replaceTile = tester
        .widget<RadioListTile<ImportMode>>(
          find.byKey(const ValueKey<String>('backup-import-mode-replace')),
        );
    expect(replaceTile.enabled, isFalse, reason: '0 件の置換は全消去になるため選べない');
    // 無効の理由が画面から読めること（リード指示: ボタン無効＋理由表示）。
    expect(find.textContaining('記録が 0 件のため置換は選べません'), findsOneWidget);
    expect(find.text('復元する'), findsOneWidget);
  });

  testWidgets('追加で 0 件（全件重複）は「変更はありません」の成功表示にする', (WidgetTester tester) async {
    // WHY: データ層はマージで imported=0 を返すだけ。UI がこれをエラー扱い
    // すると、2 回目のバックアップ適用が失敗に見えてしまう。
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1'), _record('r2')],
      existingRecords: <PlayRecord>[_record('r1'), _record('r2')],
      // WHY(0 を渡す): サービスは「ZIP 件数 − 書き込み対象 + 書き込み側の
      // スキップ」を返す。2 件とも既存 id なので書き込み側のスキップは 0 と
      // し、合計 2 件がスキップとして出ることを確かめる。
      outcome: const BulkImportResult(
        imported: 0,
        skipped: 0,
        missingImages: 0,
      ),
    );
    harness.gateway.zipResult = XFile.fromData(
      await harness.exportService.buildZip(),
      name: 'backup.zip',
    );

    await _openImportPreview(tester, harness);
    await tester.tap(
      find.byKey(const ValueKey<String>('backup-import-confirm')),
    );
    await _pumpThroughRealIo(tester);

    expect(
      find.byKey(const ValueKey<String>('backup-result-dialog')),
      findsOneWidget,
    );
    expect(find.text('変更はありません（すべて既存と重複しています）'), findsOneWidget);
    expect(find.text('取り込み: 0 件'), findsOneWidget);
    expect(find.text('スキップ: 2 件'), findsOneWidget);
    // エラー表示（別ダイアログ・エラー文言）になっていないこと。
    expect(
      find.byKey(const ValueKey<String>('backup-error-dialog')),
      findsNothing,
    );
    expect(find.text('エラー'), findsNothing);
    // WHY(色で確かめる): 「成功として扱う」は文言だけでなく見た目も対象。
    // エラー色（colorScheme.error）が明示されていないことを確認する。
    final BuildContext context = tester.element(
      find.text('変更はありません（すべて既存と重複しています）'),
    );
    final ThemeData theme = Theme.of(context);
    final Text message = tester.widget<Text>(
      find.text('変更はありません（すべて既存と重複しています）'),
    );
    expect(message.style?.color, isNot(theme.colorScheme.error));
  });

  testWidgets('ホームの導線相当: initialAction で ZIP 保存が自動実行される', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _harness(
      exportRecords: <PlayRecord>[_record('r1')],
    );

    await tester.pumpWidget(
      _screen(harness, initialAction: BackupAction.exportZip),
    );
    await tester.pumpAndSettle();

    expect(harness.gateway.saveCount, 1);
    expect(harness.gateway.savedFileName, 'scoreman-20261124-1230.zip');
  });
}

/// バックアップ画面テスト用のダミー SongDatabaseService。
class FakeSongDatabaseServiceForTest extends SongDatabaseService {
  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async => throw UnimplementedError();

  @override
  Future<Uint8List?> readAdditionalJsonBytes() async => null;

  @override
  Future<void> writeAdditionalJsonBytes(Uint8List bytes) async {
    // フェイク：何もしない。
  }

  @override
  Future<String> loadDistributionUrl() async => throw UnimplementedError();

  @override
  Future<void> saveDistributionUrl(String url) async => throw UnimplementedError();

  @override
  Future<SongDatabaseStatus> loadStatus() async => throw UnimplementedError();

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async =>
      throw UnimplementedError();

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async =>
      throw UnimplementedError();
}
