// FileSongDatabaseService の単体テスト（MemoryBlobStore＋MockClient で検証）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

void main() {
  /// テスト用サービスを生成する（MemoryBlobStore を使う・DIP）。
  FileSongDatabaseService createService(http.Client client) {
    return FileSongDatabaseService(
      blobStore: MemoryBlobStore(),
      httpClientFactory: () => client,
    );
  }

  BlobStore blobStoreOf(FileSongDatabaseService service) => service.blobStore;

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
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }

  /// BlobStore に保存されたメイン DB の内容をデコードして返す。
  dynamic readMainDb(BlobStore store) async {
    final bytes = await store.read(SongDbPaths.mainDbRelativePath);
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes));
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
      expect(
        await blobStoreOf(service).exists(SongDbPaths.settingsRelativePath),
        isTrue,
      );
    });
  });

  group('メイン DB の取得・更新', () {
    test('URL 未設定は skippedNoUrl でファイルを作らない', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl('');
      expect(result.status, SongDbUpdateStatus.skippedNoUrl);
      expect(
        await blobStoreOf(service).exists(SongDbPaths.mainDbRelativePath),
        isFalse,
      );
    });

    test('ローカル無し → applied でメイン DB を保存する', () async {
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
      final dynamic saved = await readMainDb(blobStoreOf(service));
      expect(saved['dbVersion'], 2);
      expect((saved['songs'] as List<dynamic>).length, 2);
    });

    test('ローカルと同 dbVersion → upToDate で保存しない', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => jsonOk(envelopeJson(dbVersion: 1))),
      );
      await service.updateFromUrl('https://x.test/db.json');
      final dynamic firstContent = await readMainDb(blobStoreOf(service));

      final SongDbUpdateResult second = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(second.status, SongDbUpdateStatus.upToDate);
      expect(second.dbVersion, 1);
      expect(await readMainDb(blobStoreOf(service)), firstContent);
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
      final dynamic saved = await readMainDb(blobStoreOf(service));
      expect(saved['dbVersion'], 2);
    });

    test('ネットワークエラー → failed・既存ファイルは非破壊', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      // 既存 DB を用意しておく。
      await blobStoreOf(service).write(
        SongDbPaths.mainDbRelativePath,
        utf8.encode(envelopeJson(dbVersion: 1)),
      );

      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(result.message, isNotNull);
      final dynamic saved = await readMainDb(blobStoreOf(service));
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
      expect(
        await blobStoreOf(service).exists(SongDbPaths.mainDbRelativePath),
        isFalse,
      );
    });

    test('songs 配列を含まない JSON → failed', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('{"error":"oops"}', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(
        await blobStoreOf(service).exists(SongDbPaths.mainDbRelativePath),
        isFalse,
      );
    });

    test('dbVersion 欠落 → failed', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('{"songs":[]}', 200)),
      );
      final SongDbUpdateResult result = await service.updateFromUrl(
        'https://x.test/db.json',
      );
      expect(result.status, SongDbUpdateStatus.failed);
      expect(
        await blobStoreOf(service).exists(SongDbPaths.mainDbRelativePath),
        isFalse,
      );
    });
  });

  group('追加 DB の取り込み', () {
    test('正しい JSON → 追加 DB へ保存する', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      await service.importAdditionalJson(
        utf8.encode(jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
          'sourceType': 'localAdditional',
          'songs': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'extra-1', 'title': '追加曲'},
          ],
        })),
        fileName: 'additional_source.json',
      );
      final dynamic saved = await blobStoreOf(service).read(
        SongDbPaths.additionalDbRelativePath,
      );
      final Map<String, dynamic> decoded = jsonDecode(
        utf8.decode(saved as Uint8List),
      ) as Map<String, dynamic>;
      expect((decoded['songs'] as List<dynamic>).first['id'], 'extra-1');
    });

    test('songs 配列を含まない JSON は失敗・ファイル非作成', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );
      final SongImportResult result = await service.importAdditionalJson(
        utf8.encode('not json at all'),
        fileName: 'invalid.json',
      );
      expect(result.success, isFalse);
      expect(result.message, isNotNull);
      expect(
        await blobStoreOf(service).exists(SongDbPaths.additionalDbRelativePath),
        isFalse,
      );
    });

    test('空バイトは失敗を返す', () async {
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

    test('申告サイズが上限を超える場合は中身を読まずに拒否する', () async {
      final FileSongDatabaseService service = createService(
        MockClient((request) async => http.Response('', 200)),
      );

      // WHY(バイト列を空で渡すか): 上限超過の判定は「読み込む前」に済ませる設計。
      // 選択側はサイズだけ申告し、中身は読まない。判定と文言はサービスに集約する。
      final SongImportResult result = await service.importAdditionalJson(
        Uint8List(0),
        fileName: 'huge.json',
        declaredLength: kMaxAdditionalJsonBytes + 1,
      );

      expect(result.success, isFalse);
      expect(result.message, contains('5MB'));
      // 空ファイル扱いのメッセージに落ちていないこと（判定順序の回帰）。
      expect(result.message, isNot(contains('空')));
    });
  });
}
