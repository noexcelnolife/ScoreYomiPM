// FileSongDatabaseService の状態照会（案A: 常設ステータス）と
// 最終操作の永続化（案B）のテスト（MemoryBlobStore＋MockClient）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/songdb/song_db_paths.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

void main() {
  /// 最終操作の記録時刻を固定し、永続化された値と厳密に比較する。
  final DateTime fixedNow = DateTime.utc(2026, 11, 24, 12, 34, 56);

  /// テスト用サービスを生成する（MemoryBlobStore と時計を差し替え・DIP）。
  ///
  /// [blobStore] を渡すと、同一ストアを複数のサービス インスタンス間で
  /// 共有できる（テスト内で書き込みと読み込みを分ける場合に必須）。
  FileSongDatabaseService createService(http.Client client,
      {BlobStore? blobStore}) {
    return FileSongDatabaseService(
      blobStore: blobStore ?? MemoryBlobStore(),
      httpClientFactory: () => client,
      clock: () => fixedNow,
    );
  }

  BlobStore blobStoreOf(FileSongDatabaseService service) => service.blobStore;

  /// 配信サーバーのメイン DB エンベロープを返すクライアント。
  http.Client okClient({int dbVersion = 2, int songCount = 2}) {
    return MockClient(
      (request) async => http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'schemaVersion': 1,
            'dbVersion': dbVersion,
            'updatedAt': '2026-11-22T00:00:00Z',
            'sourceType': 'mainDb',
            'songs': <Map<String, dynamic>>[
              for (int i = 0; i < songCount; i++)
                <String, dynamic>{'id': 'song-$i', 'title': '曲$i'},
            ],
          }),
        ),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      ),
    );
  }

  http.Client failingClient(int statusCode) {
    return MockClient((request) async => http.Response('error', statusCode));
  }

  group('ステータス照会（案A）', () {
    test('辞書ファイルが無ければ exists=false・URL 空・最終操作なし', () async {
      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();

      expect(status.distributionUrl, isEmpty);
      expect(status.main.exists, isFalse);
      expect(status.main.songCount, isNull);
      expect(status.main.dbVersion, isNull);
      expect(status.main.updatedAt, isNull);
      expect(status.additional.exists, isFalse);
      expect(status.additional.songCount, isNull);
      expect(status.additional.updatedAt, isNull);
      expect(status.lastOperation, isNull);
    });

    test('main DB 保存後は exists=true・曲数・dbVersion を返す', () async {
      final FileSongDatabaseService service = createService(okClient());
      await service.updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await service.loadStatus();
      expect(status.main.exists, isTrue);
      expect(status.main.songCount, 2);
      expect(status.main.dbVersion, 2);
      expect(status.main.updatedAt, isNull);
    });

    test('壊れた JSON でも例外を投げず exists=true・件数不明で返す', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.mainDbRelativePath,
        utf8.encode('{ this is not json'),
      );
      // WHY: 配列は JSON として妥当だが辞書の形ではないため件数不明として扱う。
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.additionalDbRelativePath,
        utf8.encode('[1, 2, 3]'),
      );

      // 例外が投げられないこと自体が要件（投げればテストが失敗する）。
      final SongDatabaseStatus status =
          await createService(okClient(), blobStore: store).loadStatus();
      expect(status.main.exists, isTrue);
      expect(status.main.songCount, isNull);
      expect(status.main.dbVersion, isNull);
      expect(status.main.updatedAt, isNull);
      expect(status.additional.exists, isTrue);
      expect(status.additional.songCount, isNull);
      expect(status.additional.updatedAt, isNull);
    });

    test('settings.json が壊れていても URL 空・最終操作なしで返す', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.settingsRelativePath,
        utf8.encode('not json at all'),
      );

      final SongDatabaseStatus status =
          await createService(okClient(), blobStore: store).loadStatus();
      expect(status.distributionUrl, isEmpty);
      expect(status.lastOperation, isNull);
    });
  });

  group('最終操作の永続化（案B）', () {
    test('updateFromUrl 成功 → 別インスタンスでも update/成功/曲数を読める', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await createService(okClient(), blobStore: store)
          .updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await createService(okClient(),
          blobStore: store).loadStatus();
      final SongDbLastOperation? op = status.lastOperation;
      expect(op, isNotNull);
      expect(op!.kind, SongDbOperationKind.update);
      expect(op.outcome, SongDbOperationOutcome.success);
      expect(op.at.millisecondsSinceEpoch, fixedNow.millisecondsSinceEpoch);
      expect(op.songCount, 2);
      expect(op.dbVersion, 2);
      expect(op.message, isNull);
      expect(op.sourceFileName, isNull);
    });

    test('at はローカル時刻でも保存往復で同じ時刻になる（epoch ミリ秒）', () async {
      // WHY: ローカル時刻の ISO 8601 文字列で保存すると時差情報が落ち、
      // 読み戻しで別時刻になり得る。タイムゾーン非依存であることを固定する。
      final DateTime localTime = DateTime(2026, 11, 24, 12, 34, 56, 789);
      final MemoryBlobStore store = MemoryBlobStore();
      final FileSongDatabaseService writer = FileSongDatabaseService(
        blobStore: store,
        httpClientFactory: () => okClient(),
        clock: () => localTime,
      );
      await writer.updateFromUrl('https://x.test/db.json');

      final SongDbLastOperation? op = (await createService(okClient(),
          blobStore: store).loadStatus()).lastOperation;
      expect(op!.at.millisecondsSinceEpoch, localTime.millisecondsSinceEpoch);
      expect(op.at.isAtSameMomentAs(localTime), isTrue);
    });

    test('updateFromUrl 失敗（HTTP 500）→ 失敗と理由を残す', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await createService(failingClient(500), blobStore: store)
          .updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await createService(okClient(),
          blobStore: store).loadStatus();
      final SongDbLastOperation? op = status.lastOperation;
      expect(op!.kind, SongDbOperationKind.update);
      expect(op.outcome, SongDbOperationOutcome.failure);
      expect(op.message, contains('HTTP 500'));
      expect(op.songCount, isNull);
      expect(op.dbVersion, isNull);
    });

    test('URL 未設定のスキップも記録する', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      final SongDbUpdateResult result = await createService(okClient(),
          blobStore: store).updateFromUrl('');
      expect(result.status, SongDbUpdateStatus.skippedNoUrl);

      final SongDbLastOperation? op = (await createService(okClient(),
          blobStore: store).loadStatus()).lastOperation;
      expect(op!.kind, SongDbOperationKind.update);
      // WHY: スキップは失敗ではないため、UI が「失敗」と表示しないよう
      // skipped として区別して保存されることを確認する。
      expect(op.outcome, SongDbOperationOutcome.skipped);
      expect(op.message, isNotNull);
      expect(op.songCount, isNull);
      expect(op.dbVersion, isNull);
    });

    test('upToDate でもサーバー側の収録曲数を残す', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await createService(okClient(dbVersion: 2), blobStore: store)
          .updateFromUrl('https://x.test/db.json');
      final SongDbUpdateResult second = await createService(
        okClient(dbVersion: 2),
        blobStore: store,
      ).updateFromUrl('https://x.test/db.json');
      expect(second.status, SongDbUpdateStatus.upToDate);

      final SongDbLastOperation? op = (await createService(okClient(),
          blobStore: store).loadStatus()).lastOperation;
      expect(op!.outcome, SongDbOperationOutcome.success);
      expect(op.songCount, 2);
      expect(op.dbVersion, 2);
    });

    test('importAdditionalJson 成功 → import 種別・取り込み元 basename', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      final SongImportResult result = await createService(okClient(),
          blobStore: store).importAdditionalJson(
            utf8.encode(jsonEncode(<String, dynamic>{
              'schemaVersion': 1,
              'sourceType': 'localAdditional',
              'songs': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'extra-1', 'title': '追加曲'},
              ],
            })),
            fileName: 'additional_source.json',
          );
      expect(result.success, isTrue);

      final SongDbLastOperation? op = (await createService(okClient(),
          blobStore: store).loadStatus()).lastOperation;
      expect(op!.kind, SongDbOperationKind.importAdditional);
      expect(op.outcome, SongDbOperationOutcome.success);
      expect(op.songCount, 1);
      // WHY: dbVersion はメイン DB 専用の概念のため import では null。
      expect(op.dbVersion, isNull);
      expect(op.sourceFileName, 'additional_source.json');
    });

    test('旧形式（succeeded キーのみ）の記録は読まずに null を返す', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.settingsRelativePath,
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'distributionUrl': 'https://legacy.test/db.json',
            'lastOperation': <String, dynamic>{
              'kind': 'update',
              'succeeded': true,
              'at': '2026-11-24T12:34:56.000Z',
              'message': null,
              'songCount': 2,
              'sourceFileName': null,
            },
          }),
        ),
      );

      final SongDatabaseStatus status = await createService(okClient(),
          blobStore: store).loadStatus();
      expect(status.lastOperation, isNull);
      expect(status.distributionUrl, 'https://legacy.test/db.json');
    });

    test('importAdditionalJson 失敗も記録する', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      final SongImportResult result = await createService(okClient(),
          blobStore: store).importAdditionalJson(
            Uint8List(0),
            fileName: 'missing.json',
          );
      expect(result.success, isFalse);

      final SongDbLastOperation? op = (await createService(okClient(),
          blobStore: store).loadStatus()).lastOperation;
      expect(op!.kind, SongDbOperationKind.importAdditional);
      expect(op.outcome, SongDbOperationOutcome.failure);
      expect(op.sourceFileName, 'missing.json');
      expect(op.message, isNotNull);
    });
  });

  group('settings.json の後方互換', () {
    test('URL を保存しても既存の最終操作記録が消えない', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await createService(okClient(), blobStore: store)
          .updateFromUrl('https://x.test/db.json');
      await createService(okClient(), blobStore: store)
          .saveDistributionUrl('https://x.test/new.json');

      final SongDatabaseStatus status = await createService(okClient(),
          blobStore: store).loadStatus();
      expect(status.distributionUrl, 'https://x.test/new.json');
      expect(status.lastOperation, isNotNull);
      expect(status.lastOperation!.kind, SongDbOperationKind.update);
    });

    test('未知の設定キーを保持する（read-modify-write）', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.settingsRelativePath,
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'distributionUrl': 'https://keep.test/db.json',
            'futureKey': 42,
          }),
        ),
      );

      await createService(okClient(), blobStore: store)
          .updateFromUrl('https://x.test/db.json');

      final dynamic saved = jsonDecode(
        utf8.decode(
          await blobStoreOf(createService(okClient(), blobStore: store)).read(
            SongDbPaths.settingsRelativePath,
          ) as Uint8List,
        ),
      );
      expect(saved['distributionUrl'], 'https://keep.test/db.json');
      expect(saved['futureKey'], 42);
      expect(saved['lastOperation'], isNotNull);
    });

    test('既存ユーザーの distributionUrl をそのまま読める（回帰）', () async {
      final MemoryBlobStore store = MemoryBlobStore();
      await blobStoreOf(createService(okClient(), blobStore: store)).write(
        SongDbPaths.settingsRelativePath,
        utf8.encode(
          jsonEncode(<String, String>{
            'distributionUrl': 'https://legacy.test/db.json',
          }),
        ),
      );

      expect(
        await createService(okClient(), blobStore: store).loadDistributionUrl(),
        'https://legacy.test/db.json',
      );
      expect(
        (await createService(okClient(), blobStore: store).loadStatus())
            .distributionUrl,
        'https://legacy.test/db.json',
      );
    });
  });
}
