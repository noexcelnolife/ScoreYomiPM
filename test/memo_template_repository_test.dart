// FileMemoTemplateRepository の単体テスト（一時ディレクトリで実ファイル I/O）。
//
// 永続化の要点は records.json と揃えている: tmp→rename のアトミック書き込み、
// 破損ファイルの退避、1 件単位の不正要素スキップ、削除の冪等性。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/data/memo_template_repository.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memo_template_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  FileMemoTemplateRepository createRepository() {
    return FileMemoTemplateRepository(
      documentsDirectoryResolver: () async => tempDir,
    );
  }

  File templatesFile() => File('${tempDir.path}/memo_templates/templates.json');

  group('listAll', () {
    test('ファイルが無ければ空リスト', () async {
      final FileMemoTemplateRepository repository = createRepository();

      expect(await repository.listAll(), isEmpty);
    });
  });

  group('add', () {
    test('追加した順に並び、値は trim される', () async {
      final FileMemoTemplateRepository repository = createRepository();

      final MemoTemplate first = await repository.add(
        title: '  精度重視  ',
        body: '  精度重視でプレイ  ',
      );
      await repository.add(title: '要復習', body: '要復習: ');

      final List<MemoTemplate> all = await repository.listAll();

      expect(all.map((MemoTemplate t) => t.title), <String>['精度重視', '要復習']);
      expect(all.first.body, '精度重視でプレイ');
      expect(first.id, isNotEmpty);
    });

    test('id は衝突しない', () async {
      final FileMemoTemplateRepository repository = createRepository();

      final MemoTemplate a = await repository.add(title: 'A', body: 'a');
      final MemoTemplate b = await repository.add(title: 'B', body: 'b');

      expect(a.id, isNot(b.id));
    });

    test('保存後に同じインスタンスで読み直せる（永続化されている）', () async {
      await createRepository().add(title: 'A', body: 'a');

      final List<MemoTemplate> reloaded = await createRepository().listAll();

      expect(reloaded, hasLength(1));
      expect(reloaded.single.title, 'A');
    });
  });

  group('update', () {
    test('既存 1 件を差し替える（件数は変わらない）', () async {
      final FileMemoTemplateRepository repository = createRepository();
      final MemoTemplate template = await repository.add(
        title: '旧',
        body: '旧本文',
      );

      await repository.update(template.copyWith(title: '新', body: '新本文'));

      final List<MemoTemplate> all = await repository.listAll();
      expect(all, hasLength(1));
      expect(all.single.id, template.id);
      expect(all.single.title, '新');
      expect(all.single.body, '新本文');
    });

    test('未知の id は StateError', () async {
      final FileMemoTemplateRepository repository = createRepository();
      await repository.add(title: 'A', body: 'a');

      expect(
        () => repository.update(
          const MemoTemplate(id: 'missing', title: 'x', body: 'y'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('delete', () {
    test('指定 id だけが消える', () async {
      final FileMemoTemplateRepository repository = createRepository();
      final MemoTemplate keep = await repository.add(title: '残す', body: 'a');
      final MemoTemplate remove = await repository.add(title: '消す', body: 'b');

      await repository.delete(remove.id);

      final List<MemoTemplate> all = await repository.listAll();
      expect(all.map((MemoTemplate t) => t.id), <String>[keep.id]);
    });

    test('未知の id でも例外にならない（冪等）', () async {
      final FileMemoTemplateRepository repository = createRepository();
      await repository.add(title: 'A', body: 'a');

      await repository.delete('missing');
      await repository.delete('missing');

      expect(await repository.listAll(), hasLength(1));
    });
  });

  group('破損ファイル', () {
    test('JSON として壊れていたら退避して空リストを返す', () async {
      final FileMemoTemplateRepository repository = createRepository();
      templatesFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('{ broken json');

      expect(await repository.listAll(), isEmpty);

      final List<String> corrupt = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((File file) => file.path)
          .where((String path) => path.contains('.corrupt.'))
          .toList();
      expect(corrupt, hasLength(1));
    });

    test('配列でない JSON も退避して空リスト', () async {
      final FileMemoTemplateRepository repository = createRepository();
      templatesFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('{"templates": []}');

      expect(await repository.listAll(), isEmpty);
    });

    test('不正な要素は 1 件だけスキップし、正常な要素は読める', () async {
      final FileMemoTemplateRepository repository = createRepository();
      templatesFile()
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(<dynamic>[
            <String, dynamic>{'id': 'ok', 'title': '正常', 'body': '本文'},
            <String, dynamic>{'id': 'bad', 'title': '', 'body': '本文'},
            'not a map',
          ]),
        );

      final List<MemoTemplate> all = await repository.listAll();

      expect(all, hasLength(1));
      expect(all.single.id, 'ok');
    });
  });

  group('mergeAll', () {
    test('空リストなら何も書かず 0 を返す', () async {
      final FileMemoTemplateRepository repository = createRepository();

      expect(await repository.mergeAll(<MemoTemplate>[]), 0);
      expect(await templatesFile().exists(), isFalse);
    });

    test('既存と重ならないものだけを追加し、件数を返す', () async {
      final FileMemoTemplateRepository repository = createRepository();
      final MemoTemplate existing = await repository.add(
        title: '既存',
        body: '既存の本文',
      );

      final int added = await repository.mergeAll(<MemoTemplate>[
        existing,
        const MemoTemplate(id: 'zip-1', title: '取り込み', body: '取り込み本文'),
        const MemoTemplate(id: 'zip-1', title: '重複', body: 'ZIP 内の重複'),
      ]);

      final List<MemoTemplate> all = await repository.listAll();

      // 既存 id と ZIP 内の重複 id の両方を落とし、増えるのは 1 件だけ。
      expect(added, 1);
      expect(all.map((MemoTemplate t) => t.id), <String>[existing.id, 'zip-1']);
      expect(all.first.title, '既存');
      expect(all.last.body, '取り込み本文');
    });

    test('同じリストを 2 回流しても増えない', () async {
      final FileMemoTemplateRepository repository = createRepository();
      const List<MemoTemplate> incoming = <MemoTemplate>[
        MemoTemplate(id: 'zip-1', title: '取り込み', body: '本文'),
      ];

      expect(await repository.mergeAll(incoming), 1);
      expect(await repository.mergeAll(incoming), 0);
      expect(await repository.listAll(), hasLength(1));
    });

    test('保存後に .tmp が残らない（追記も 1 回の書き込みで行う）', () async {
      final FileMemoTemplateRepository repository = createRepository();
      await repository.add(title: '既存', body: '本文');

      await repository.mergeAll(<MemoTemplate>[
        const MemoTemplate(id: 'zip-1', title: 'A', body: 'a'),
        const MemoTemplate(id: 'zip-2', title: 'B', body: 'b'),
      ]);

      final File tmp = File('${templatesFile().path}.tmp');

      expect(await tmp.exists(), isFalse);
      expect(await repository.listAll(), hasLength(3));
    });

    test('破損ファイルは退避したうえで追記する', () async {
      final FileMemoTemplateRepository repository = createRepository();
      templatesFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('{壊れた');

      final int added = await repository.mergeAll(<MemoTemplate>[
        const MemoTemplate(id: 'zip-1', title: '取り込み', body: '本文'),
      ]);

      expect(added, 1);
      expect(await repository.listAll(), hasLength(1));
    });
  });

  group('アトミック書き込み', () {
    test('保存後に .tmp が残らない', () async {
      final FileMemoTemplateRepository repository = createRepository();
      await repository.add(title: 'A', body: 'a');

      final File tmp = File('${templatesFile().path}.tmp');
      expect(await tmp.exists(), isFalse);
      expect(await templatesFile().exists(), isTrue);
    });
  });
}
