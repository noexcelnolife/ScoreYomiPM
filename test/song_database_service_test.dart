// FileSongDatabaseService の単体テスト（一時ディレクトリ＋MockClient で検証）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('songdb_service_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// テスト用サービスを生成する（documents の解決を一時ディレクトリへ差し替え・DIP）。
  FileSongDatabaseService createService(http.Client client) {
    return FileSongDatabaseService(
      documentsDirectoryResolver: () async => tempDir,
      httpClientFactory: () => client,
    );
  }

  File mainDbFile() => File('${tempDir.path}/songs/main_v1.json');
  File additionalDbFile() => File('${tempDir.path}/songs/additional_v1.json');
  File settingsFile() => File('${tempDir.path}/songs/settings.json');

  /// 配信サーバーが返す想定の DB エンベロープ JSON を作る。
  String envelopeJson({required int dbVersion, int songCount = 2}) {
    return jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'dbVersion': dbVersion,
      'updatedAt': '2026-11-22T00:00:00Z',
      'sourceType': 'mainDb',
      'songCount': songCount,
      'songs': <Map<String, dynamic>>[
        for (int i = 0; i < songCount; i++)
          <String, dynamic>{'id': 'song-$i', 'title': '曲$i'},
      ],
    });
  }

  /// UTF-8 の JSON 応答を返す。
  ///
  /// WHY: http.Response に文字列で渡すと既定エンコード（latin1）で詰められ、
  /// 日本語曲名入りボディで例外になるため、UTF-8 バイトで明示する。
  http.Response jsonOk(String body) {
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
    );
  }

  group('配信 URL の設定保存', () {
    test('未設定時は空文字を返す', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      expect(await service.loadDistributionUrl(), isEmpty);
    });

    test('保存した URL を読み戻せる', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      await service.saveDistributionUrl('https://example.com/main_v1.json');
      expect(
        await service.loadDistributionUrl(),
        'https://example.com/main_v1.json',
      );
      expect(await settingsFile().exists(), isTrue);
    });
  });

  group('メイン DB の取得・更新', () {
    test('URL 未設定は skippedNoUrl でファイルを作らない', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl('');
      expect(result.status, SongDbUpdateStatus.skippedNoUrl);
      expect(await mainDbFile().exists(), isFalse);
    });

    test('ローカル無し → applied で main_v1.json を保存する', () async {
      final FileSongDatabaseService service = createService(
        MockClient(
          (request) async => jsonOk(envelopeJson(dbVersion: 2, songCount: 2)),
        ),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(
        result.status,
        SongDbUpdateStatus.applied,
        reason: result.message ?? '',
      );
      expect(result.dbVersion, 2);
      expect(result.songCount, 2);
      final dynamic saved = jsonDecode(await mainDbFile().readAsString());
      expect(saved['dbVersion'], 2);
      expect((saved['songs'] as List<dynamic>).length, 2);
    });

    test('ローカルと同 dbVersion → upToDate で保存しない', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => jsonOk(envelopeJson(dbVersion: 1))),
      );
      await service.updateFromUrl('https://x.test/db.json');
      final String firstContent = await mainDbFile().readAsString();

      final SongDbUpdateResult second = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(second.status, SongDbUpdateStatus.upToDate);
      expect(second.dbVersion, 1);
      expect(await mainDbFile().readAsString(), firstContent);
    });

    test('サーバーの方が新しい dbVersion → applied で上書きする', () async {
      // WHY: 呼び出しごとに dbVersion を変えることで、1 回目は v1 の保存、
      // 2 回目は v2 への上書きを検証する。
      int callCount = 0;
      final FileSongDatabaseService service = createService(
        MockClient((request) async {
          callCount++;
          final int version = callCount == 1 ? 1 : 2;
          return jsonOk(envelopeJson(dbVersion: version));
        }),
      );
      await service.updateFromUrl('https://x.test/db.json');
      final SongDbUpdateResult second = await service.updateFromUrl(
        'https://x.test/db.json',
      );

      expect(
        second.status,
        SongDbUpdateStatus.applied,
        reason: second.message ?? '',
      );
      expect(second.dbVersion, 2);
      final dynamic saved = jsonDecode(await mainDbFile().readAsString());
      expect(saved['dbVersion'], 2);
    });

    test('ネットワークエラー → failed・既存ファイルは非破壊', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      // 既存 DB を用意しておく。
      await mainDbFile().parent.create(recursive: true);
      await mainDbFile().writeAsString(envelopeJson(dbVersion: 1));

      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(result.message, isNotNull);
      final dynamic saved = jsonDecode(await mainDbFile().readAsString());
      expect(saved['dbVersion'], 1);
    });

    test('HTTP 404 → failed', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('not found', 404)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(await mainDbFile().exists(), isFalse);
    });

    test('songs 配列を含まない JSON → failed', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('{"error":"oops"}', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(await mainDbFile().exists(), isFalse);
    });

    test('dbVersion 欠落 → failed', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('{"songs":[]}', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(await mainDbFile().exists(), isFalse);
    });
  });

  group('追加 DB の取り込み', () {
    test('正しい JSON → additional_v1.json へ保存する', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final Directory sourceDir = await Directory.systemTemp.createTemp(
        'songdb_import_test',
      );
      try {
        final File sourceFile = File(
          '${sourceDir.path}/additional_source.json',
        );
        await sourceFile.writeAsString(
          jsonEncode(<String, dynamic>{
            'schemaVersion': 1,
            'sourceType': 'localAdditional',
            'songs': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'extra-1', 'title': '追加曲'},
            ],
          }),
        );

        final SongImportResult result = await service.importAdditionalJson(
          sourceFile.readAsBytesSync(),
          fileName: sourceFile.path.split(RegExp(r'[\\/]')).last,
        );
        expect(result.success, isTrue);
        expect(result.songCount, 1);
        final dynamic saved = jsonDecode(
          await additionalDbFile().readAsString(),
        );
        expect((saved['songs'] as List<dynamic>).first['id'], 'extra-1');
      } finally {
        await sourceDir.delete(recursive: true);
      }
    });

    test('songs 配列を含まない JSON は失敗・ファイル非作成', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final Directory sourceDir = await Directory.systemTemp.createTemp(
        'songdb_import_test',
      );
      try {
        final File sourceFile = File('${sourceDir.path}/invalid.json');
        await sourceFile.writeAsString('not json at all');

        final SongImportResult result = await service.importAdditionalJson(
          sourceFile.readAsBytesSync(),
          fileName: sourceFile.path.split(RegExp(r'[\\/]')).last,
        );
        expect(result.success, isFalse);
        expect(result.message, isNotNull);
        expect(await additionalDbFile().exists(), isFalse);
      } finally {
        await sourceDir.delete(recursive: true);
      }
    });

    test('存在しないファイルは失敗を返す', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final SongImportResult result = await service.importAdditionalJson(
        Uint8List(0),
        fileName: 'missing.json',
      );
      expect(result.success, isFalse);
      expect(result.message, isNotNull);
    });
  });
}
