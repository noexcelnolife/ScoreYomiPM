// FilePlayRecordRepository の単体テスト（一時ディレクトリで実ファイル I/O を検証）。
//
// FR-4 未確定レコード保存の永続化層。アトミック書き込み・破損退避・
// 値の正規化・原画像のバイト等価コピーを含む。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('play_record_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  FilePlayRecordRepository createRepository() {
    return FilePlayRecordRepository(
      documentsDirectoryResolver: () async => tempDir,
    );
  }

  File recordsFile() => File('${tempDir.path}/records/records.json');

  /// パスからファイル名部分を取り出す（Windows の区切りも処理）。
  String baseName(String path) => path.split(Platform.pathSeparator).last;
  File imageFileOf(PlayRecord record) => File(record.resultImagePath);

  /// テスト用の原画像ファイルを作る。
  File createSourceImage(String name) {
    final File file = File('${tempDir.path}/$name');
    file.writeAsBytesSync(<int>[1, 2, 3, 255, 128, 7]);
    return file;
  }

  /// 手入力相当の draft（全フィールドあり・confirmed）。
  PlayRecordDraft fullDraft({String? songName}) {
    return PlayRecordDraft(
      songName: songName ?? 'テスト楽曲',
      score: '98108',
      cool: 2345,
      great: 123,
      good: 10,
      bad: 5,
      maxCombo: 500,
      level: 38,
      status: PlayRecordStatus.confirmed,
      source: PlayRecordSource.playshare,
    );
  }

  group('create', () {
    test('id・画像コピー・JSON 追加が行われる', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.png');

      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      expect(record.id, isNotEmpty);
      expect(record.songName, 'テスト楽曲');
      expect(record.score, 98108);
      expect(record.level, 38);
      expect(record.status, PlayRecordStatus.confirmed);
      expect(record.resultImagePath, isNotEmpty);
      expect(await imageFileOf(record).exists(), isTrue);
      expect(
        await imageFileOf(record).readAsBytes(),
        await sourceImage.readAsBytes(),
      );
      expect(await repository.listAll(), hasLength(1));
      expect(await recordsFile().exists(), isTrue);
    });

    test('png 元画像は .png で保存される', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.png');

      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      expect(record.resultImagePath, endsWith('.png'));
    });

    test('連続 create で id が重複しない', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');

      final PlayRecord first = await repository.create(
        fullDraft(),
        sourceImage,
      );
      final PlayRecord second = await repository.create(
        fullDraft(songName: '別の曲'),
        sourceImage,
      );

      expect(first.id, isNot(second.id));
      expect(await repository.listAll(), hasLength(2));
    });

    test('元画像が存在しない場合は例外でレコード未作成', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File missing = File('${tempDir.path}/missing.png');

      await expectLater(
        repository.create(fullDraft(), missing),
        throwsA(isA<FileSystemException>()),
      );
      expect(await repository.listAll(), isEmpty);
    });

    test('原画像のみの draft（OCR 失敗フォールバック相当）を pending で保存', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecordDraft draft = PlayRecordDraft(
        songName: null,
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      );

      final PlayRecord record = await repository.create(draft, sourceImage);

      expect(record.status, PlayRecordStatus.pending);
      expect(record.songName, isNull);
      expect(record.score, isNull);
      expect(await imageFileOf(record).exists(), isTrue);
    });
  });

  group('参照', () {
    test('新規ディレクトリでは空リストを返す', () async {
      final FilePlayRecordRepository repository = createRepository();
      expect(await repository.listAll(), isEmpty);
    });

    test('findById は存在すれば返し、なければ null', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      expect((await repository.findById(record.id))?.id, record.id);
      expect(await repository.findById('no-such-id'), isNull);
    });
  });

  group('update', () {
    test('ドラフト値で全上書きされ、システム管理フィールドは維持される', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        PlayRecordDraft(
          songName: null,
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
        sourceImage,
      );
      final String originalImagePath = record.resultImagePath;
      final DateTime originalPlayedAt = record.playedAt;

      await repository.update(
        record.id,
        PlayRecordDraft(
          songName: '補完した曲名',
          score: 90000,
          status: PlayRecordStatus.confirmed,
          source: PlayRecordSource.playshare,
        ),
      );

      final PlayRecord reloaded = (await repository.findById(record.id))!;
      expect(reloaded.songName, '補完した曲名');
      expect(reloaded.score, 90000);
      expect(reloaded.status, PlayRecordStatus.confirmed);
      expect(reloaded.resultImagePath, originalImagePath, reason: '画像パスは維持');
      expect(reloaded.playedAt, originalPlayedAt, reason: '記録日時は維持');
      expect(await repository.listAll(), hasLength(1));
    });

    test('メモはドラフト値で上書きされ、空にすれば null に戻る', () async {
      final FilePlayRecordRepository repository = createRepository();
      final PlayRecord record = await repository.create(
        PlayRecordDraft(
          songName: 'メモ曲',
          memo: '旧メモ',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
        createSourceImage('result.jpg'),
      );

      await repository.update(
        record.id,
        PlayRecordDraft(
          songName: 'メモ曲',
          memo: '新メモ',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
      );
      expect((await repository.findById(record.id))!.memo, '新メモ');

      // WHY: 修正画面でメモ欄を空にしたら消えるのが期待挙動（曲名と同じ規則）。
      await repository.update(
        record.id,
        PlayRecordDraft(
          songName: 'メモ曲',
          memo: '',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
      );
      expect((await repository.findById(record.id))!.memo, isNull);
    });

    test('曲名を空にして保存すると songName は null に戻る', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      await repository.update(
        record.id,
        PlayRecordDraft(
          songName: '   ',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
      );

      final PlayRecord reloaded = (await repository.findById(record.id))!;
      expect(reloaded.songName, isNull);
      expect(reloaded.score, isNull, reason: '全上書きで他フィールドも消える');
    });

    test('未知の id は例外', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      await expectLater(
        repository.update('no-such-id', fullDraft()),
        throwsA(isA<StateError>()),
      );
      expect(
        (await repository.findById(record.id))?.score,
        98108,
        reason: '無損',
      );
    });
  });

  group('delete', () {
    test('レコードと原画像の両方を削除する', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      await repository.delete(record.id);

      expect(await repository.listAll(), isEmpty);
      expect(await imageFileOf(record).exists(), isFalse);
    });

    test('存在しない id は無音で成功（冪等）', () async {
      final FilePlayRecordRepository repository = createRepository();
      await repository.delete('no-such-id');
      expect(await repository.listAll(), isEmpty);
    });
  });

  group('書き込み耐障害', () {
    test('書き込み後は .tmp 残骸がなく records.json が完成している', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      await repository.create(fullDraft(), sourceImage);
      await repository.create(fullDraft(songName: '2曲目'), sourceImage);

      expect(await recordsFile().exists(), isTrue);
      final Directory recordsDir = recordsFile().parent;
      final List<String> names = recordsDir
          .listSync()
          .map((e) => baseName(e.path))
          .toList();
      expect(
        names.where((name) => name.endsWith('.tmp')),
        isEmpty,
        reason: 'アトミック置換後の tmp 残骸はあってはならない',
      );
      final dynamic saved = jsonDecode(await recordsFile().readAsString());
      expect(saved, isList);
      expect((saved as List<dynamic>).length, 2);
    });

    test('破損 JSON → .corrupt.<ts> 退避・空リスト開始・原画像残置・次回保存で復帰', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord first = await repository.create(
        fullDraft(),
        sourceImage,
      );
      final String originalJson = await recordsFile().readAsString();

      // 意図的に破損させる。
      await recordsFile().writeAsString('{"broken": ');
      expect(await repository.listAll(), isEmpty);

      final Directory recordsDir = recordsFile().parent;
      final List<String> names = recordsDir
          .listSync()
          .map((e) => baseName(e.path))
          .toList();
      final String? corruptBackup = names
          .where((name) => name.startsWith('records.json.corrupt.'))
          .firstOrNull;
      expect(corruptBackup, isNotNull, reason: '破損ファイルが退避されていること');
      expect(
        await File('${recordsDir.path}/$corruptBackup').readAsString(),
        isNot(equals(originalJson)),
      );
      // 復旧用の中身が退避されているかはシグネチャで確認（破損直前のJSONとは別物）。
      expect(await File('${recordsDir.path}/$corruptBackup').exists(), isTrue);
      // 原画像は残置。
      expect(await imageFileOf(first).exists(), isTrue);
      // 次回保存で records.json が再作成され、運用が復帰する。
      final PlayRecord next = await repository.create(fullDraft(), sourceImage);
      expect(await repository.listAll(), hasLength(1));
      expect(next.id, isNot(first.id));
    });

    test('配列でないルート（オブジェクト）も破損退避する', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      await repository.create(fullDraft(), sourceImage);

      await recordsFile().writeAsString('{"songs": "not-records"}');
      expect(await repository.listAll(), isEmpty);

      final Directory recordsDir = recordsFile().parent;
      final List<String> names = recordsDir
          .listSync()
          .map((e) => baseName(e.path))
          .toList();
      expect(
        names.any((name) => name.startsWith('records.json.corrupt.')),
        isTrue,
      );
    });

    test('配列内の不正要素のみスキップし退避はしない', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      await repository.create(fullDraft(), sourceImage);

      final List<dynamic> raw =
          jsonDecode(await recordsFile().readAsString()) as List<dynamic>;
      raw.add('garbage-entry');
      await recordsFile().writeAsString(jsonEncode(raw));

      final List<PlayRecord> records = await repository.listAll();
      expect(records, hasLength(1));
      final Directory recordsDir = recordsFile().parent;
      final List<String> names = recordsDir
          .listSync()
          .map((e) => baseName(e.path))
          .toList();
      expect(
        names.any((name) => name.startsWith('records.json.corrupt.')),
        isFalse,
      );
    });
  });

  group('正規化', () {
    test('レンジ外・不正値は null に正規化される', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecordDraft draft = PlayRecordDraft(
        songName: '   ',
        score: '123456',
        cool: -1,
        great: 10,
        good: 'abc',
        bad: 3,
        maxCombo: 99999,
        level: '55',
        status: PlayRecordStatus.pending,
        source: PlayRecordSource.playshare,
      );

      final PlayRecord record = await repository.create(draft, sourceImage);

      expect(record.songName, isNull, reason: '空白のみの曲名は null');
      expect(record.score, isNull, reason: 'score 100000 超は null');
      expect(record.cool, isNull, reason: '負値は null');
      expect(record.good, isNull, reason: '数値でない文字列は null');
      expect(record.bad, 3);
      expect(record.maxCombo, 99999);
      expect(record.level, isNull, reason: 'level 50 超は null');
    });

    test('境界値は保存される（score 0/100000・level 1/50）', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecordDraft draft = PlayRecordDraft(
        songName: '境界曲',
        score: '100000',
        cool: 0,
        great: 0,
        good: 0,
        bad: 0,
        maxCombo: 0,
        level: '50',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      );

      final PlayRecord record = await repository.create(draft, sourceImage);

      expect(record.score, 100000);
      expect(record.level, 50);
      expect(record.cool, 0);
    });
  });

  group('JSON 往復', () {
    test('toJson→fromJson でフィールドが復元される', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        fullDraft(),
        sourceImage,
      );

      final PlayRecord restored = PlayRecord.fromJson(record.toJson());

      expect(restored.id, record.id);
      expect(restored.playedAt, record.playedAt);
      expect(restored.songName, record.songName);
      expect(restored.score, record.score);
      expect(restored.cool, record.cool);
      expect(restored.great, record.great);
      expect(restored.good, record.good);
      expect(restored.bad, record.bad);
      expect(restored.maxCombo, record.maxCombo);
      expect(restored.level, record.level);
      expect(restored.status, record.status);
      expect(restored.source, record.source);
      expect(restored.resultImagePath, record.resultImagePath);
    });

    test('メモは trim され、空文字は null として往復する', () async {
      final FilePlayRecordRepository repository = createRepository();
      final File sourceImage = createSourceImage('result.jpg');
      final PlayRecord record = await repository.create(
        PlayRecordDraft(
          songName: 'メモ曲',
          memo: '  精度重視\n',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
        sourceImage,
      );

      expect(record.memo, '精度重視');
      expect(PlayRecord.fromJson(record.toJson()).memo, '精度重視');

      final PlayRecord blank = await repository.create(
        PlayRecordDraft(
          songName: '空メモ曲',
          memo: '   ',
          status: PlayRecordStatus.pending,
          source: PlayRecordSource.playshare,
        ),
        createSourceImage('result2.jpg'),
      );
      expect(blank.memo, isNull, reason: '空白のみのメモは null');
    });

    test('メモを持たない旧 JSON は null として読める', () async {
      final PlayRecord restored = PlayRecord.fromJson(<String, dynamic>{
        'id': 'legacy-2',
        'playedAt': '2026-11-22T10:00:00Z',
        'resultImagePath': '/tmp/legacy.jpg',
      });

      expect(restored.memo, isNull);
    });

    test('欠落キー・未知キーでも復元できる（スキーマ進化許容）', () async {
      final Map<String, dynamic> legacyJson = <String, dynamic>{
        'id': 'legacy-1',
        'playedAt': '2026-11-22T10:00:00Z',
        'songName': 'レガシーキー',
        'resultImagePath': '/tmp/legacy.jpg',
        'unknownFutureField': 42,
      };

      final PlayRecord restored = PlayRecord.fromJson(legacyJson);

      expect(restored.id, 'legacy-1');
      expect(restored.songName, 'レガシーキー');
      expect(restored.score, isNull);
      expect(restored.status, PlayRecordStatus.pending);
      expect(restored.source, PlayRecordSource.playshare);
    });
  });
}
