import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/platform/blob_store.dart';

void main() {
  group('MemoryBlobStore', () {
    late MemoryBlobStore store;

    setUp(() {
      store = MemoryBlobStore();
    });

    test('書き込み後の読み取り（往復）', () async {
      await store.write('songs/popn/001.json', Uint8List.fromList([1, 2, 3]));
      final result = await store.read('songs/popn/001.json');
      expect(result, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('存在しないキーは null を返す', () async {
      final result = await store.read('songs/missing.json');
      expect(result, isNull);
    });

    test('exists は存在時 true、不在時 false', () async {
      await store.write('a/b.txt', Uint8List.fromList([0]));
      expect(await store.exists('a/b.txt'), isTrue);
      expect(await store.exists('a/c.txt'), isFalse);
    });

    test('listKeys は prefix でフィルタし昇順にソートする', () async {
      await store.write('songs/popn/001.json', Uint8List.fromList([1]));
      await store.write('songs/popn/002.json', Uint8List.fromList([2]));
      await store.write('songs/iidx/001.json', Uint8List.fromList([3]));
      await store.write('other/file.txt', Uint8List.fromList([4]));

      final result = await store.listKeys('songs/popn/');
      expect(result, equals(['songs/popn/001.json', 'songs/popn/002.json']));
    });

    test('delete でエントリを削除できる', () async {
      await store.write('temp/x.txt', Uint8List.fromList([1]));
      expect(await store.exists('temp/x.txt'), isTrue);
      await store.delete('temp/x.txt');
      expect(await store.exists('temp/x.txt'), isFalse);
    });

    test('deleteWhere は prefix 一致をすべて削除する', () async {
      await store.write('temp/1.txt', Uint8List.fromList([1]));
      await store.write('temp/2.txt', Uint8List.fromList([2]));
      await store.write('keep/3.txt', Uint8List.fromList([3]));
      await store.deleteWhere('temp/');
      expect(await store.exists('temp/1.txt'), isFalse);
      expect(await store.exists('temp/2.txt'), isFalse);
      expect(await store.exists('keep/3.txt'), isTrue);
    });

    test('書き込みは上書きされる', () async {
      await store.write('k.txt', Uint8List.fromList([1]));
      await store.write('k.txt', Uint8List.fromList([2]));
      final result = await store.read('k.txt');
      expect(result, equals(Uint8List.fromList([2])));
    });
  });

  group('IoBlobStore', () {
    late Directory tempDir;
    late IoBlobStore store;

    setUp(() async {
      tempDir = Directory('${Directory.systemTemp.path}/scoreyomipm_blob_test_${DateTime.now().millisecondsSinceEpoch}');
      await tempDir.create(recursive: true);
      store = IoBlobStore(tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('書き込み後の読み取り（往復）', () async {
      await store.write('songs/popn/001.json', Uint8List.fromList([1, 2, 3]));
      final result = await store.read('songs/popn/001.json');
      expect(result, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('存在しないキーは null を返す', () async {
      final result = await store.read('songs/missing.json');
      expect(result, isNull);
    });

    test('exists は存在時 true、不在時 false', () async {
      await store.write('a/b.txt', Uint8List.fromList([0]));
      expect(await store.exists('a/b.txt'), isTrue);
      expect(await store.exists('a/c.txt'), isFalse);
    });

    test('listKeys は prefix でフィルタし昇順にソートする', () async {
      await store.write('songs/popn/001.json', Uint8List.fromList([1]));
      await store.write('songs/popn/002.json', Uint8List.fromList([2]));
      await store.write('songs/iidx/001.json', Uint8List.fromList([3]));
      await store.write('other/file.txt', Uint8List.fromList([4]));

      final result = await store.listKeys('songs/popn/');
      expect(result, equals(['songs/popn/001.json', 'songs/popn/002.json']));
    });

    test('delete でエントリを削除できる', () async {
      await store.write('temp/x.txt', Uint8List.fromList([1]));
      expect(await store.exists('temp/x.txt'), isTrue);
      await store.delete('temp/x.txt');
      expect(await store.exists('temp/x.txt'), isFalse);
    });

    test('deleteWhere は prefix 一致をすべて削除する', () async {
      await store.write('temp/1.txt', Uint8List.fromList([1]));
      await store.write('temp/2.txt', Uint8List.fromList([2]));
      await store.write('keep/3.txt', Uint8List.fromList([3]));
      await store.deleteWhere('temp/');
      expect(await store.exists('temp/1.txt'), isFalse);
      expect(await store.exists('temp/2.txt'), isFalse);
      expect(await store.exists('keep/3.txt'), isTrue);
    });

    test('キーに .. が含まれると ArgumentError を投げる', () async {
      expect(() => store.read('../etc/passwd'), throwsA(isA<ArgumentError>()));
      expect(() => store.write('../evil.txt', Uint8List.fromList([1])),
          throwsA(isA<ArgumentError>()));
      expect(() => store.delete('../secret.json'), throwsA(isA<ArgumentError>()));
      expect(() => store.exists('../x'), throwsA(isA<ArgumentError>()));
    });

    test('キーが絶対パスだと ArgumentError を投げる', () async {
      if (Platform.isWindows) {
        expect(() => store.read('C:\\Windows\\system32\\config\\sam'),
            throwsA(isA<ArgumentError>()));
      } else {
        expect(() => store.read('/etc/passwd'), throwsA(isA<ArgumentError>()));
      }
    });
  });
}
