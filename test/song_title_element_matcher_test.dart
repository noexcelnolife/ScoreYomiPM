// ST-5 本実装: 曲名照合の genre 行混入対策（要素単位照合）のテスト。
//
// 実 fixture（playshare_region_ocr_results.json）の要素構造を固定値として
// 再現し、「行クラスタリング → 行内連結 → 最良距離照合」を検証する。
// 背景: 曲名バンドのクロップにはジャンル行（例 SOFT ROCK LONG）と曲名行が
// 同写りになり、従来の全文 join 照合はジャンル接頭辞で距離が膨らみ
// 自動決定が破綻する（実測: join 全文 0/7 vs 行単位 5/7、QA-Docs
// docs/st5_title_matching_verification_plan.md）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/bundled_seed_repository.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_element_matcher.dart';
import 'package:scoreyomipm/ocr/song_title_matcher.dart';

/// テスト用 SongRepository（タイブレーク検証用の小さな辞書）。
class _FakeSongRepository implements SongRepository {
  final List<SongEntry> songs;

  _FakeSongRepository({required this.songs});

  @override
  String get sourceName => 'fake';

  @override
  bool get isAvailable => songs.isNotEmpty;

  @override
  List<SongEntry> get allSongs => List.unmodifiable(songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final entry in songs) {
      if (entry.normalizedKey == normalizedKey) {
        return entry;
      }
    }
    return null;
  }

  @override
  int get length => songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      songs.any((e) => e.normalizedKey == normalizedKey);
}

/// usnb54 の songTitle 帯（実 fixture 値・crop 1200x114）。
///
/// genre 行 [SOFT|ROCIK|LONG]（t24-67）+ 曲名行 [Homesiok|Pt.2&3]（t84-114）。
List<OcrElement> _usnb54Elements() => [
  _el('SOFT', 552, 24, 658, 67),
  _el('ROCIK', 666, 24, 773, 67),
  _el('LONG', 788, 24, 892, 67),
  _el('Homesiok', 556, 84, 698, 114),
  _el('Pt.2&3', 709, 84, 814, 114),
];

/// 3490q2 の songTitle 帯（実 fixture 値・crop 1200x113）。
///
/// genre 行 [PET|DRUMHN|COREDUST2]（t31-74）と曲名行（t68-110）の
/// 行高（bbox）が重なるケース。
List<OcrElement> _q2Elements() => [
  _el('PET', 556, 37, 588, 68),
  _el('DRUMHN', 684, 31, 780, 70),
  _el('COREDUST2', 809, 34, 977, 74),
  _el('ラビストアの物京', 666, 68, 946, 110),
];

OcrElement _el(String text, double l, double t, double r, double b) =>
    OcrElement(
      text: text,
      boundingBox: Rect.fromLTRB(l, t, r, b),
      confidence: 0.8,
    );

Future<SongTitleElementMatcher> _matcherWithSeed() async {
  final seed = BundledSeedRepository();
  await seed.load();
  return SongTitleElementMatcher(SongTitleMatcher(seed));
}

