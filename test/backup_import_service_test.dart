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
import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/data/memo_template_repository.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/platform/io_blob_store.dart';

void main() {
  late Directory tempDirA;
  late Directory tempDirB;
  late FilePlayRecordRepository repoA;
  late FilePlayRecordRepository repoB;

  setUp(() async {
    tempDirA = await Directory.systemTemp.createTemp('scoreyomipm_exp_');
    tempDirB = await Directory.systemTemp.createTemp('scoreyomipm_imp_');
    repoA = FilePlayRecordRepository(
      blobStore: IoBlobStore(tempDirA),
    );
    repoB = FilePlayRecordRepository(
      blobStore: IoBlobStore(tempDirB),
    );
  });

  tearDown(() async {
    for (final Directory dir in <Directory>[tempDirA, tempDirB]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  /// 画像付きレコードに持たせる JPEG もどきのバイト列（先頭は JPEG の SOI）。
  /// WHY 実ファイルを作らないか: 保存先はリポジトリの BlobStore に閉じており、
  /// create() はバイト列を直接受け取る。テストが端末のディスクに依存すると、
  /// Web 実装に切り替えたときに同じテストが動かなくなる。
  final Uint8List sourceImageBytes = Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    0xFF,
    42,
  ]);

  BackupImportService buildService(FilePlayRecordRepository repository) {
    return BackupImportService(
      listRecords: repository.listAll,
      writer: repository,
    );
  }

  /// 端末 A のレコード 2 件（うち 1 件は画像付き）から ZIP を作る。
  Future<Uint8List> buildZipFromA() async {
    final PlayRecord withImage = await repoA.create(
      const PlayRecordDraft(
        songName: '画像あり',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      sourceImageBytes,
    );
    await repoA.create(
      const PlayRecordDraft(
        songName: '画像なし',
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      ),
      null,
    );
    // WHY ファイル名だけを検証するか: 実体の置き場所は保存先（端末のディスク /
    // ブラウザの IndexedDB）ごとに違うので、レコードには basename だけを持つ。
    expect(withImage.resultImagePath, '${withImage.id}.jpg');
    expect(
      await repoA.readImage(withImage.resultImagePath),
      equals(sourceImageBytes),
    );

    return BackupExportService(
      repository: repoA,
      appVersion: '1.4.0+6',
    ).buildZip();
  }

  test('プレビューは件数・画像数を返し、書き込みを行わない', () async {
    final Uint8List zip = await buildZipFromA();
    final BackupArchiveCodec codec = const BackupArchiveCodec();
    final BackupArchive archive = codec.decode(zip);
    // WHY: 旧実装は File(record.resultImagePath) で原画像を探していたため、
    // パスが basename になると ZIP に画像が 1 枚も入らなかった。プレビュー
    // 以前の段階で ZIP 自体に画像が入っていることを押さえる。
    expect(archive.imagesById, hasLength(1));

    final BlobStore storeB = IoBlobStore(tempDirB);
    final Uint8List? beforeBytes = await storeB.read('records/records.json');
    final int recordsFileSizeBefore = beforeBytes?.length ?? 0;

    final BackupImportPreview preview = await buildService(repoB).preview(zip);

    expect(preview.recordCount, 2);
    expect(preview.imageCount, 1);
    expect(preview.duplicateCount, 0);
    expect(preview.manifest.appVersion, '1.4.0+6');
    final Uint8List? afterBytes = await storeB.read('records/records.json');
    expect(afterBytes?.length ?? 0, recordsFileSizeBefore);
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

    final BlobStore storeB = IoBlobStore(tempDirB);
    final List<PlayRecord> all = await repoB.listAll();
    expect(all, hasLength(2));
    expect(
      all.where((PlayRecord r) => r.resultImagePath.isNotEmpty),
      hasLength(1),
    );

    // WHY: importAll は新 ID を発行するため、resultImagePath で特定のレコードを
    // 特定できない。代わりに imagesRestored カウンタと blobStore の中身を検証する。
    expect(outcome.imagesRestored, 1);
    expect(outcome.missingImages, 0);

    // 画像が blobStore に保存されていることを確認。
    final imageKeys = await storeB.listKeys('records/images/');
    expect(imageKeys, isNotEmpty);
    expect(await storeB.read(imageKeys.first), equals(sourceImageBytes));
  });

  test('壊れた ZIP は例外で止まり、1 件も書き込まない', () async {
    final Uint8List broken = Uint8List.fromList(<int>[0, 1, 2, 3]);

    await expectLater(
      buildService(repoB).apply(broken, mode: ImportMode.replace),
      throwsA(isA<BackupFormatException>()),
    );

    final BlobStore storeB = IoBlobStore(tempDirB);
    expect(await repoB.listAll(), isEmpty);
    expect(await storeB.read('records/records.json'), isNull);
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

  group('メモのテンプレート', () {
    late FileMemoTemplateRepository templatesA;
    late FileMemoTemplateRepository templatesB;

    setUp(() {
      templatesA = FileMemoTemplateRepository(
        documentsDirectoryResolver: () async => tempDirA,
      );
      templatesB = FileMemoTemplateRepository(
        documentsDirectoryResolver: () async => tempDirB,
      );
    });

    BackupImportService buildServiceWithTemplates(
      FilePlayRecordRepository repository, {
      MemoTemplateRepository? templates,
    }) {
      return BackupImportService(
        listRecords: repository.listAll,
        writer: repository,
        memoTemplateRepository: templates ?? templatesB,
      );
    }

    /// 端末 A のテンプレート 2 件を含む ZIP を作る（レコードは 2 件）。
    Future<Uint8List> buildZipWithTemplates() async {
      await buildZipFromA(); // 端末 A にレコードを用意する。
      await templatesA.add(title: '要復習', body: '要復習です');
      await templatesA.add(title: '精度重視', body: '精度重視で');

      return BackupExportService(
        repository: repoA,
        appVersion: '1.4.0+6',
        memoTemplateRepository: templatesA,
      ).buildZip();
    }

    test('ZIP に同梱され、プレビューと復元結果に件数が出る', () async {
      final Uint8List zip = await buildZipWithTemplates();

      final BackupImportPreview preview = await buildServiceWithTemplates(repoB)
          .preview(zip);
      final BackupImportOutcome outcome = await buildServiceWithTemplates(repoB)
          .apply(zip, mode: ImportMode.merge);

      expect(preview.templateCount, 2);
      expect(preview.manifest.templateCount, 2);
      expect(outcome.templatesImported, 2);

      final List<MemoTemplate> restored = await templatesB.listAll();

      expect(restored.map((MemoTemplate t) => t.title), <String>[
        '要復習',
        '精度重視',
      ]);
      expect(restored.first.body, '要復習です');
    });

    test('復元は追加のみで、2 回当てても増えない', () async {
      final Uint8List zip = await buildZipWithTemplates();
      await templatesB.add(title: '端末 B の既存', body: '消えては困る');

      final BackupImportOutcome first = await buildServiceWithTemplates(repoB)
          .apply(zip, mode: ImportMode.merge);
      final BackupImportOutcome second = await buildServiceWithTemplates(repoB)
          .apply(zip, mode: ImportMode.merge);

      expect(first.templatesImported, 2);
      expect(second.templatesImported, 0);

      final List<MemoTemplate> all = await templatesB.listAll();

      expect(all.length, 3);
      expect(all.map((MemoTemplate t) => t.title), contains('端末 B の既存'));
    });

    test('全置換でもテンプレートは消さない（追加のみ）', () async {
      // WHY: テンプレートは「ZIP に無い版がある」うえ、記録の全置換に
      // つられて消えると手元のプリセットが黙って失われる。
      final Uint8List zip = await buildZipWithTemplates();
      await templatesB.add(title: '端末 B の既存', body: '消えては困る');

      await buildServiceWithTemplates(repoB)
          .apply(zip, mode: ImportMode.replace);

      final List<MemoTemplate> all = await templatesB.listAll();

      expect(all.length, 3);
      expect(all.map((MemoTemplate t) => t.title), contains('端末 B の既存'));
    });

    test('テンプレートを持たない旧 ZIP でもレコードは復元できる', () async {
      final Uint8List zip = await buildZipFromA();

      final BackupImportOutcome outcome = await buildServiceWithTemplates(repoB)
          .apply(zip, mode: ImportMode.merge);

      expect(outcome.imported, 2);
      expect(outcome.templatesImported, 0);
      expect(await templatesB.listAll(), isEmpty);
    });

    test('テンプレートの復元に失敗してもレコードは復元済みのまま返る', () async {
      // WHY: 記録の復元は既に成功している。テンプレートだけの失敗で
      // 例外を投げると「何も復元できなかった」と誤解される。
      final Uint8List zip = await buildZipWithTemplates();
      final BackupImportService service = buildServiceWithTemplates(
        repoB,
        templates: _ThrowingMemoTemplateRepository(),
      );

      final BackupImportOutcome outcome = await service.apply(
        zip,
        mode: ImportMode.merge,
      );

      expect(outcome.imported, 2);
      expect(outcome.templatesImported, 0);
      expect((await repoB.listAll()).length, 2);
    });

    test('テンプレートの復元先が未設定なら何もしない', () async {
      final Uint8List zip = await buildZipWithTemplates();
      final BackupImportService service = BackupImportService(
        listRecords: repoB.listAll,
        writer: repoB,
      );

      final BackupImportOutcome outcome = await service.apply(
        zip,
        mode: ImportMode.merge,
      );

      expect(outcome.imported, 2);
      expect(outcome.templatesImported, 0);
      expect(await templatesB.listAll(), isEmpty);
    });
  });
}

/// 復元失敗時の縮退を確かめるための、必ず例外を投げる repository。
class _ThrowingMemoTemplateRepository implements MemoTemplateRepository {
  @override
  Future<List<MemoTemplate>> listAll() async =>
      throw const FileSystemException('読めない');

  @override
  Future<MemoTemplate> add({
    required String title,
    required String body,
  }) async => throw const FileSystemException('書けない');

  @override
  Future<MemoTemplate> update(MemoTemplate template) async =>
      throw const FileSystemException('書けない');

  @override
  Future<void> delete(String id) async =>
      throw const FileSystemException('書けない');

  @override
  Future<int> mergeAll(List<MemoTemplate> templates) async =>
      throw const FileSystemException('書けない');
}
