// バックアップ ZIP コーデックのホストテスト（タスク 01a20bfe・データ層）。
//
// WHY: コーデックは IO を持たない純粋関数として設計するため、ZIP バイト列だけを
// 入力に往復（encode→decode）を検証できる。ここでは実ファイル・実端末に依存せず、
// 形式検証（format/schemaVersion）と画像欠落の扱い（警告して継続）を固定する。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/backup/backup_archive_codec.dart';
import 'package:scoreyomipm/backup/backup_manifest.dart';
import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/data/play_record.dart';

/// テスト用の最小レコード（画像なし）。
PlayRecord buildRecord({
  required String id,
  String? songName = 'テスト曲',
  String resultImagePath = '',
}) {
  return PlayRecord(
    id: id,
    playedAt: DateTime(2026, 11, 23, 21, 5),
    songName: songName,
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

BackupManifest buildManifest({
  int recordCount = 0,
  int imageCount = 0,
  int templateCount = 0,
}) {
  return BackupManifest(
    appVersion: '1.4.0+6',
    exportedAt: DateTime.utc(2026, 11, 23, 12),
    recordCount: recordCount,
    imageCount: imageCount,
    templateCount: templateCount,
  );
}

/// テスト用の最小テンプレート。
MemoTemplate buildTemplate({
  String id = 't1',
  String title = '要復習',
  String body = '要復習です',
}) {
  return MemoTemplate(id: id, title: title, body: body);
}

/// 生の ZIP を組み立てる（拒否系テスト用に任意の内容を流し込む）。
Uint8List buildRawZip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  for (final MapEntry<String, List<int>> entry in entries.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  final BackupArchiveCodec codec = BackupArchiveCodec();

  group('往復', () {
    test('0 件でも manifest と records.json だけで往復できる', () {
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(),
        records: <PlayRecord>[],
        imagesById: <String, Uint8List>{},
      );

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.manifest.recordCount, 0);
      expect(archive.records, isEmpty);
      expect(archive.imagesById, isEmpty);
      expect(archive.warnings, isEmpty);
    });

    test('画像付き 1 件は相対パスへ変換され、復号時に画像と共に戻る', () {
      // WHY: ZIP 内のパスは端末ごとに異なる絶対パスを含めない（別端末で復元する
      // ため）。ID から images/<id>.<ext> を組み立てる規則を固定する。
      final Uint8List image = Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        1,
        2,
        3,
      ]);
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(recordCount: 1, imageCount: 1),
        records: <PlayRecord>[
          buildRecord(id: 'r1', resultImagePath: 'D:/old/r1.jpg'),
        ],
        imagesById: <String, Uint8List>{'r1.jpg': image},
      );

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.manifest.recordCount, 1);
      expect(archive.manifest.imageCount, 1);
      expect(archive.records.single.resultImagePath, 'images/r1.jpg');
      expect(archive.imagesById['r1.jpg'], equals(image));
      expect(archive.warnings, isEmpty);
    });

    test('画像なしが混在していても往復できる', () {
      final Uint8List png = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        9,
      ]);
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(recordCount: 3, imageCount: 1),
        records: <PlayRecord>[
          buildRecord(id: 'r1', resultImagePath: 'D:/old/r1.png'),
          buildRecord(id: 'r2'),
          buildRecord(id: 'r3', songName: null),
        ],
        imagesById: <String, Uint8List>{'r1.png': png},
      );

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.records.length, 3);
      expect(archive.records[0].resultImagePath, 'images/r1.png');
      expect(archive.records[1].resultImagePath, '');
      expect(archive.records[2].resultImagePath, '');
      expect(archive.records[2].songName, isNull);
      expect(archive.imagesById.keys, <String>['r1.png']);
    });

    test('日本語曲名と引用符・カンマを含む曲名が往復する', () {
      // WHY: records.json は JSON なので CSV と違いエスケープは JSON 側が担うが、
      // 端末間で曲名が化けないことを実バイト列経由で確認する。
      const String tricky = '「テスト」, "quote" 曲';
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(recordCount: 1),
        records: <PlayRecord>[buildRecord(id: 'r1', songName: tricky)],
        imagesById: <String, Uint8List>{},
      );

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.records.single.songName, tricky);
    });

    test('画像は再圧縮せず格納される（サイズ・バイト列が一致する）', () {
      // WHY: JPEG/PNG は既に圧縮済みで、再圧縮は画質劣化と時間増の両面で損。
      // 格納（無圧縮）で入れることを ZIP エントリの方式で確認する。
      final Uint8List image = Uint8List.fromList(
        List<int>.generate(512, (int i) => i % 256),
      );
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(recordCount: 1, imageCount: 1),
        records: <PlayRecord>[buildRecord(id: 'r1')],
        imagesById: <String, Uint8List>{'r1.jpg': image},
      );

      final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final ArchiveFile entry = archive.findFile('images/r1.jpg')!;

      expect(entry.size, image.length);
      expect(entry.content, equals(image));
    });
  });

  group('拒否', () {
    test('format が異なる ZIP は BackupFormatException で拒否する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(
          jsonEncode(<String, dynamic>{
            'format': 'other.app',
            'schemaVersion': 1,
            'appVersion': '1.0.0',
            'exportedAt': '2026-11-23T12:00:00.000Z',
            'recordCount': 0,
            'imageCount': 0,
          }),
        ),
        'records.json': utf8.encode('[]'),
      });

      // WHY: 部分適用を防ぐため、検証は全読み込み前に行い例外で止める。
      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('schemaVersion が 2 の ZIP は拒否する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(
          jsonEncode(<String, dynamic>{
            'format': 'scoreyomipm.backup',
            'schemaVersion': 2,
            'appVersion': '9.9.9',
            'exportedAt': '2026-11-23T12:00:00.000Z',
            'recordCount': 0,
            'imageCount': 0,
          }),
        ),
        'records.json': utf8.encode('[]'),
      });

      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('manifest.json が無い ZIP は拒否する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'records.json': utf8.encode('[]'),
      });

      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('records.json が無い ZIP は拒否する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
      });

      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('records.json が JSON 配列でない場合は拒否する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
        'records.json': utf8.encode('{"records": []}'),
      });

      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('ZIP として壊れたバイト列は拒否する', () {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

      expect(() => codec.decode(bytes), throwsA(isA<BackupFormatException>()));
    });
  });

  group('画像欠落', () {
    test('参照先の画像が無い場合は警告に積み、そのレコードだけ画像なしで読む', () {
      // WHY: 画像 1 枚の欠落でバックアップ全体を復元不能にしない（裁定 D と同旨）。
      // 欠落は warnings に積み、レコードは画像なしとして継続する。
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(
          jsonEncode(buildManifest(recordCount: 2, imageCount: 2).toJson()),
        ),
        'records.json': utf8.encode(
          jsonEncode(<Map<String, dynamic>>[
            buildRecord(id: 'r1', resultImagePath: 'images/r1.jpg').toJson(),
            buildRecord(id: 'r2', resultImagePath: 'images/r2.jpg').toJson(),
          ]),
        ),
        // r2.jpg だけ実体がある（r1.jpg は欠落）。
        'images/r2.jpg': <int>[7, 8, 9],
      });

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.records.length, 2);
      expect(archive.records[0].resultImagePath, '');
      expect(archive.records[1].resultImagePath, 'images/r2.jpg');
      expect(archive.imagesById['r2.jpg'], equals(<int>[7, 8, 9]));
      expect(archive.warnings.length, 1);
      expect(archive.warnings.single, contains('r1.jpg'));
    });
  });

  group('メモのテンプレート', () {
    test('encode したテンプレートは decode で同じ内容に戻る', () {
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(templateCount: 2),
        records: <PlayRecord>[],
        imagesById: <String, Uint8List>{},
        templates: <MemoTemplate>[
          buildTemplate(id: 't1', title: '要復習', body: '要復習です'),
          buildTemplate(id: 't2', title: '精度重視', body: '精度重視で'),
        ],
      );

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.templates.map((MemoTemplate t) => t.id), <String>[
        't1',
        't2',
      ]);
      expect(archive.templates.first.title, '要復習');
      expect(archive.templates.last.body, '精度重視で');
      expect(archive.manifest.templateCount, 2);
      expect(archive.warnings, isEmpty);
    });

    test('テンプレート 0 件でも空配列として書き出し、警告なく読める', () {
      // WHY 空でも書くか: 「このバックアップにはテンプレートが無い」と
      // 「テンプレートという概念が無い版の ZIP」を区別できる。
      final Uint8List bytes = codec.encode(
        manifest: buildManifest(),
        records: <PlayRecord>[],
        imagesById: <String, Uint8List>{},
      );

      final Archive raw = ZipDecoder().decodeBytes(bytes);

      expect(raw.find('memo_templates.json'), isNotNull);
      expect(utf8.decode(raw.find('memo_templates.json')!.content), '[]');

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.templates, isEmpty);
      expect(archive.warnings, isEmpty);
      expect(archive.manifest.templateCount, 0);
    });

    test('memo_templates.json が無い旧 ZIP でもレコードは復元できる', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
        'records.json': utf8.encode(
          jsonEncode(<Map<String, dynamic>>[buildRecord(id: 'r1').toJson()]),
        ),
      });

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.records.single.id, 'r1');
      expect(archive.templates, isEmpty);
      expect(archive.warnings, isEmpty);
      expect(archive.manifest.templateCount, 0);
    });

    test('壊れた memo_templates.json は警告に積み、レコードは復元する', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
        'records.json': utf8.encode(
          jsonEncode(<Map<String, dynamic>>[buildRecord(id: 'r1').toJson()]),
        ),
        'memo_templates.json': utf8.encode('{壊れた'),
      });

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.records.single.id, 'r1');
      expect(archive.templates, isEmpty);
      expect(archive.warnings.single, contains('memo_templates.json'));
    });

    test('配列でない memo_templates.json は警告に積む', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
        'records.json': utf8.encode(jsonEncode(<Map<String, dynamic>>[])),
        'memo_templates.json': utf8.encode('{"templates": []}'),
      });

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.templates, isEmpty);
      expect(archive.warnings.single, contains('memo_templates.json'));
    });

    test('必須項目が欠けた 1 件だけを捨て、他は読む', () {
      final Uint8List bytes = buildRawZip(<String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(buildManifest().toJson())),
        'records.json': utf8.encode(jsonEncode(<Map<String, dynamic>>[])),
        'memo_templates.json': utf8.encode(
          jsonEncode(<Map<String, dynamic>>[
            <String, dynamic>{'id': 't1', 'title': '', 'body': '本文'},
            <String, dynamic>{'id': 't2', 'title': '名前', 'body': '本文'},
          ]),
        ),
      });

      final BackupArchive archive = codec.decode(bytes);

      expect(archive.templates.map((MemoTemplate t) => t.id), <String>['t2']);
    });
  });

  group('manifest', () {
    test('toJson は仕様どおりのキーと値を持つ', () {
      final Map<String, dynamic> json = buildManifest(
        recordCount: 3,
        imageCount: 2,
      ).toJson();

      expect(json['format'], 'scoreyomipm.backup');
      expect(json['schemaVersion'], 1);
      expect(json['appVersion'], '1.4.0+6');
      expect(json['exportedAt'], '2026-11-23T12:00:00.000Z');
      expect(json['recordCount'], 3);
      expect(json['imageCount'], 2);
      expect(json['templateCount'], 0);
    });

    test('fromJson は未知キーを無視し、既知キーだけを読む', () {
      final BackupManifest manifest = BackupManifest.fromJson(<String, dynamic>{
        'format': 'scoreyomipm.backup',
        'schemaVersion': 1,
        'appVersion': '1.4.0+6',
        'exportedAt': '2026-11-23T12:00:00.000Z',
        'recordCount': 3,
        'imageCount': 2,
        'futureField': 'ignored',
      });

      expect(manifest.recordCount, 3);
      expect(manifest.exportedAt.toUtc(), DateTime.utc(2026, 11, 23, 12));
    });

    test('templateCount が無い旧 manifest は 0 として読む', () {
      final BackupManifest manifest = BackupManifest.fromJson(<String, dynamic>{
        'format': 'scoreyomipm.backup',
        'schemaVersion': 1,
        'appVersion': '1.4.0+6',
        'exportedAt': '2026-11-23T12:00:00.000Z',
        'recordCount': 3,
        'imageCount': 2,
      });

      expect(manifest.templateCount, 0);
    });

    test('fromJson は型不一致を明示エラーにする（黙って既定値に落とさない）', () {
      expect(
        () => BackupManifest.fromJson(<String, dynamic>{
          'format': 'scoreyomipm.backup',
          'schemaVersion': 1,
          'appVersion': 1,
          'exportedAt': '2026-11-23T12:00:00.000Z',
          'recordCount': 3,
          'imageCount': 2,
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });
}
