// ST-1 画像分類・前処理: テスト画像の分類検証テスト
// testimage/playshare/ の既存 30 枚はすべて landscapePlayShare と分類され
// scr001-009 はすべて portraitWithEmbedded と分類される必要がある
// 1枚でも誤分類があると FAIL
//
// 画像パイプライン: Image (image パッケージ) を使用して画像を読み込み、
// 低解像度サムネイル（幅 ≤256px）で分類コストを削減

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/input_preprocessing.dart';

import 'support/image_fixture_skip.dart';

const String _playshareDir = 'testimage/playshare';
const String _acHcPhotoDir = 'testimage/AC-HC-photo';

const List<String> _allScrIds = <String>[
  'scr001',
  'scr002',
  'scr003',
  'scr004',
  'scr005',
  'scr006',
  'scr007',
  'scr008',
  'scr009',
];

/// scr ID からスクリーンショットのタイムスタンプを取得する
String _scrTimestamp(String id) {
  final timestamps = <String, String>{
    'scr001': '124336',
    'scr002': '124345',
    'scr003': '124356',
    'scr004': '124401',
    'scr005': '124405',
    'scr006': '124410',
    'scr007': '124414',
    'scr008': '124418',
    'scr009': '124421',
  };
  return timestamps[id] ?? '';
}

void main() {
  // 実画像が無い環境（公開リポジトリの clone など）では丸ごと skip する
  group('InputPreprocessor.classify 実データ回帰ガード（39枚全件）', () {
    test('既存30枚すべて landscapePlayShare と分類される（1枚でも誤分類なら FAIL）', () async {
      final preprocessor = InputPreprocessor();

      final dir = Directory(_playshareDir);
      final jpgFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(
        jpgFiles.length,
        equals(30),
        reason: 'testimage/playshare/ に JPG が 30 枚存在すること',
      );

      final misclassified = <String>[];
      for (final file in jpgFiles) {
        final id = _extractId(file);
        final actual = preprocessor.classify(file);
        if (actual != InputImageClass.landscapePlayShare) {
          misclassified.add('$id (${file.path}): $actual');
        }
      }

      if (misclassified.isNotEmpty) {
        fail(
          '誤分類あり ${misclassified.length} 枚: landscapePlayShare 以外が分類されました:\n'
          '${misclassified.join('\n')}',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('scr001-009 全9枚 portraitWithEmbedded と分類される（コンテンツ特徴は全9枚共通）', () async {
      final preprocessor = InputPreprocessor();

      final misclassified = <String>[];
      for (final id in _allScrIds) {
        final file = File(
          '$_playshareDir/Screenshot_20261122-${_scrTimestamp(id)}.png',
        );
        if (!file.existsSync()) {
          misclassified.add('$id: ファイルが存在しません');
          continue;
        }
        final actual = preprocessor.classify(file);
        if (actual != InputImageClass.portraitWithEmbedded) {
          misclassified.add('$id: 期待 portraitWithEmbedded, 実際 $actual');
        }
      }

      if (misclassified.isNotEmpty) {
        fail('scr 分類エラー:\n${misclassified.join('\n')}');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('AC-HC-photo 全30枚 arcadeResultFrame と分類される（縦 3:4 の2枚含む）', () async {
      final preprocessor = InputPreprocessor();

      final dir = Directory(_acHcPhotoDir);
      final jpgFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(
        jpgFiles.length,
        equals(30),
        reason: 'testimage/AC-HC-photo/ に JPG が 30 枚存在すること',
      );

      final misclassified = <String>[];
      for (final file in jpgFiles) {
        final id = file.uri.pathSegments.last;
        final actual = preprocessor.classify(file);
        if (actual != InputImageClass.arcadeResultFrame) {
          misclassified.add('$id (${file.path}): $actual');
        }
      }

      if (misclassified.isNotEmpty) {
        fail(
          'AC-HC-photo 分類エラー ${misclassified.length} 枚: arcadeResultFrame 以外が分類されました:\n'
          '${misclassified.join('\n')}',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipIfImagesMissing(<String>[_playshareDir, _acHcPhotoDir]));
}

/// ファイル名から ID を抽出する（形式: ..._media_【タイムスタンプ】_【ID】.jpg）
String _extractId(File file) {
  final name = file.uri.pathSegments.last;
  final parts = name.split('_');
  return parts.last.replaceAll('.jpg', '');
}