void main() {
  // WHY: 実 fixture 回帰テストが rootBundle（bundledSeed アセット）を読むため
  // 素の test() では TestWidgetsFlutterBinding の初期化が必須。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clusterRows', () {
    test('空要素リストは空を返す', () {
      expect(SongTitleElementMatcher.clusterRows(const []), isEmpty);
    });

    test('単一要素は1行1要素', () {
      final rows = SongTitleElementMatcher.clusterRows([
        _el('朧', 100, 80, 140, 110),
      ]);
      expect(rows.length, 1);
      expect(rows[0].length, 1);
    });

    test('同一行に分割された曲名は1行にまとまる（bt2qlc 型・実 fixture 値）', () {
      final rows = SongTitleElementMatcher.clusterRows([
        _el('イ9Yonkey', 669, 77, 867, 120),
        _el('Business|', 876, 75, 1015, 117),
      ]);
      expect(rows.length, 1);
      // 行内は左→右順に並ぶ
      expect(rows[0][0].text, 'イ9Yonkey');
      expect(rows[0][1].text, 'Business|');
    });

    test('genre 行と曲名行は2行に分かれる（usnb54 型・実 fixture 値）', () {
      final rows = SongTitleElementMatcher.clusterRows(_usnb54Elements());
      expect(rows.length, 2);
      expect(rows[0].map((e) => e.text).toList(), ['SOFT', 'ROCIK', 'LONG']);
      expect(rows[1].map((e) => e.text).toList(), ['Homesiok', 'Pt.2&3']);
    });

    test('行高（bbox）が重なる場合も中心Yで分離する（3490q2 型・実 fixture 値）', () {
      final rows = SongTitleElementMatcher.clusterRows(_q2Elements());
      expect(rows.length, 2);
      expect(rows[0].map((e) => e.text).toList(), [
        'PET',
        'DRUMHN',
        'COREDUST2',
      ]);
      expect(rows[1].map((e) => e.text).toList(), ['ラビストアの物京']);
    });
  });

  group('candidateTexts', () {
    test('genre 行+曲名行で「行連結 → 単一要素」の順に候補を生成する（usnb54 型）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: const [])),
      );
      expect(matcher.candidateTexts(_usnb54Elements()), [
        'SOFT ROCIK LONG',
        'SOFT',
        'ROCIK',
        'LONG',
        'Homesiok Pt.2&3',
        'Homesiok',
        'Pt.2&3',
      ]);
    });

    test('単一要素の行は重複候補を生成しない', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: const [])),
      );
      expect(matcher.candidateTexts([_el('朧', 100, 80, 140, 110)]), ['朧']);
    });

    test('空白のみの要素は候補から除外される', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: const [])),
      );
      expect(
        matcher.candidateTexts([
          _el('   ', 10, 20, 30, 40),
          _el('朧', 100, 80, 140, 110),
        ]),
        ['朧'],
      );
    });
  });

  group('match', () {
    test('genre 行混入画像（usnb54 実fixture値）で曲名行を自動決定する', () async {
      final result = await _matcherWithSeed().then(
        (m) => m.match(_usnb54Elements()),
      );
      expect(result.bestMatchOriginal, 'Homesick Pt.2&3');
      expect(result.bestDistance, 1);
      expect(result.autoDecided, isTrue);
      // rawOcrText は採用候補の生テキスト（genre 行を含まない）
      expect(result.rawOcrText, 'Homesiok Pt.2&3');
    });

    test('単一行に分割された曲名を連結して自動決定する（bt2qlc 型レイアウト）', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(
            id: 's1',
            title: 'New Song Extra',
            normalizedKey: 'newsongextra',
          ),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match([
        _el('New Song', 669, 77, 867, 120),
        _el('Extra', 876, 75, 1015, 117),
      ]);
      expect(result.bestMatchOriginal, 'New Song Extra');
      expect(result.bestDistance, 0);
      expect(result.autoDecided, isTrue);
    });

    test('同距離では正規化テキストが長い候補を優先する', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(id: 's1', title: 'ab', normalizedKey: 'ab'),
          SongEntry(id: 's2', title: 'abcd', normalizedKey: 'abcd'),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match([
        _el('ab', 100, 20, 140, 60),
        _el('abcd', 100, 90, 160, 120),
      ]);
      expect(result.bestMatchOriginal, 'abcd');
      expect(result.bestDistance, 0);
    });

    test('同距離・同長では画面下側の行を優先する（曲名行は genre 行より下）', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(id: 's1', title: 'Song A', normalizedKey: 'songa'),
          SongEntry(id: 's2', title: 'Song B', normalizedKey: 'songb'),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match([
        _el('Song A', 100, 20, 160, 60),
        _el('Song B', 100, 90, 160, 130),
      ]);
      expect(result.bestMatchOriginal, 'Song B');
    });

    test('全候補不一致時は全文 join にフォールバックする（従来動作・FR-3 表示用保全）', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(
            id: 's1',
            title: 'Totally Other Song',
            normalizedKey: 'totallyothersong',
          ),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match(_q2Elements());
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, 'PET DRUMHN COREDUST2 ラビストアの物京');
    });

    test('空白のみの要素は照合せず不一致結果を返す', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(
            id: 's1',
            title: 'Homesick Pt.2&3',
            normalizedKey: 'homesickpt.2&3',
          ),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match([_el('   ', 10, 20, 30, 40)]);
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, '');
    });

    test('空要素リストは不一致結果を返す', () {
      final repo = _FakeSongRepository(
        songs: const [
          SongEntry(
            id: 's1',
            title: 'Homesick Pt.2&3',
            normalizedKey: 'homesickpt.2&3',
          ),
        ],
      );
      final matcher = SongTitleElementMatcher(SongTitleMatcher(repo));
      final result = matcher.match(const []);
      expect(result.hasMatch, isFalse);
    });
  });

  group('最小長ガード（ST-5 フェーズ2-E）', () {
    // WHY: r3 実測で短い無関係要素が短い辞書キー（朧/o†o/oort は 1〜4 字）に
    // dist≤3 で誤マッチし曲名候補を crowd-out する実害が 9 枚観測された
    // （行連結 4+単一 5）。ガード適用後は候補不一致扱いとなり全文 join
    // フォールバックへ転落する（FR-3 rawOcrText 保全・誤候補排除）。
    // 詳細: docs/st5_e_min_length_guard_design_confirmation_2026-11-22.md
    final ooboroRepo = [
      SongEntry(id: 'e1', title: '朧', normalizedKey: '朧'),
      SongEntry(id: 'e2', title: 'o†o', normalizedKey: 'o†o'),
      SongEntry(id: 'e3', title: 'Oort', normalizedKey: 'oort'),
    ];

    test('g7p9b2 型: 短い単独行 EX は朧/o†o に誤マッチせず不一致になる（red）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [
              SongEntry(id: 'e1', title: '朧', normalizedKey: '朧'),
              SongEntry(id: 'e2', title: 'o†o', normalizedKey: 'o†o'),
            ],
          ),
        ),
      );
      final result = matcher.match([
        _el('EX', 100, 20, 160, 50),
        _el('RCEMETAL', 100, 90, 220, 120),
      ]);
      expect(result.hasMatch, isFalse);
      // WHY: fallback の全文 join で FR-3 表示用 rawOcrText が保全されること
      expect(result.rawOcrText, 'EX RCEMETAL');
    });

    test('3490q2 型: ジャンル断片 PET は短キー群に誤マッチせず不一致になる（red）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: List.of(ooboroRepo))),
      );
      final result = matcher.match(_q2Elements());
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, 'PET DRUMHN COREDUST2 ラビストアの物京');
    });

    test('12h1bb 型: 4 字断片 CORE は oort（dist2）に誤マッチせず不一致になる（red）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [
              SongEntry(id: 'e1', title: 'Oort', normalizedKey: 'oort'),
            ],
          ),
        ),
      );
      final result = matcher.match([
        _el('PaoIC', 550, 30, 660, 70),
        _el('CORE', 680, 30, 760, 70),
      ]);
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, 'PaoIC CORE');
    });

    test('124410 型: 1 字断片 M と 2 字行 ルカ は朧に誤マッチせず不一致になる（red）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: List.of(ooboroRepo))),
      );
      final result = matcher.match([
        _el('M', 550, 30, 590, 70),
        _el('TARIÚ', 610, 30, 730, 70),
        _el('ルカ', 600, 95, 700, 135),
      ]);
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, 'M TARIÚ ルカ');
    });

    test('r7uamp 型: 3 字行 PEI（dist3）と 2 字断片 UP は朧に誤マッチせず不一致になる（red）', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [SongEntry(id: 'e1', title: '朧', normalizedKey: '朧')],
          ),
        ),
      );
      final result = matcher.match([
        _el('PEI', 550, 30, 620, 70),
        _el('UP', 550, 95, 610, 135),
        _el('ZETAと', 630, 95, 760, 135),
      ]);
      expect(result.hasMatch, isFalse);
      expect(result.rawOcrText, 'PEI UP ZETAと');
    });

    test('green pin: 完全一致（dist0）は最小長に関係なく採用される', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [SongEntry(id: 'e1', title: '朧', normalizedKey: '朧')],
          ),
        ),
      );
      final result = matcher.match([_el('朧', 100, 80, 140, 110)]);
      expect(result.bestMatchOriginal, '朧');
      expect(result.bestDistance, 0);
      expect(result.autoDecided, isTrue);
    });

    test('green pin（KPI 保持の核）: oto は o†o(1) で採用・自動決定はしない', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(_FakeSongRepository(songs: List.of(ooboroRepo))),
      );
      final result = matcher.match([_el('oto', 100, 80, 160, 110)]);
      expect(result.bestMatchOriginal, 'o†o');
      expect(result.bestDistance, 1);
      // WHY: o†o は 3 字キーのため topK に oort(2)・朧(3) が並ぶ → 3 件で
      // 自動決定条件（topK==1）を満たさない。この挙動は KPI 上正当であり
      // ガード導入で変えてはいけない（リード承認条件 3）。
      expect(result.autoDecided, isFalse);
    });

    test('green pin: 朧1（2 字・dist1）は行連結候補として採用され自動決定される', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [SongEntry(id: 'e1', title: '朧', normalizedKey: '朧')],
          ),
        ),
      );
      final result = matcher.match([_el('朧1', 100, 80, 160, 110)]);
      expect(result.bestMatchOriginal, '朧');
      expect(result.bestDistance, 1);
      expect(result.autoDecided, isTrue);
    });

    test('green pin: 複数要素行の中の完全一致単一要素（朧+XX）は dist0 で採用される', () {
      final matcher = SongTitleElementMatcher(
        SongTitleMatcher(
          _FakeSongRepository(
            songs: const [SongEntry(id: 'e1', title: '朧', normalizedKey: '朧')],
          ),
        ),
      );
      final result = matcher.match([
        _el('朧', 550, 30, 590, 70),
        _el('XX', 610, 30, 670, 70),
      ]);
      expect(result.bestMatchOriginal, '朧');
      expect(result.bestDistance, 0);
      expect(result.autoDecided, isTrue);
    });
  });

  group('実 fixture 回帰（ST-5 KPI ガード）', () {
    test('songTitle 要素あり 7 枚のうち 5 枚以上が自動決定し、決定曲は全て Homesick Pt.2&3', () async {
      final fixture = jsonDecode(
        File('test/fixtures/ocr/playshare_region_ocr_results.json')
            .readAsStringSync(),
      ) as List<dynamic>;

      final matcher = await _matcherWithSeed();
      final matched = <String, SongMatchResult>{};
      for (final item in fixture.cast<Map<String, dynamic>>()) {
        // fixture には file/regions が null のサマリー的要素が含まれるためスキップ
        final file = item['file'];
        final regionsRaw = item['regions'];
        if (file is! String || regionsRaw is! List) {
          continue;
        }
        final regions = regionsRaw.cast<Map<String, dynamic>>();
        final songTitleRegions = regions
            .where((r) => r['target'] == 'songTitle')
            .toList();
        if (songTitleRegions.isEmpty) {
          continue;
        }
        final elements = ((songTitleRegions.first['elements'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(_elementFromJson)
            .toList();
        if (elements.isEmpty) {
          continue;
        }
        matched[file] = matcher.match(elements);
      }

      expect(matched.length, 7, reason: 'songTitle 要素ありは実測 7/30 枚');
      final autoDecided = matched.entries
          .where((e) => e.value.autoDecided)
          .toList();
      expect(
        autoDecided.length,
        greaterThanOrEqualTo(5),
        reason: 'QA-Docs 実測（行単位 5/7）を下回らないこと',
      );
      for (final entry in autoDecided) {
        expect(
          entry.value.bestMatchOriginal,
          'Homesick Pt.2&3',
          reason: '${entry.key}: 想定外の曲で自動決定された',
        );
      }
    });
  });
}

OcrElement _elementFromJson(Map<String, dynamic> json) {
  final bbox = json['boundingBox'] as Map<String, dynamic>;
  return OcrElement(
    text: json['text'] as String,
    boundingBox: Rect.fromLTRB(
      (bbox['l'] as num).toDouble(),
      (bbox['t'] as num).toDouble(),
      (bbox['r'] as num).toDouble(),
      (bbox['b'] as num).toDouble(),
    ),
    confidence: (json['confidence'] as num).toDouble(),
  );
}
