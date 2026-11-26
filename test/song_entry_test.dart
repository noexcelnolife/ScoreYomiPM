// ST-6 楽曲エントリテスト（TDD）

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ocr/song_entry.dart';

void main() {
  group('SongEntry.fromJson', () {
    test('有効なJSONから構築', () {
      final entry = SongEntry.fromJson({
        'id': 'test_001',
        'title': 'Test Song',
        'normalizedKey': 'testsong',
        'genre': 'TestGenre',
        'artist': 'TestArtist',
        'levels': {'EX': 50, 'LIGHT': 10},
        'notesCounts': {'EX': 1000},
        'version': 'Test Version',
      });

      expect(entry.id, equals('test_001'));
      expect(entry.title, equals('Test Song'));
      expect(entry.normalizedKey, equals('testsong'));
      expect(entry.genre, equals('TestGenre'));
      expect(entry.artist, equals('TestArtist'));
      expect(entry.levels, equals({'EX': 50, 'LIGHT': 10}));
      // WHY getter 合成（リード最終裁定 01a2030b）: JSON に totalNotes キーは
      // 無く、notesCounts 非空なら max(notesCounts.values) を返す。
      expect(entry.totalNotes, equals(1000));
      expect(entry.notesCountFor('EX'), equals(1000));
      expect(entry.version, equals('Test Version'));
    });

    test('normalizedKey が省略時は title から自動導出', () {
      final entry = SongEntry.fromJson({'id': 'test_002', 'title': 'ＡＢＣ１２３'});

      expect(entry.normalizedKey, equals('abc123'));
    });

    test('id が空欄で ArgumentError', () {
      expect(
        () => SongEntry.fromJson({'id': '', 'title': 'Test'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('title が空欄で ArgumentError', () {
      expect(
        () => SongEntry.fromJson({'id': 'test_003', 'title': ''}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('id が null で ArgumentError', () {
      expect(
        () => SongEntry.fromJson({'title': 'Test'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('normalizedKey が空欄で ArgumentError', () {
      expect(
        () => SongEntry.fromJson({
          'id': 'test_004',
          'title': 'Test',
          'normalizedKey': '',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('オプションフィールド欠如でも構築可能', () {
      final entry = SongEntry.fromJson({
        'id': 'test_005',
        'title': 'Minimal Song',
      });

      expect(entry.genre, isNull);
      expect(entry.artist, isNull);
      expect(entry.levels, isEmpty);
      expect(entry.totalNotes, isNull);
      expect(entry.notesCountFor('EX'), isNull);
      expect(entry.version, isNull);
    });

    test('notesCounts 複数難易度をマップで保持', () {
      // WHY: Harmonia のように LIGHT と EX の両方が判明している曲は
      // 単一値では表現できない（seed_v2 規約: 欠落キーは null 埋めせず省略）。
      final entry = SongEntry.fromJson({
        'id': 'test_006',
        'title': 'Harmonia',
        'normalizedKey': 'harmonia',
        'notesCounts': {'LIGHT': 135, 'EX': 1036},
      });

      expect(entry.notesCountFor('LIGHT'), equals(135));
      expect(entry.notesCountFor('EX'), equals(1036));
      // 未収集難易度は null（FR-6 VR-1/VR-3 では skip 扱い）。
      expect(entry.notesCountFor('NORMAL'), isNull);
      expect(entry.notesCountFor('HYPER'), isNull);
    });

    test('notesCounts の文字列値は int として受理', () {
      final entry = SongEntry.fromJson({
        'id': 'test_007',
        'title': 'Test',
        'notesCounts': {'EX': '1036'},
      });

      expect(entry.notesCountFor('EX'), equals(1036));
    });

    test('notesCounts の 0 以下・非パース値はキーごと省略', () {
      // WHY: VR-1 は notesCount >= count の比較のため、0 を受理すると
      // 検証が常に通過してしまう。不正値はデータ不在（skip）に倒す。
      final entry = SongEntry.fromJson({
        'id': 'test_008',
        'title': 'Test',
        'notesCounts': {'EX': 0, 'HYPER': -5, 'NORMAL': 'abc'},
      });

      expect(entry.notesCountFor('EX'), isNull);
      expect(entry.notesCountFor('HYPER'), isNull);
      expect(entry.notesCountFor('NORMAL'), isNull);
      expect(entry.notesCounts, isEmpty);
    });

    test('notesCountFor の未知難易度は null', () {
      final entry = SongEntry.fromJson({
        'id': 'test_009',
        'title': 'Test',
        'notesCounts': {'EX': 1000},
      });

      expect(entry.notesCountFor('UPPER'), isNull);
    });

    test('v1/main_v1 由来の legacy totalNotes のみのデータを救済', () {
      // WHY legacy 読み込み復活（リード最終裁定 01a2030b）: db/popn_hc_main_v1.json
      // の 135 曲は totalNotes のみで notesCounts を持たない。fromJson がこの
      // キーを黙って捨てると 135 曲分のノーツデータが喪失するため、private
      // フィールドに保持し getter 経由で返す（VR-1 も機能し続ける）。
      final entry = SongEntry.fromJson({
        'id': 'test_010',
        'title': 'Legacy Song',
        'totalNotes': 1500,
      });

      expect(entry.totalNotes, equals(1500));
      expect(entry.notesCounts, isEmpty);
    });

    test('legacy totalNotes の文字列値も寛容パース', () {
      final entry = SongEntry.fromJson({
        'id': 'test_011',
        'title': 'Legacy Song 2',
        'totalNotes': '1500',
      });

      expect(entry.totalNotes, equals(1500));
    });

    test('legacy totalNotes が 0 以下は null（データ不在扱い）', () {
      // WHY: VR-1 が 0 を受理すると上限チェックが常に通過する防御
      // （リード裁定 01a20308 承認事項の notesCounts 規約と対になる）。
      final zero = SongEntry.fromJson({
        'id': 'test_012',
        'title': 'Legacy Song 3',
        'totalNotes': 0,
      });
      final negative = SongEntry.fromJson({
        'id': 'test_013',
        'title': 'Legacy Song 4',
        'totalNotes': -5,
      });

      expect(zero.totalNotes, isNull);
      expect(negative.totalNotes, isNull);
    });
  });

  group('SongEntry.toJson', () {
    test('全フィールドシリアライズ（notesCounts 非空なら totalNotes は出さない）', () {
      final entry = SongEntry(
        id: 'test_006',
        title: 'Test Song',
        normalizedKey: 'testsong',
        genre: 'TestGenre',
        artist: 'TestArtist',
        levels: {'EX': 50},
        notesCounts: {'EX': 1000},
        version: 'Test Version',
      );

      final json = entry.toJson();
      expect(json['id'], equals('test_006'));
      expect(json['title'], equals('Test Song'));
      expect(json['normalizedKey'], equals('testsong'));
      expect(json['genre'], equals('TestGenre'));
      expect(json['artist'], equals('TestArtist'));
      expect(json['levels'], equals({'EX': 50}));
      // WHY 条件付き出力（リード最終裁定 01a2030b）: seed_v2 由来の曲に旧キー
      // totalNotes を広げない（getter 合成値は JSON 永続化しない）。
      expect(json.containsKey('totalNotes'), isFalse);
      expect(json['notesCounts'], equals({'EX': 1000}));
      expect(json['version'], equals('Test Version'));
    });

    test('legacy のみの曲は totalNotes を出力（main_v1 往復無損失）', () {
      final entry = SongEntry.fromJson({
        'id': 'test_014',
        'title': 'Legacy Song 5',
        'totalNotes': 1500,
      });

      final json = entry.toJson();
      expect(json['totalNotes'], equals(1500));
      expect(json.containsKey('notesCounts'), isFalse);

      // fromJson → toJson 往復で無損失（main_v1 再書き出し互換）。
      final reparsed = SongEntry.fromJson(json);
      expect(reparsed.totalNotes, equals(1500));
    });

    test('null フィールドは除外', () {
      final entry = SongEntry(
        id: 'test_007',
        title: 'Test Song',
        normalizedKey: 'testsong',
      );

      final json = entry.toJson();
      expect(json.containsKey('genre'), isFalse);
      expect(json.containsKey('artist'), isFalse);
      expect(json.containsKey('notesCounts'), isFalse);
      expect(json.containsKey('totalNotes'), isFalse);
      expect(json.containsKey('version'), isFalse);
    });

    test('空 levels は除外', () {
      final entry = SongEntry(
        id: 'test_008',
        title: 'Test Song',
        normalizedKey: 'testsong',
        levels: {},
      );

      final json = entry.toJson();
      expect(json.containsKey('levels'), isFalse);
    });
  });

  group('SongEntry equality', () {
    test('同じ id/title/normalizedKey は等しい', () {
      final a = SongEntry(id: 'id1', title: 'Title', normalizedKey: 'key');
      final b = SongEntry(id: 'id1', title: 'Title', normalizedKey: 'key');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('異なる id は等しくない', () {
      final a = SongEntry(id: 'id1', title: 'Title', normalizedKey: 'key');
      final b = SongEntry(id: 'id2', title: 'Title', normalizedKey: 'key');
      expect(a, isNot(equals(b)));
    });
  });

  group('SongDictionaryView', () {
    test('エントリリストからビューを構築', () {
      final entries = <SongEntry>[
        SongEntry(id: '1', title: 'Song A', normalizedKey: 'songa'),
        SongEntry(id: '2', title: 'Song B', normalizedKey: 'songb'),
        SongEntry(id: '3', title: 'Song C', normalizedKey: 'songc'),
      ];
      final view = SongDictionaryView(entries);

      expect(view.length, equals(3));
      expect(view.titles, contains('songa'));
      expect(view.titles, contains('songb'));
      expect(view.titles, contains('songc'));
    });

    test('originalTitle で元表記を取得', () {
      final entries = <SongEntry>[
        SongEntry(
          id: '1',
          title: 'Original Title',
          normalizedKey: 'originaltitle',
        ),
      ];
      final view = SongDictionaryView(entries);

      expect(view.originalTitle('originaltitle'), equals('Original Title'));
      expect(view.originalTitle('nonexistent'), isNull);
    });

    test('contains で存在確認', () {
      final entries = <SongEntry>[
        SongEntry(id: '1', title: 'Song A', normalizedKey: 'songa'),
      ];
      final view = SongDictionaryView(entries);

      expect(view.contains('songa'), isTrue);
      expect(view.contains('nonexistent'), isFalse);
    });

    test('重複 normalizedKey は1つだけ titles に含まれる', () {
      final entries = <SongEntry>[
        SongEntry(id: '1', title: 'Song A', normalizedKey: 'songa'),
        SongEntry(id: '2', title: 'Song A v2', normalizedKey: 'songa'),
      ];
      final view = SongDictionaryView(entries);

      expect(view.length, equals(1));
      expect(view.titles, hasLength(1));
    });
  });

  group('SongEntry × seed_v2 統合（totalNotes getter 合成）', () {
    // WHY 実 asset 読込（リード最終裁定 01a2030b・テスト要件①②）:
    // seed_v2.json に totalNotes キーは無いため、fromJson → getter で
    // max(notesCounts.values) が合成されることを全33曲で検証する。
    // これが FR-6 段階 B VR-1（S > totalNotes）が全曲 skip しない保証。
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    Future<List<SongEntry>> loadSeedV2Entries() async {
      final raw = await rootBundle.loadString('assets/songs/seed_v2.json');
      final songs =
          (jsonDecode(raw) as Map<String, dynamic>)['songs'] as List<dynamic>;
      return songs
          .map((s) => SongEntry.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    test(
      '①全33曲で getter totalNotes が非null 且つ max(notesCounts.values) と一致',
      () async {
        final entries = await loadSeedV2Entries();
        expect(entries, hasLength(33));

        final problems = <String>[];
        for (final entry in entries) {
          final totalNotes = entry.totalNotes;
          if (totalNotes is! int || totalNotes <= 0) {
            problems.add('${entry.id}: totalNotes が正の int でない: $totalNotes');
            continue;
          }
          final maxNotes = entry.notesCounts.values.reduce(
            (a, b) => a > b ? a : b,
          );
          if (totalNotes != maxNotes) {
            problems.add(
              '${entry.id}: totalNotes=$totalNotes != max=$maxNotes',
            );
          }
        }
        expect(problems, isEmpty, reason: problems.join('\n'));
      },
    );

    test('②Harmonia の getter totalNotes は 1036（EX）', () async {
      final entries = await loadSeedV2Entries();
      final harmonia = entries.firstWhere(
        (e) => e.normalizedKey == 'harmonia',
        orElse: () => throw StateError('Harmonia が seed_v2 に存在しない'),
      );

      // WHY 1036 固定: 収集ドキュメントの Harmonia EX ノーツ数（LIGHT 135 は
      // max 計算で EX 1036 に負けることの確認も兼ねる）。
      expect(harmonia.notesCounts, equals({'LIGHT': 135, 'EX': 1036}));
      expect(harmonia.totalNotes, equals(1036));
    });
  });
}
