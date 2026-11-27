// 検証対象: v1.0.3 の端末に保存済みのデータを、Web 対応後もそのまま読めること。
//
// WHY(このテストが必要か): 保存先の配置と resultImagePath の意味は、BlobStore を
// 挟んでも変えてはいけない。ここが壊れても例外は出ず、「画像だけが消える」
// 「記録が 0 件になる」という形で静かに壊れる。更新した既存ユーザーが最初に
// 踏むのがこの経路なので、実装より先に仕様として固定する。
//
//  - 読み込みは <documents>/records/records.json（従来と同じ場所）
//  - resultImagePath が絶対パスでも basename として解決する（移行読み込み）
//  - 日本語は UTF-8 で往復する（UTF-16 の切り詰めで壊れない）

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';
import 'package:scoreyomipm/platform/io_blob_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scoreyomipm-compat-');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  /// v1.0.3 と同じ場所に records.json を置く。
  Future<void> writeLegacyRecords(List<Map<String, Object?>> records) async {
    final File file = File('${root.path}/records/records.json');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(utf8.encode(jsonEncode(records)));
  }

  Future<void> writeLegacyImage(String name, List<int> bytes) async {
    final File file = File('${root.path}/records/images/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  FilePlayRecordRepository buildRepository() {
    return FilePlayRecordRepository(blobStore: IoBlobStore(root));
  }

  test('絶対パスの resultImagePath は basename として解決し、画像も読める', () async {
    await writeLegacyRecords(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'r1',
        'playedAt': '2026-11-01T12:00:00.000',
        'songName': '春日影',
        'score': 1234567,
        'status': 'confirmed',
        'source': 'playshare',
        'resultImagePath': r'C:\Users\ka\AppData\Local\records\images\r1.jpg',
      },
      <String, Object?>{
        'id': 'r2',
        'playedAt': '2026-11-02T12:00:00.000',
        'songName': 'テスト曲',
        'status': 'confirmed',
        'source': 'playshare',
        'resultImagePath':
            '/data/user/0/jp.example.scoreyomipm/files/records/images/r2.jpg',
      },
    ]);
    await writeLegacyImage('r1.jpg', <int>[1, 2, 3]);
    await writeLegacyImage('r2.jpg', <int>[4, 5, 6]);

    final FilePlayRecordRepository repository = buildRepository();
    final List<PlayRecord> records = await repository.listAll();

    expect(records, hasLength(2));
    final PlayRecord first = records.firstWhere((PlayRecord r) => r.id == 'r1');
    final PlayRecord second = records.firstWhere((PlayRecord r) => r.id == 'r2');

    // レコードが持つのはファイル名だけ。絶対パスは保存にも表示にも使わない。
    expect(first.resultImagePath, 'r1.jpg');
    expect(second.resultImagePath, 'r2.jpg');
    expect(await repository.readImage(first.resultImagePath), <int>[1, 2, 3]);
    expect(await repository.readImage(second.resultImagePath), <int>[4, 5, 6]);
    // 日本語（3 バイト文字）が UTF-8 で往復している
    expect(first.songName, '春日影');
  });

  test('保存は v1.0.3 と同じ配置（records/records.json と records/images/）', () async {
    final FilePlayRecordRepository repository = buildRepository();
    final PlayRecord created = await repository.create(
      const PlayRecordDraft(
        songName: '配置テスト',
        status: PlayRecordStatus.confirmed,
        source: PlayRecordSource.playshare,
      ),
      Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    );

    expect(File('${root.path}/records/records.json').existsSync(), isTrue);
    // PNG 署名のバイト列なので拡張子は png になる
    expect(created.resultImagePath, '${created.id}.png');
    expect(
      File('${root.path}/records/images/${created.resultImagePath}').existsSync(),
      isTrue,
    );

    // WHY バイト列で確かめるか: codeUnits を書き込む実装だと、この時点で
    // 日本語が壊れて jsonDecode できない（または文字化けする）。
    final String raw = utf8.decode(
      File('${root.path}/records/records.json').readAsBytesSync(),
    );
    final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
    expect((decoded.single as Map<String, dynamic>)['songName'], '配置テスト');
  });

  test('画像が無い旧レコードでも一覧は壊れない', () async {
    await writeLegacyRecords(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'r3',
        'playedAt': '2026-11-03T12:00:00.000',
        'songName': '画像なし',
        'status': 'confirmed',
        'source': 'playshare',
        'resultImagePath': r'C:\gone\r3.jpg',
      },
    ]);

    final FilePlayRecordRepository repository = buildRepository();
    final List<PlayRecord> records = await repository.listAll();

    expect(records, hasLength(1));
    expect(records.single.resultImagePath, 'r3.jpg');
    // 実体が無ければ null。画面側はプレースホルダを出す。
    expect(await repository.readImage(records.single.resultImagePath), isNull);
  });
}
