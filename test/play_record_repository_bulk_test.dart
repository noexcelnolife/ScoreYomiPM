// 一括取り込み（PlayRecordBulkWriter）のホストテスト（タスク 01a20bfe・データ層）。
//
// P2: BlobStore 経由で永続化。ファイルシステム I/O は行わず、
// MemoryBlobStore で代替する。全置換後の孤児画像削除も検証する。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_bulk_writer.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';
import 'package:scoreyomipm/platform/blob_store.dart';

PlayRecord buildRecord(String id, {String resultImagePath = ''}) {
  return PlayRecord(
    id: id,
    playedAt: DateTime(2026, 11, 23, 21, 5),
    songName: '曲-$id',
    score: 98108,
    cool: 975,
    great: 58,
    good: 2,
    bad: 1,
    maxCombo: 733,
    level: 44,
    clearMedal: 'フルコンボ',
    difficulty: GameDifficulty.hyper,
    machine: 'H☆C!!',
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
    resultImagePath: resultImagePath,
  );
}

void main() {
  MemoryBlobStore createBlobStore() => MemoryBlobStore();

  /// 直近に作った保存先。`records/images/` という内部キーまで検証したい
  /// テストで参照する（レコードには basename しか出さないため）。
  late MemoryBlobStore lastBlobStore;

  FilePlayRecordRepository createRepository() {
    lastBlobStore = createBlobStore();
    return FilePlayRecordRepository(blobStore: lastBlobStore);
  }

  /// テスト用の原画像バイト列を作る。
  Uint8List sourceImageBytes([List<int>? bytes]) {
    return Uint8List.fromList(bytes ?? <int>[1, 1, 1]);
  }

  setUp(() {});

    test('マージは既存レコードを残し、同じ id はスキップする', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List existingImage = sourceImageBytes(<int>[1, 1, 1]);
      final PlayRecord existing = await repository.create(
        const PlayRecordDraft(
          songName: '既存曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
        existingImage,
      );

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[
          buildRecord(existing.id),
          buildRecord('new-1'),
        ],
        replaceAll: false,
        imageBytesById: <String, Uint8List?>{
          existing.id: existingImage,
          'new-1': sourceImageBytes(<int>[2, 2, 2]),
        },
      );

      final List<PlayRecord> all = await repository.listAll();

      expect(result.imported, 1);
      expect(result.skipped, 1);
      expect(result.missingImages, 0);
      expect(all.map((PlayRecord r) => r.id).toSet(), <String>{
        existing.id,
        'new-1',
      });
      expect(
        all.firstWhere((PlayRecord r) => r.id == existing.id).resultImagePath,
        isNotEmpty,
      );
    });

    test('全置換は既存レコードと既存画像を残さない', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List existingImage = sourceImageBytes(<int>[1, 1, 1]);
      final PlayRecord existing = await repository.create(
        const PlayRecordDraft(
          songName: '既存曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
        existingImage,
      );

      // 既存の画像は読める
      expect(await repository.readImage(existing.resultImagePath), existingImage);

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[buildRecord('new-1')],
        replaceAll: true,
        imageBytesById: <String, Uint8List?>{
          'new-1': sourceImageBytes(<int>[3, 3, 3]),
        },
      );

      final List<PlayRecord> all = await repository.listAll();

      expect(result.imported, 1);
      expect(result.skipped, 0);
      expect(all.map((PlayRecord r) => r.id), <String>['new-1']);
      // 既存画像は削除されている（読めない）
      expect(await repository.readImage(existing.resultImagePath), isNull);
    });

    test('画像は records/images/<id>.<ext> に保存し、レコードには basename を持つ', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List source = sourceImageBytes(<int>[9, 8, 7]);

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[buildRecord('r1', resultImagePath: 'whatever.jpg')],
        replaceAll: false,
        imageBytesById: <String, Uint8List?>{'r1': source},
      );

      final PlayRecord saved = (await repository.listAll()).single;

      expect(result.missingImages, 0);
      // レコードが持つのはファイル名だけ。置き場所は保存先の内部事情。
      expect(saved.resultImagePath, 'r1.jpg');
      expect(await lastBlobStore.exists('records/images/r1.jpg'), isTrue);
      // 保存された画像バイト列を読める
      final Uint8List? copied = await repository.readImage(saved.resultImagePath);
      expect(copied, source);
    });

    test('元画像バイト列がなければ missingImages に数え、パスを空にする', () async {
      final FilePlayRecordRepository repository = createRepository();

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[buildRecord('r1', resultImagePath: 'no-such.jpg')],
        replaceAll: false,
        imageBytesById: <String, Uint8List?>{}, // 画像バイト列なし
      );

      final PlayRecord saved = (await repository.listAll()).single;

      expect(result.missingImages, 1);
      expect(saved.resultImagePath, '');
    });

    test('0 件の全置換は全消去として成立する', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List existingImage = sourceImageBytes(<int>[1, 1, 1]);
      await repository.create(
        const PlayRecordDraft(
          songName: '既存曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
        existingImage,
      );

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[],
        replaceAll: true,
      );

      expect(result.imported, 0);
      expect(await repository.listAll(), isEmpty);
    });

    test('全置換の成功後は旧画像だけが消え、新しい画像は残る', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List existingImage = sourceImageBytes(<int>[1, 1, 1]);
      final PlayRecord existing = await repository.create(
        const PlayRecordDraft(
          songName: '既存曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
        existingImage,
      );

      final String oldKey = existing.resultImagePath;

      final BulkImportResult result = await repository.importAll(
        <PlayRecord>[buildRecord('new-1', resultImagePath: 'new.jpg')],
        replaceAll: true,
        imageBytesById: <String, Uint8List?>{
          'new-1': sourceImageBytes(<int>[7, 7, 7]),
        },
      );

      final PlayRecord saved = (await repository.listAll()).single;

      expect(result.imported, 1);
      // 旧キーは削除されている（読めない）
      expect(await repository.readImage(oldKey), isNull);
      // 新キーは読める
      final Uint8List? newBytes = await repository.readImage(saved.resultImagePath);
      expect(newBytes, sourceImageBytes(<int>[7, 7, 7]));
    });

    test('マージでは既存画像が消えない', () async {
      final FilePlayRecordRepository repository = createRepository();
      final Uint8List existingImage = sourceImageBytes(<int>[1, 1, 1]);
      final PlayRecord existing = await repository.create(
        const PlayRecordDraft(
          songName: '既存曲',
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
        existingImage,
      );

      final String existingKey = existing.resultImagePath;

      await repository.importAll(
        <PlayRecord>[buildRecord('new-1')],
        replaceAll: false,
        imageBytesById: <String, Uint8List?>{
          'new-1': sourceImageBytes(<int>[2, 2, 2]),
        },
      );

      // 旧画像はまだ読める
      expect(await repository.readImage(existingKey), existingImage);
      expect((await repository.listAll()).length, 2);
    });
  }
