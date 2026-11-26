// MemoTemplate のモデル単体テスト（JSON 往復・入力検証・trim 正規化）。
import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/data/memo_template.dart';

void main() {
  group('toJson / fromJson', () {
    test('往復で値が保たれる', () {
      const MemoTemplate template = MemoTemplate(
        id: 't1',
        title: '精度重視',
        body: '精度重視でプレイ',
      );

      final MemoTemplate restored = MemoTemplate.fromJson(template.toJson());

      expect(restored.id, 't1');
      expect(restored.title, '精度重視');
      expect(restored.body, '精度重視でプレイ');
    });

    test('id・title・body の前後空白は trim される', () {
      final MemoTemplate restored = MemoTemplate.fromJson(<String, dynamic>{
        'id': '  t1  ',
        'title': '  精度重視  ',
        'body': '\n 本文 \n',
      });

      expect(restored.id, 't1');
      expect(restored.title, '精度重視');
      expect(restored.body, '本文');
    });

    test('必須項目が欠けていたら FormatException', () {
      expect(
        () =>
            MemoTemplate.fromJson(<String, dynamic>{'id': 't1', 'title': '名前'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => MemoTemplate.fromJson(<String, dynamic>{
          'id': '',
          'title': 'a',
          'body': 'b',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => MemoTemplate.fromJson(<String, dynamic>{
          'id': 't1',
          'title': '  ',
          'body': 'b',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('copyWith', () {
    test('id は保ったまま title と body を差し替えられる', () {
      const MemoTemplate template = MemoTemplate(
        id: 't1',
        title: '旧',
        body: '旧本文',
      );

      final MemoTemplate updated = template.copyWith(title: '新', body: '新本文');

      expect(updated.id, 't1');
      expect(updated.title, '新');
      expect(updated.body, '新本文');
    });
  });

  group('validateTitle', () {
    test('空文字・空白のみ・null はエラー', () {
      expect(MemoTemplate.validateTitle(''), isNotNull);
      expect(MemoTemplate.validateTitle('   '), isNotNull);
      expect(MemoTemplate.validateTitle(null), isNotNull);
    });

    test('上限ちょうどは許容し、超過はエラー', () {
      final String maxTitle = 'あ' * MemoTemplate.titleMaxLength;

      expect(MemoTemplate.validateTitle(maxTitle), isNull);
      expect(
        MemoTemplate.validateTitle('あ' * (MemoTemplate.titleMaxLength + 1)),
        isNotNull,
      );
    });
  });

  group('validateBody', () {
    test('空文字・空白のみ・null はエラー', () {
      expect(MemoTemplate.validateBody(''), isNotNull);
      expect(MemoTemplate.validateBody('\n\n'), isNotNull);
      expect(MemoTemplate.validateBody(null), isNotNull);
    });

    test('上限ちょうどは許容し、超過はエラー', () {
      final String maxBody = 'あ' * MemoTemplate.bodyMaxLength;

      expect(MemoTemplate.validateBody(maxBody), isNull);
      expect(
        MemoTemplate.validateBody('あ' * (MemoTemplate.bodyMaxLength + 1)),
        isNotNull,
      );
    });
  });
}
