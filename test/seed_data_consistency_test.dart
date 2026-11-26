// ST-6 seed データ整合性テスト（TDD）
//
// WHY: 照合側（SongTitleMatcher）は OCR タイトルを normalizeSongTitle で
// 正規化したキーで辞書を引く。事前計算済み normalizedKey がこの関数の
// 出力から外れていると、正解曲名でも照合が失敗する。DB 更新時（配信
// ダウンロード・ローカル追加 DB）も同一の不変条件を守るための回帰テスト。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('seed_v2.json の normalizedKey は normalizeSongTitle の出力と一致する', () async {
    // タスク 01a20305: 同梱シードを seed_v2 に切替（notesCounts マップ化）。
    // 不変条件検証の対象は「アクティブに読まれるシード」であるべきなので
    // rootBundle（pubspec asset 登録の検証も兼ねる）で seed_v2 を読む。
    final jsonString = await rootBundle.loadString('assets/songs/seed_v2.json');
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final songsJson = json['songs'] as List<dynamic>;

    expect(songsJson, isNotEmpty);

    final mismatches = <String>[];
    for (final songJson in songsJson) {
      final entry = SongEntry.fromJson(songJson as Map<String, dynamic>);
      final expected = normalizeSongTitle(entry.title);
      if (entry.normalizedKey != expected) {
        mismatches.add(
          '${entry.id}: key=${entry.normalizedKey} expected=$expected',
        );
      }
    }

    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });
}
