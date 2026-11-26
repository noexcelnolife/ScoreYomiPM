// 記録詳細画面の「アプリ外に保存」ボタン（タスク 01a2106d）のテスト。
//
// 検証対象:
// (1) 原画像あり → ボタンを出し、タップで bytes / 保存名 / MIME が gateway へ渡る
// (2) 原画像なし（空パス） → ボタンを出さない（画像プレビューと同じ条件）
// (3) 保存ダイアログのキャンセル（戻り値 null） → SnackBar を出さない（無言）
// (4) 原画像ファイル欠落 → 「画像が見つかりません」SnackBar・保存しない
// (5) ボタンがプレビュー枠の中央に配置される（右揃えからの変更・01a21087）
//
// WHY(fake 注入): 保存ダイアログはプラットフォームチャネルを使うため widget
// テストから直接呼べない。FileExportGateway を差し替えて、画面が渡す引数と
// 戻り値の扱いだけを検証する（DIP・01a20c14 と同じ方針）。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ui/file_export_gateway.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// [FileExportGateway.saveBytes] に渡された引数の記録。
class _SaveCall {
  _SaveCall({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

/// 保存ダイアログの代わりに呼び出しを記録する fake。
///
/// [savedPath] が null なら「ユーザーがキャンセルした」ことを表す。
class _FakeFileExportGateway implements FileExportGateway {
  _FakeFileExportGateway({this.savedPath = '/sdcard/Download/exported.png'});

  final String? savedPath;
  final List<_SaveCall> calls = <_SaveCall>[];

  @override
  Future<XFile?> pickZip() async => null;

  @override
  Future<String?> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    calls.add(_SaveCall(bytes: bytes, fileName: fileName, mimeType: mimeType));
    return savedPath;
  }
}

/// 詳細画面に表示するレコードを 1 件作る。
PlayRecord _record({
  required String id,
  required String imagePath,
  String? songName,
}) {
  return PlayRecordDraft(
    songName: songName,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(
    id: id,
    resultImagePath: imagePath,
    playedAt: DateTime(2026, 11, 24, 10, 30),
  );
}

/// ルート画面から詳細を push する（route() の引数透過もここで通す）。
Future<void> _pumpDetail(
  WidgetTester tester, {
  required PlayRecord record,
  required FileExportGateway gateway,
}) async {
  final FakePlayRecordRepository repository = FakePlayRecordRepository()
    ..store[record.id] = record;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            PlayRecordDetailScreen.route(
              playRecordRepository: repository,
              ocrEngine: FakeOcrEngine(),
              recordId: record.id,
              fileExportGateway: gateway,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 実ファイル I/O の完了を待つ。
///
/// WHY: 原画像の existence チェックと読み込みは本物の dart:io なので、
/// widget テストの fake async では進まない。実時間を少しずつ進めながら
/// pump する（backup_screen_test の _pumpThroughRealIo と同じ手法）。
Future<void> _pumpThroughRealIo(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('(1) 画像あり: ボタンが出て、タップで bytes・保存名・MIME が渡る', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final _FakeFileExportGateway gateway = _FakeFileExportGateway();

    await _pumpDetail(
      tester,
      record: _record(id: 'r-1', imagePath: image.path, songName: 'テスト曲'),
      gateway: gateway,
    );

    final Finder button = find.byKey(
      const ValueKey<String>('export-image-button'),
    );
    expect(button, findsOneWidget);
    expect(find.text('アプリ外に保存'), findsOneWidget);

    await tester.tap(button);
    await _pumpThroughRealIo(tester);

    expect(gateway.calls, hasLength(1));
    final _SaveCall call = gateway.calls.single;
    expect(call.bytes, equals(image.readAsBytesSync()), reason: '原画像そのものを渡す');
    // 曲名あり: scoreyomipm_<曲名>_<yyyyMMdd>.<ext>（日付は実行日）
    expect(call.fileName, matches(RegExp(r'^scoreyomipm_テスト曲_\d{8}\.png$')));
    expect(call.mimeType, 'image/png');
    expect(find.text('保存しました'), findsOneWidget);
  });

  testWidgets('(2) 画像なし: ボタンを出さない', (WidgetTester tester) async {
    await _pumpDetail(
      tester,
      record: _record(id: 'r-2', imagePath: '', songName: 'テスト曲'),
      gateway: _FakeFileExportGateway(),
    );

    expect(
      find.byKey(const ValueKey<String>('export-image-button')),
      findsNothing,
    );
    expect(find.text('アプリ外に保存'), findsNothing);
  });

  testWidgets('(3) キャンセル: SnackBar を出さない', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final _FakeFileExportGateway gateway = _FakeFileExportGateway(
      savedPath: null,
    );

    await _pumpDetail(
      tester,
      record: _record(id: 'r-3', imagePath: image.path, songName: 'テスト曲'),
      gateway: gateway,
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-image-button')));
    await _pumpThroughRealIo(tester);

    expect(gateway.calls, hasLength(1), reason: '保存ダイアログまでは進む');
    expect(find.byType(SnackBar), findsNothing, reason: 'キャンセルは無言');
    expect(find.text('保存しました'), findsNothing);
  });

  testWidgets('(4) ファイル欠落: 「画像が見つかりません」を出し、保存しない', (WidgetTester tester) async {
    final File missing = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'scoreyomipm-missing-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    final _FakeFileExportGateway gateway = _FakeFileExportGateway();

    await _pumpDetail(
      tester,
      record: _record(id: 'r-4', imagePath: missing.path, songName: 'テスト曲'),
      gateway: gateway,
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-image-button')));
    await _pumpThroughRealIo(tester);

    expect(gateway.calls, isEmpty, reason: '読めない画像は渡さない');
    expect(find.text('画像が見つかりません'), findsOneWidget);
  });

  testWidgets('(5) ボタンはプレビュー枠の中央に配置される', (WidgetTester tester) async {
    // WHY(中央揃え): ユーザー指示で右揃えから中央揃えに変更した（01a21087）。
    // プレビュー枠は横幅いっぱい（width: double.infinity）なので、枠の中心 x と
    // ボタンの中心 x が一致すれば「中央」と言える。
    final File image = createTestImageFile();
    await _pumpDetail(
      tester,
      record: _record(id: 'r-5', imagePath: image.path, songName: 'テスト曲'),
      gateway: _FakeFileExportGateway(),
    );

    final Rect preview = tester.getRect(find.byType(InteractiveViewer));
    final Rect button = tester.getRect(
      find.byKey(const ValueKey<String>('export-image-button')),
    );
    expect(
      button.center.dx,
      moreOrLessEquals(preview.center.dx, epsilon: 0.5),
      reason: '右揃え（Align.centerRight）だと中央からボタン半分ぶん右にずれる',
    );
  });
}
