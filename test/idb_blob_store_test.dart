import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:scoreyomipm/platform/blob_store.dart';
import 'package:scoreyomipm/platform/idb_blob_store.dart';

/// キー範囲の判定に使う接頭辞。実データの命名（`records/...`）に合わせる。
const String _recordsPrefix = 'records/';

void main() {
  late IdbBlobStore store;

  setUp(() {
    // WHY(毎回空のファクトリを作るか): idbFactoryMemory はプロセス内で共有され、
    // テスト間でデータが残る。独立性を保つためテストごとに空の実装を渡す。
    store = IdbBlobStore(newIdbFactoryMemory());
  });

  group('IdbBlobStore', () {
    test('書き込んだバイト列をそのまま読み戻せる', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 250, 0, 7]);

      await store.write('${_recordsPrefix}a', bytes);

      expect(await store.read('${_recordsPrefix}a'), bytes);
    });

    test('未保存のキーは null を返す', () async {
      expect(await store.read('${_recordsPrefix}missing'), isNull);
    });

    test('書き込み後に呼び出し元のバッファを書き換えても保存内容は変わらない', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
      await store.write('${_recordsPrefix}a', bytes);

      bytes[0] = 99;

      // WHY(複製を確認するか): 呼び出し側がバッファを使い回す実装（OCR の結果
      // 画像を渡す経路など）で、保存済みの内容が後から書き換わってはならない。
      expect(await store.read('${_recordsPrefix}a'), <int>[1, 2, 3]);
    });

    test('exists は書き込みの有無を反映する', () async {
      expect(await store.exists('${_recordsPrefix}a'), isFalse);

      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));

      expect(await store.exists('${_recordsPrefix}a'), isTrue);
    });

    test('listKeys は接頭辞に一致するキーだけを昇順で返す', () async {
      await store.write('${_recordsPrefix}b', Uint8List.fromList(<int>[1]));
      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[2]));
      await store.write('songs/db', Uint8List.fromList(<int>[3]));

      expect(await store.listKeys(_recordsPrefix), <String>[
        '${_recordsPrefix}a',
        '${_recordsPrefix}b',
      ]);
    });

    test('listKeys は接頭辞を共有するだけの隣接キーを取り違えない', () async {
      await store.write('records/1', Uint8List.fromList(<int>[1]));
      // WHY(このキーを足すか): 接頭辞判定を `startsWith` ではなくキー範囲で
      // 行っているため、`recordsX` のような「前方一致だが区切りが違う」キーを
      // 混入させないことを確かめる。
      await store.write('recordsX/1', Uint8List.fromList(<int>[2]));

      expect(await store.listKeys(_recordsPrefix), <String>['records/1']);
    });

    test('deleteWhere は接頭辞に一致するキーだけを消す', () async {
      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));
      await store.write('${_recordsPrefix}b', Uint8List.fromList(<int>[2]));
      await store.write('songs/db', Uint8List.fromList(<int>[3]));

      await store.deleteWhere(_recordsPrefix);

      expect(await store.listKeys(_recordsPrefix), isEmpty);
      expect(await store.exists('songs/db'), isTrue);
    });

    test('同じキーへの書き込みは上書きになる', () async {
      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));
      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[2, 2]));

      expect(await store.read('${_recordsPrefix}a'), <int>[2, 2]);
    });

    test('delete は対象のキーだけを消す', () async {
      await store.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));
      await store.write('${_recordsPrefix}b', Uint8List.fromList(<int>[2]));

      await store.delete('${_recordsPrefix}a');

      expect(await store.exists('${_recordsPrefix}a'), isFalse);
      expect(await store.exists('${_recordsPrefix}b'), isTrue);
    });
  });

  group('IdbBlobStore.onFirstWrite', () {
    test('最初の書き込み成功後に 1 回だけ呼ばれる', () async {
      int calls = 0;
      final IdbBlobStore hooked = IdbBlobStore(
        newIdbFactoryMemory(),
        onFirstWrite: () async => calls++,
      );

      await hooked.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));
      await hooked.write('${_recordsPrefix}b', Uint8List.fromList(<int>[2]));

      // WHY(1 回に限るか): フックはブラウザの永続化要求を想定しており、
      // 保存のたびに繰り返す必要が無い。
      expect(calls, 1);
    });

    test('フックが失敗しても保存は成功したまま', () async {
      final IdbBlobStore hooked = IdbBlobStore(
        newIdbFactoryMemory(),
        onFirstWrite: () async => throw StateError('persist refused'),
      );

      await hooked.write('${_recordsPrefix}a', Uint8List.fromList(<int>[1]));

      // WHY(保存を優先するか): 永続化要求の拒否は「保存できなかった」ことを
      // 意味しない。ここで例外を投げると、正常な保存が失敗として扱われる。
      expect(await hooked.read('${_recordsPrefix}a'), <int>[1]);
    });
  });

  group('BlobStoreQuotaException', () {
    test('メッセージを保持し、Exception として捕捉できる', () {
      const BlobStoreQuotaException exception = BlobStoreQuotaException('空き容量が足りません');

      expect(exception, isA<Exception>());
      expect(exception.message, '空き容量が足りません');
      expect(exception.toString(), contains('空き容量が足りません'));
    });
  });
}
