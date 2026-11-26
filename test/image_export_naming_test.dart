// 原画像の「アプリ外に保存」で使う保存名・MIME タイプの純粋関数のテスト。
//
// WHY(分離): 保存名の組み立てと MIME 判定は画面の状態に依存しない純粋関数。
// 画面から切り出してここで直接検証する（画面ファイルの肥大化も避ける）。

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ui/image_export.dart';

void main() {
  final DateTime fixedNow = DateTime(2026, 11, 24, 9, 5);

  group('buildImageExportFileName', () {
    test('曲名あり: scoreyomipm_<曲名>_<yyyyMMdd>.<ext>', () {
      final String name = buildImageExportFileName(
        recordId: 'abcdefgh-1234',
        songName: 'テスト曲',
        imagePath: '/data/x/photo.PNG',
        now: fixedNow,
      );

      expect(name, 'scoreyomipm_テスト曲_20261124.png', reason: '拡張子は小文字化');
    });

    test('曲名なし: scoreyomipm_<recordId 先頭8>.<ext>（日付は付けない）', () {
      expect(
        buildImageExportFileName(
          recordId: 'abcdefgh-1234',
          songName: null,
          imagePath: '/data/x/photo.jpg',
          now: fixedNow,
        ),
        'scoreyomipm_abcdefgh.jpg',
      );
      expect(
        buildImageExportFileName(
          recordId: 'abc',
          songName: '   ',
          imagePath: '/data/x/photo.jpeg',
          now: fixedNow,
        ),
        'scoreyomipm_abc.jpeg',
        reason: '空白だけの曲名は「曲名なし」扱い（id は 8 文字未満ならそのまま）',
      );
    });

    test('ファイル名に使えない文字は _ に置換する', () {
      final String name = buildImageExportFileName(
        recordId: 'r-1',
        songName: r'a/b\c:d*e?f"g<h>i|j',
        imagePath: '/data/x/photo.jpg',
        now: fixedNow,
      );

      expect(name, 'scoreyomipm_a_b_c_d_e_f_g_h_i_j_20261124.jpg');
    });
  });

  group('mimeTypeForImagePath', () {
    test('拡張子から MIME タイプを決める', () {
      expect(mimeTypeForImagePath('/a/b.jpg'), 'image/jpeg');
      expect(mimeTypeForImagePath('/a/b.JPEG'), 'image/jpeg');
      expect(mimeTypeForImagePath('/a/b.png'), 'image/png');
      expect(mimeTypeForImagePath('/a/b.webp'), 'application/octet-stream');
      expect(mimeTypeForImagePath('/a/b'), 'application/octet-stream');
    });
  });
}
