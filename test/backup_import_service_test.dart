// バックアップ入出力サービスのホストテスト（タスク 01a20bfe・データ層）。
//
// WHY: 復元は「既存データを壊さない」ことが最優先のため、①プレビューが書き込ま
// ないこと ②同じ ZIP を 2 回当てても増えないこと ③壊れた ZIP では 1 件も書かな
// いこと を実ファイルで固定する。画像パスは端末ごとに異なるため、復元先の
// documents 配下へ張り直されることを確認する。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/backup/backup_archive_codec.dart';
import 'package:scoreyomipm/backup/backup_export_service.dart';
import 'package:scoreyomipm/backup/backup_import_service.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';

void main() {
  late Directory tempDirA;
  late Directory tempDirB;
  late FilePlayRecordRepository repoA;
  late FilePlayRecordRepository repoB;

  setUp(() async {
    tempDirA = await Directory.systemTemp.createTemp('scoreyomipm_exp_');
    tempDirB = await Directory.systemTemp.createTemp('scoreyomipm_imp_');
    repoA = FilePlayRecordRepository(
      documentsDirectoryResolver: () async => tempDirA,
    );
    repoB = FilePlayRecordRepository(
      documentsDirectoryResolver: () async => tempDirB,
    );
  });

  tearDown(() async {
    for (final Directory dir in <Directory>[tempDirA, tempDirB]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  File writeSourceImage(String name, List<int> bytes) {
    final File file = File('${tempDirA.path}/$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  BackupImportService buildService(FilePlayRecordRepository repository) {
    return BackupImportService(
      listRecords: repository.listAll,
      writer: repository,
    );
  }

  /// 端末 A のレコード 2 件（うち 1 件は画像付き）から ZIP を作る。
  Future<Uint8List> buildZipFromA() async {
    final File image = writeSourceImage('photo.jpg', <int>[
      0xFF,
      0xD8,
      0xFF,
      42,
    ]);
    final PlayRecord withImage = await repoA.create(
      const PlayRecordDraft(
        songName: '画像あり',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      image,
    );
    await repoA.create(
      const PlayRecordDraft(
        songName: '画像なし',
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      ),
      null,
    );
    expect(withImage.resultImagePath, isNotEmpty);

    return BackupExportService(
      repository: repoA,
      appVersion: '1.4.0+6',
    ).buildZip();
  }

  test('プレビューは件数・画像数・重複数を返し、1 件も書き込まない', () async {
    final Uint8List zip = await buildZipFromA();
    // 端末 B に 1 件だけ先に入れておき、その id を重複として数えさせる。
    final String duplicateId = (await repoA.listAll()).first.id;
    final BackupArchiveCodec codec = const BackupArchiveCodec();
    final BackupArchive archive = codec.decode(zip);

    await repoB.importAll(<PlayRecord>[
      archive.records.firstWhere((PlayRecord r) => r.id == duplicateId),
    ], replaceAll: false);
    final int recordsFileSizeBefore = File(
      '${tempDirB.path}/records/records.json',
    ).lengthSync();

    final BackupImportPreview preview = await buildService(repoB).preview(zip);

    expect(preview.recordCount, 2);
    expect(preview.imageCount, 1);
    expect(preview.duplicateCount, 1);
    expect(preview.manifest.appVersion, '1.4.0+6');
    expect(
      File('${tempDirB.path}/records/records.json').lengthSync(),
      recordsFileSizeBefore,
    );
  });

  test('マージは冪等（同じ ZIP を 2 回当てても件数が増えない）', () async {
    final Uint8List zip = await buildZipFromA();
    final BackupImportService service = buildService(repoB);

    final BackupImportOutcome first = await service.apply(
      zip,
      mode: ImportMode.merge,
    );
    final BackupImportOutcome second = await service.apply(
      zip,
      mode: ImportMode.merge,
    );

    expect(first.imported, 2);
    expect(first.skipped, 0);
    expect(second.imported, 0);
    expect(second.skipped, 2);
    expect((await repoB.listAll()).length, 2);
  });

  test('全置換は既存レコードを消して ZIP の内容だけにする', () async {
    final Uint8List zip = await buildZipFromA();
    await repoB.create(
      const PlayRecordDraft(
        songName: '端末 B の既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      null,
    );

    final BackupImportOutcome outcome = await buildService(repoB)
        .apply(zip, mode: ImportMode.replace);

    final List<PlayRecord> all = await repoB.listAll();

    expect(outcome.imported, 2);
    expect(outcome.skipped, 0);
    expect(all.map((PlayRecord r) => r.songName).toSet(), <String>{
      '画像あり',
      '画像なし',
    });
  });

  test('画像は復元先の documents 配下へ張り直され、バイト列が一致する', () async {
    final Uint8List zip = await buildZipFromA();

    final BackupImportOutcome outcome = await buildService(repoB)
        .apply(zip, mode: ImportMode.merge);

    final PlayRecord restored = (await repoB.listAll()).firstWhere(
      (PlayRecord r) => r.resultImagePath.isNotEmpty,
    );
    final File imageFile = File(restored.resultImagePath);

    // WHY: 端末 A の絶対パスをそのまま持ち込むと、復元先で画像が開けなくなる。
    expect(restored.resultImagePath, startsWith(tempDirB.path));
    expect(imageFile.existsSync(), isTrue);
    expect(
      imageFile.readAsBytesSync(),
      equals(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 42])),
    );
    expect(outcome.imagesRestored, 1);
    expect(outcome.missingImages, 0);
  });

  test('壊れた ZIP は例外で止まり、1 件も書き込まない', () async {
    final Uint8List broken = Uint8List.fromList(<int>[0, 1, 2, 3]);

    await expectLater(
      buildService(repoB).apply(broken, mode: ImportMode.replace),
      throwsA(isA<BackupFormatException>()),
    );

    expect(await repoB.listAll(), isEmpty);
    expect(File('${tempDirB.path}/records/records.json').existsSync(), isFalse);
  });

  test('CSV エクスポートは BOM 付きでヘッダから始まる', () async {
    await buildZipFromA();

    final String csv = await BackupExportService(
      repository: repoA,
      appVersion: '1.4.0+6',
    ).buildCsv();

    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv, contains('実施日時,曲名,難易度,レベル,スコア,COOL,GREAT,GOOD,BAD,MAX COMBO'));
    expect(csv, contains('画像あり'));
    expect(csv, contains('画像なし'));
  });
}
