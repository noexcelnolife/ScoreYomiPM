// 一括取り込み（PlayRecordBulkWriter）のホストテスト（タスク 01a20bfe・データ層）。
//
// WHY: 復元は「全置換」と「マージ」で既存データの扱いが真逆になるため、
// 実ファイル（records.json と images/）を一時ディレクトリに作って検証する。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_bulk_writer.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';

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
  late Directory tempDir;
  late FilePlayRecordRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scoreyomipm_bulk_');
    repository = FilePlayRecordRepository(
      documentsDirectoryResolver: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Directory imagesDir() => Directory('${tempDir.path}/records/images');

  File writeSourceImage(String name, List<int> bytes) {
    final File file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  test('マージは既存レコードを残し、同じ id はスキップする', () async {
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
    final PlayRecord existing = await repository.create(
      const PlayRecordDraft(
        songName: '既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      existingImage,
    );

    final BulkImportResult result = await repository.importAll(<PlayRecord>[
      buildRecord(existing.id),
      buildRecord('new-1'),
    ], replaceAll: false);

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
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
    await repository.create(
      const PlayRecordDraft(
        songName: '既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      existingImage,
    );
    expect(imagesDir().listSync(), isNotEmpty);

    final BulkImportResult result = await repository.importAll(<PlayRecord>[
      buildRecord('new-1'),
    ], replaceAll: true);

    final List<PlayRecord> all = await repository.listAll();

    expect(result.imported, 1);
    expect(result.skipped, 0);
    expect(all.map((PlayRecord r) => r.id), <String>['new-1']);
    // WHY: 全置換後に旧画像が残ると、レコードから参照されない孤児ファイルが増える。
    expect(
      imagesDir().existsSync() ? imagesDir().listSync() : <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('全置換で書き込みが失敗したら旧画像と旧 records.json が残る', () async {
    // WHY: 旧画像を先に消すと、書き込み失敗時に「旧 records.json は残るが
    // 参照先の画像は全部消えている」状態になる。失敗時は旧データがそのまま
    // 使えることを保証する。
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
    final PlayRecord existing = await repository.create(
      const PlayRecordDraft(
        songName: '既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      existingImage,
    );
    final File oldImageFile = File(existing.resultImagePath);
    final File recordsFile = File('${tempDir.path}/records/records.json');
    final String oldRecordsJson = recordsFile.readAsStringSync();

    // WHY: _writeAll は records.json.tmp に書いてから rename する。そのパスに
    // ディレクトリを置くと、本番コードに失敗注入用の seam を足さずに
    // 「画像複製は成功したが records.json の書き込みだけ失敗」を作れる。
    final Directory blocker = Directory('${recordsFile.path}.tmp')
      ..createSync(recursive: true);

    final File newImage = writeSourceImage('new.jpg', <int>[7, 7, 7]);

    await expectLater(
      repository.importAll(<PlayRecord>[
        buildRecord('new-1', resultImagePath: newImage.path),
      ], replaceAll: true),
      throwsA(isA<FileSystemException>()),
    );

    expect(oldImageFile.existsSync(), isTrue);
    expect(recordsFile.readAsStringSync(), oldRecordsJson);
    expect((await repository.listAll()).single.id, existing.id);

    await blocker.delete(recursive: true);
  });

  test('全置換の成功後は旧画像だけが消え、新しい画像は残る', () async {
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
    final PlayRecord existing = await repository.create(
      const PlayRecordDraft(
        songName: '既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      existingImage,
    );
    final String oldFileName = existing.resultImagePath
        .split(RegExp(r'[\\/]'))
        .last;
    final File newImage = writeSourceImage('new.jpg', <int>[7, 7, 7]);

    final BulkImportResult result = await repository.importAll(<PlayRecord>[
      buildRecord('new-1', resultImagePath: newImage.path),
    ], replaceAll: true);

    final PlayRecord saved = (await repository.listAll()).single;

    expect(result.imported, 1);
    expect(File('${imagesDir().path}/$oldFileName').existsSync(), isFalse);
    expect(File(saved.resultImagePath).existsSync(), isTrue);
    expect(
      imagesDir().listSync().whereType<File>().map(
        (File f) => f.path.split(RegExp(r'[\\/]')).last,
      ),
      <String>['new-1.jpg'],
    );
  });

  test('マージでは既存画像が消えない', () async {
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
    final PlayRecord existing = await repository.create(
      const PlayRecordDraft(
        songName: '既存曲',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      existingImage,
    );
    final File oldImageFile = File(existing.resultImagePath);

    await repository.importAll(<PlayRecord>[
      buildRecord('new-1'),
    ], replaceAll: false);

    expect(oldImageFile.existsSync(), isTrue);
    expect((await repository.listAll()).length, 2);
  });

  test('元画像が実在すれば images/<id>.<ext> に複製し、絶対パスへ差し替える', () async {
    final File source = writeSourceImage('src.jpg', <int>[9, 8, 7]);

    final BulkImportResult result = await repository.importAll(<PlayRecord>[
      buildRecord('r1', resultImagePath: source.path),
    ], replaceAll: false);

    final PlayRecord saved = (await repository.listAll()).single;
    final File copied = File(saved.resultImagePath);

    expect(result.missingImages, 0);
    expect(saved.resultImagePath, contains('images'));
    expect(saved.resultImagePath, endsWith('r1.jpg'));
    expect(copied.existsSync(), isTrue);
    expect(
      copied.readAsBytesSync(),
      equals(Uint8List.fromList(<int>[9, 8, 7])),
    );
  });

  test('元画像が実在しなければ missingImages に数え、パスを空にする', () async {
    final BulkImportResult result = await repository.importAll(<PlayRecord>[
      buildRecord('r1', resultImagePath: '${tempDir.path}/no-such.jpg'),
    ], replaceAll: false);

    final PlayRecord saved = (await repository.listAll()).single;

    expect(result.missingImages, 1);
    expect(saved.resultImagePath, '');
  });

  test('0 件の全置換は全消去として成立する', () async {
    final File existingImage = writeSourceImage('old.jpg', <int>[1, 1, 1]);
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
}
