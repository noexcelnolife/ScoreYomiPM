// FileSongDatabaseService の状態照会（案A: 常設ステータス）と
// 最終操作の永続化（案B）のテスト（一時ディレクトリ＋MockClient）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';

void main() {
  late Directory tempDir;

  /// 最終操作の記録時刻を固定し、永続化された値と厳密に比較する。
  final DateTime fixedNow = DateTime.utc(2026, 11, 24, 12, 34, 56);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('songdb_status_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// テスト用サービスを生成する（documents の解決と時計を差し替え・DIP）。
  FileSongDatabaseService createService(http.Client client) {
    return FileSongDatabaseService(
      documentsDirectoryResolver: () async => tempDir,
      httpClientFactory: () => client,
      clock: () => fixedNow,
    );
  }

  File mainDbFile() => File('${tempDir.path}/songs/main_v1.json');
  File additionalDbFile() => File('${tempDir.path}/songs/additional_v1.json');
  File settingsFile() => File('${tempDir.path}/songs/settings.json');

  /// 配信サーバーのメイン DB エンベロープを返すクライアント。
  ///
  /// WHY: http.Response に文字列で渡すと latin1 で詰められ日本語曲名で例外に
  /// なるため、既存テストと同じく UTF-8 バイト応答にする。
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
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
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
      expect(status.lastOperation, isNull);
    });

    test('main DB 保存後は exists=true・曲数・dbVersion・mtime を返す', () async {
      final FileSongDatabaseService service = createService(okClient());
      await service.updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await service.loadStatus();
      expect(status.main.exists, isTrue);
      expect(status.main.songCount, 2);
      expect(status.main.dbVersion, 2);
      expect(status.main.updatedAt, isNotNull);
      // WHY: updatedAt は表示用のファイル更新時刻。同一 stat 由来のため一致する。
      final Duration diff = status.main.updatedAt!.difference(
        mainDbFile().lastModifiedSync(),
      );
      expect(diff.inSeconds.abs(), lessThanOrEqualTo(1));
    });

    test('壊れた JSON でも例外を投げず exists=true・件数不明で返す', () async {
      await mainDbFile().parent.create(recursive: true);
      await mainDbFile().writeAsString('{ this is not json');
      // WHY: 配列は JSON として妥当だが辞書の形ではないため件数不明として扱う。
      await additionalDbFile().writeAsString('[1, 2, 3]');

      // 例外が投げられないこと自体が要件（投げればテストが失敗する）。
      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
      expect(status.main.exists, isTrue);
      expect(status.main.songCount, isNull);
      expect(status.main.dbVersion, isNull);
      expect(status.main.updatedAt, isNotNull);
      expect(status.additional.exists, isTrue);
      expect(status.additional.songCount, isNull);
    });

    test('settings.json が壊れていても URL 空・最終操作なしで返す', () async {
      await settingsFile().parent.create(recursive: true);
      await settingsFile().writeAsString('not json at all');

      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
      expect(status.distributionUrl, isEmpty);
      expect(status.lastOperation, isNull);
    });

    test('辞書ファイルが読めない（IO 例外）でも落ちず件数不明で返す', () async {
      await createService(okClient()).updateFromUrl('https://x.test/db.json');

      // WHY: 権限不足・ロック等で読み取りが失敗する状況を再現する。
      // 同一パスを排他ロックすると、存在確認は成功し読み取りだけが失敗する。
      final RandomAccessFile lock = await mainDbFile().open(
        mode: FileMode.write,
      );
      await lock.lock(FileLock.exclusive);
      try {
        // 例外が投げられないこと自体が要件（投げればテストが失敗する）。
        final SongDatabaseStatus status = await createService(okClient())
            .loadStatus();
        expect(status.main.exists, isTrue);
        expect(status.main.songCount, isNull);
        expect(status.main.updatedAt, isNull);
      } finally {
        await lock.unlock();
        await lock.close();
      }
    });

    test('settings.json が読めない（IO 例外）でも落ちず未設定で返す', () async {
      await createService(okClient()).updateFromUrl('https://x.test/db.json');

      final RandomAccessFile lock = await settingsFile().open(
        mode: FileMode.write,
      );
      await lock.lock(FileLock.exclusive);
      try {
        final SongDatabaseStatus status = await createService(okClient())
            .loadStatus();
        expect(status.distributionUrl, isEmpty);
        expect(status.lastOperation, isNull);
      } finally {
        await lock.unlock();
        await lock.close();
      }
    });
  });

  group('最終操作の永続化（案B）', () {
    test('updateFromUrl 成功 → 別インスタンスでも update/成功/曲数を読める', () async {
      await createService(okClient()).updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
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
      final FileSongDatabaseService writer = FileSongDatabaseService(
        documentsDirectoryResolver: () async => tempDir,
        httpClientFactory: () => okClient(),
        clock: () => localTime,
      );
      await writer.updateFromUrl('https://x.test/db.json');

      final SongDbLastOperation? op = (await createService(
        okClient(),
      ).loadStatus()).lastOperation;
      expect(op!.at.millisecondsSinceEpoch, localTime.millisecondsSinceEpoch);
      expect(op.at.isAtSameMomentAs(localTime), isTrue);
    });

    test('updateFromUrl 失敗（HTTP 500）→ 失敗と理由を残す', () async {
      await createService(failingClient(500))
          .updateFromUrl('https://x.test/db.json');

      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
      final SongDbLastOperation? op = status.lastOperation;
      expect(op!.kind, SongDbOperationKind.update);
      expect(op.outcome, SongDbOperationOutcome.failure);
      expect(op.message, contains('HTTP 500'));
      expect(op.songCount, isNull);
      expect(op.dbVersion, isNull);
    });

    test('URL 未設定のスキップも記録する', () async {
      final SongDbUpdateResult result = await createService(okClient())
          .updateFromUrl('');
      expect(result.status, SongDbUpdateStatus.skippedNoUrl);

      final SongDbLastOperation? op = (await createService(
        okClient(),
      ).loadStatus()).lastOperation;
      expect(op!.kind, SongDbOperationKind.update);
      // WHY: スキップは失敗ではないため、UI が「失敗」と表示しないよう
      // skipped として区別して保存されることを確認する。
      expect(op.outcome, SongDbOperationOutcome.skipped);
      expect(op.message, isNotNull);
      expect(op.songCount, isNull);
      expect(op.dbVersion, isNull);
    });

    test('upToDate でもサーバー側の収録曲数を残す', () async {
      await createService(okClient(dbVersion: 2))
          .updateFromUrl('https://x.test/db.json');
      final SongDbUpdateResult second = await createService(
        okClient(dbVersion: 2),
      ).updateFromUrl('https://x.test/db.json');
      expect(second.status, SongDbUpdateStatus.upToDate);

      final SongDbLastOperation? op = (await createService(
        okClient(),
      ).loadStatus()).lastOperation;
      expect(op!.outcome, SongDbOperationOutcome.success);
      expect(op.songCount, 2);
      expect(op.dbVersion, 2);
    });

    test('importAdditionalJson 成功 → import 種別・取り込み元 basename', () async {
      final Directory sourceDir = await Directory.systemTemp.createTemp(
        'songdb_status_src',
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

        final SongImportResult result = await createService(okClient())
            .importAdditionalJson(
              sourceFile.readAsBytesSync(),
              fileName: sourceFile.path.split(RegExp(r'[\\/]')).last,
            );
        expect(result.success, isTrue);

        final SongDbLastOperation? op = (await createService(
          okClient(),
        ).loadStatus()).lastOperation;
        expect(op!.kind, SongDbOperationKind.importAdditional);
        expect(op.outcome, SongDbOperationOutcome.success);
        expect(op.songCount, 1);
        // WHY: dbVersion はメイン DB 専用の概念のため import では null。
        expect(op.dbVersion, isNull);
        expect(op.sourceFileName, 'additional_source.json');
      } finally {
        await sourceDir.delete(recursive: true);
      }
    });

    test('旧形式（succeeded キーのみ）の記録は読まずに null を返す', () async {
      await settingsFile().parent.create(recursive: true);
      // WHY: 旧形式は outcome を持たないため解釈できない。表示専用の補助情報
      // なので、例外にせず「記録なし」として黙って捨てる。
      await settingsFile().writeAsString(
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
      );

      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
      expect(status.lastOperation, isNull);
      expect(status.distributionUrl, 'https://legacy.test/db.json');
    });

    test('importAdditionalJson 失敗も記録する', () async {
      final SongImportResult result = await createService(okClient())
          .importAdditionalJson(
            Uint8List(0),
            fileName: 'missing.json',
          );
      expect(result.success, isFalse);

      final SongDbLastOperation? op = (await createService(
        okClient(),
      ).loadStatus()).lastOperation;
      expect(op!.kind, SongDbOperationKind.importAdditional);
      expect(op.outcome, SongDbOperationOutcome.failure);
      expect(op.sourceFileName, 'missing.json');
      expect(op.message, isNotNull);
    });
  });

  group('settings.json の後方互換', () {
    test('URL を保存しても既存の最終操作記録が消えない', () async {
      await createService(okClient()).updateFromUrl('https://x.test/db.json');
      await createService(okClient())
          .saveDistributionUrl('https://x.test/new.json');

      final SongDatabaseStatus status = await createService(okClient())
          .loadStatus();
      expect(status.distributionUrl, 'https://x.test/new.json');
      expect(status.lastOperation, isNotNull);
      expect(status.lastOperation!.kind, SongDbOperationKind.update);
    });

    test('未知の設定キーを保持する（read-modify-write）', () async {
      await settingsFile().parent.create(recursive: true);
      await settingsFile().writeAsString(
        jsonEncode(<String, dynamic>{
          'distributionUrl': 'https://keep.test/db.json',
          'futureKey': 42,
        }),
      );

      await createService(okClient()).updateFromUrl('https://x.test/db.json');

      final dynamic saved = jsonDecode(await settingsFile().readAsString());
      expect(saved['distributionUrl'], 'https://keep.test/db.json');
      expect(saved['futureKey'], 42);
      expect(saved['lastOperation'], isNotNull);
    });

    test('既存ユーザーの distributionUrl をそのまま読める（回帰）', () async {
      await settingsFile().parent.create(recursive: true);
      await settingsFile().writeAsString(
        jsonEncode(<String, String>{
          'distributionUrl': 'https://legacy.test/db.json',
        }),
      );

      expect(
        await createService(okClient()).loadDistributionUrl(),
        'https://legacy.test/db.json',
      );
      expect(
        (await createService(okClient()).loadStatus()).distributionUrl,
        'https://legacy.test/db.json',
      );
    });
  });
}
