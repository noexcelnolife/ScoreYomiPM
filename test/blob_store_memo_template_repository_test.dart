// BlobStoreMemoTemplateRepository の回帰テスト。
//
// WHY ここで担保するか: Web では FileMemoTemplateRepository が使えず、
// テンプレートが「作れるが復元で消える」経路（D-W14）を塞いだ実装がこれ。
// FileMemoTemplateRepository と同じ契約（冪等削除・未知 id の StateError・
// mergeAll の追加のみ）を満たすことを、メモリ上の BlobStore で確認する。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/data/blob_store_memo_template_repository.dart';
import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/platform/blob_store.dart';

/// 保存キー（実装の private 定数と同じ値。外部から見える契約として固定する）。
const String _key = 'memo_templates/templates.json';

/// 保存済みの生 JSON を読む（書き込み形式の検証用）。
Future<dynamic> _readStoredJson(BlobStore blobStore) async {
  final bytes = await blobStore.read(_key);
  expect(bytes, isNotNull, reason: '保存キー $_key に書き込まれていない');
  return jsonDecode(utf8.decode(bytes!));
}

void main() {
  group('BlobStoreMemoTemplateRepository', () {
    test('add した内容が listAll で読める（前後の空白は trim される）', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);

      final created = await repository.add(title: '  定番  ', body: '  本文  ');
      final all = await repository.listAll();

      expect(all, hasLength(1));
      expect(all.single.id, created.id);
      expect(all.single.title, '定番');
      expect(all.single.body, '本文');
    });

    test('update は差し替えて返し、保存内容にも反映される', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);
      final created = await repository.add(title: '旧', body: '旧本文');

      final updated = await repository.update(
        created.copyWith(title: ' 新 ', body: ' 新本文 '),
      );
      final all = await repository.listAll();

      expect(updated.title, '新');
      expect(updated.body, '新本文');
      expect(all.single.title, '新');
      expect(all.single.body, '新本文');
    });

    test('未知の id を update すると StateError', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);
      await repository.add(title: '名前', body: '本文');

      await expectLater(
        repository.update(
          const MemoTemplate(id: 'unknown', title: 'x', body: 'y'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('delete は対象だけを消し、同じ id の再削除でも失敗しない（冪等）', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);
      final first = await repository.add(title: 'A', body: 'a');
      final second = await repository.add(title: 'B', body: 'b');

      await repository.delete(first.id);
      expect(
        (await repository.listAll()).map((t) => t.id),
        <String>[second.id],
      );

      // 2 回目は書き込み自体が起きない（存在しない id）。
      final bytesBefore = await blobStore.read(_key);
      await repository.delete(first.id);
      final bytesAfter = await blobStore.read(_key);
      expect(bytesAfter, bytesBefore);
    });

    test('mergeAll は既存 id を飛ばし、ZIP 内の重複も 1 件に畳む', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);
      final existing = await repository.add(title: '既存', body: '既存本文');

      const duplicated = MemoTemplate(id: 'dup', title: '重複', body: '本文');
      final added = await repository.mergeAll(<MemoTemplate>[
        MemoTemplate(id: existing.id, title: '上書きしない', body: '上書きしない'),
        duplicated,
        duplicated,
        const MemoTemplate(id: 'new', title: '新規', body: '新規本文'),
      ]);

      final all = await repository.listAll();
      expect(added, 2, reason: 'dup と new の 2 件だけが追加される');
      expect(all.map((t) => t.id), <String>[existing.id, 'dup', 'new']);
      expect(
        all.first.title,
        '既存',
        reason: 'mergeAll は追加のみで既存を書き換えない',
      );
    });

    test('空の mergeAll は何も書き込まない', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);

      expect(await repository.mergeAll(const <MemoTemplate>[]), 0);
      expect(await blobStore.exists(_key), isFalse);
    });

    test('保存形式は JSON 配列で、別インスタンスからも読める', () async {
      final blobStore = MemoryBlobStore();
      final repository = BlobStoreMemoTemplateRepository(blobStore);
      await repository.add(title: 'A', body: 'a');
      await repository.add(title: 'B', body: 'b');

      final decoded = await _readStoredJson(blobStore);
      expect(decoded, isA<List<dynamic>>());
      expect((decoded as List<dynamic>).length, 2);

      // 再起動相当: 同じ BlobStore を別インスタンスで読み直す。
      final reopened = BlobStoreMemoTemplateRepository(blobStore);
      expect(
        (await reopened.listAll()).map((t) => t.title),
        <String>['A', 'B'],
      );
    });

    test('壊れた JSON は空リストを返し、原本を .corrupt. へ退避する', () async {
      final blobStore = MemoryBlobStore();
      final broken = utf8.encode('{ this is not json');
      await blobStore.write(_key, broken);
      final repository = BlobStoreMemoTemplateRepository(blobStore);

      expect(await repository.listAll(), isEmpty);

      final keys = await blobStore.listKeys('memo_templates/');
      expect(keys, hasLength(1), reason: '原本は消え、退避キーだけが残る');
      expect(keys.single, startsWith('$_key.corrupt.'));
      expect(await blobStore.read(keys.single), broken);
      expect(await blobStore.exists(_key), isFalse);
    });

    test('JSON だが配列でない場合も同じく退避して空リスト', () async {
      final blobStore = MemoryBlobStore();
      final notArray = utf8.encode('{"id":"t1"}');
      await blobStore.write(_key, notArray);
      final repository = BlobStoreMemoTemplateRepository(blobStore);

      expect(await repository.listAll(), isEmpty);

      final keys = await blobStore.listKeys('memo_templates/');
      expect(keys, hasLength(1));
      expect(keys.single, startsWith('$_key.corrupt.'));
      expect(await blobStore.read(keys.single), notArray);
    });

    test('不正な要素だけを捨て、正常な要素は残す', () async {
      final blobStore = MemoryBlobStore();
      final mixed = jsonEncode(<dynamic>[
        <String, dynamic>{'id': 'ok1', 'title': '正常1', 'body': '本文1'},
        <String, dynamic>{'id': 'bad', 'title': '', 'body': '本文'},
        'not a map',
        <String, dynamic>{'id': 'ok2', 'title': '正常2', 'body': '本文2'},
      ]);
      await blobStore.write(_key, utf8.encode(mixed));
      final repository = BlobStoreMemoTemplateRepository(blobStore);

      final all = await repository.listAll();

      expect(all.map((t) => t.id), <String>['ok1', 'ok2']);
      // 一部が壊れているだけで原本を退避しない（全体は正当な JSON）。
      expect(await blobStore.exists(_key), isTrue);
    });
  });
}
