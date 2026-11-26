// PlayRecordsScreen の曲名検索（01a20b92）のテスト。
//
// ユーザー要件: 記録一覧に曲名検索を追加する。既存のソート選択
// （実施日の新しい順 / スコアの高い順）は検索の前後で常に残し、検索結果にも
// 選択中のソートが効くこと。
//
// 検証対象:
// (a) 検索欄は常設・部分一致（ASCII は大文字小文字を区別しない）
// (b) 空クエリ（クリア）で全件に戻る・クリアボタンは入力中のだけ出る
// (c) 検索中も両ソートが効く（フィルタ→ソートの合成）・ソート UI は残る
// (d) 曲名が未入力（null）のレコードは検索語に一致しない
// (e) サジェストは保存済みレコードの曲名（重複排除）由来で、楽曲 DB 全件は使わない
// (f) 候補タップで検索語が確定し絞り込まれる・ソートは維持される
// (g) 候補が上限（8 件）を超えるときは先頭 8 件 + 「他 N 件」

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ui/play_records_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'test_image_helper.dart';

/// 検索欄（常設）。
const ValueKey<String> _searchFieldKey = ValueKey<String>(
  'records-search-field',
);

/// 検索語クリアボタン（入力中のみ表示）。
const ValueKey<String> _clearButtonKey = ValueKey<String>(
  'records-search-clear',
);

/// サジェスト候補のコンテナ。
const ValueKey<String> _suggestionsKey = ValueKey<String>(
  'records-suggestions',
);

/// サジェスト上限を超えた分の件数表示。
const ValueKey<String> _overflowKey = ValueKey<String>(
  'records-suggestion-overflow',
);

/// 一致 0 件の案内。
const ValueKey<String> _noMatchKey = ValueKey<String>('records-search-empty');

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// ドラフトからテスト用レコードを組み立てるヘルパー。
PlayRecord _record(
  File image, {
  required String id,
  required DateTime playedAt,
  String? songName,
  int? score,
  PlayRecordStatus status = PlayRecordStatus.confirmed,
}) {
  return PlayRecordDraft(
    songName: songName,
    score: score,
    status: status,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(id: id, resultImagePath: image.path, playedAt: playedAt);
}

/// 楽曲 DB のフェイク。
///
/// WHY: 「候補源は保存済みレコードの曲名であり、楽曲 DB 全件ではない」ことを
/// 検証するため、DB にだけ存在する曲名を注入できるようにする。
class _FakeSongRepository implements SongRepository {
  _FakeSongRepository(this._entries);

  final List<SongEntry> _entries;

  @override
  String get sourceName => 'fake_song_db';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => _entries;

  @override
  int get length => _entries.length;

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final SongEntry entry in _entries) {
      if (entry.normalizedKey == normalizedKey) {
        return entry;
      }
    }
    return null;
  }

  @override
  bool containsNormalizedKey(String normalizedKey) =>
      findByNormalizedKey(normalizedKey) != null;
}

Future<void> _pumpList(
  WidgetTester tester,
  FakePlayRecordRepository repository, {
  SongRepository? songRepository,
}) async {
  await tester.pumpWidget(
    _wrap(
      PlayRecordsScreen(
        playRecordRepository: repository,
        ocrEngine: FakeOcrEngine(),
        mainSongRepository: songRepository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 検索語を入力して再描画を待つ。
Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(_searchFieldKey), query);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('検索欄は常設で、曲名の部分一致（ASCII は大文字小文字無視）で絞り込む', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
        score: 98000,
      )
      ..store['c-sec'] = _record(
        image,
        id: 'c-sec',
        playedAt: DateTime(2026, 11, 21),
        songName: 'Second Heaven',
        score: 90000,
      )
      ..store['c-jp'] = _record(
        image,
        id: 'c-jp',
        playedAt: DateTime(2026, 11, 20),
        songName: 'ハルモニア',
        score: 80000,
      )
      ..store['p-harm'] = _record(
        image,
        id: 'p-harm',
        playedAt: DateTime(2026, 11, 23),
        songName: 'Harmonia',
        status: PlayRecordStatus.pending,
      );

    await _pumpList(tester, repository);

    // 常設: 入力前から検索欄が在る。
    expect(find.byKey(_searchFieldKey), findsOneWidget);
    expect(find.text('確定 3 件'), findsOneWidget);
    expect(find.text('未確定 1 件'), findsOneWidget);

    // 小文字 'harm' で大文字始まりの 'Harmonia' に一致する（ASCII は
    // 大文字小文字を区別しない既定）。
    await _search(tester, 'harm');

    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-p-harm')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-sec')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('record-row-c-jp')), findsNothing);

    // 見出しの件数は絞り込み後の件数になる。
    expect(find.text('確定 1 件'), findsOneWidget);
    expect(find.text('未確定 1 件'), findsOneWidget);

    // WHY: 統計カードは「記録全体のサマリ」なので検索で動かさない
    // （数字が検索で変わると絞り込み表示と混同される）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('records-stats-total')),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('クリアで全件に戻り、クリアボタンは入力中のみ表示される', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
      )
      ..store['c-sec'] = _record(
        image,
        id: 'c-sec',
        playedAt: DateTime(2026, 11, 21),
        songName: 'Second Heaven',
      );

    await _pumpList(tester, repository);

    // 空クエリではクリアボタンを出さない（消す対象が無い）。
    expect(find.byKey(_clearButtonKey), findsNothing);

    await _search(tester, 'harm');
    expect(find.byKey(_clearButtonKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('record-row-c-sec')),
      findsNothing,
    );

    await tester.tap(find.byKey(_clearButtonKey));
    await tester.pumpAndSettle();

    // 空クエリ = 全件。確定 2 件に戻る。
    expect(find.text('確定 2 件'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-sec')),
      findsOneWidget,
    );
    expect(find.byKey(_clearButtonKey), findsNothing);
  });

  testWidgets('検索中も実施日順・スコア順の切替が効き、ソート UI は残る', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      // 古いが高得点（実施日順では下・スコア順では上）。
      ..store['c-alpha'] = _record(
        image,
        id: 'c-alpha',
        playedAt: DateTime(2026, 11, 20),
        songName: 'Alpha',
        score: 99000,
      )
      // 新しいが低得点（実施日順では上・スコア順では下）。
      ..store['c-album'] = _record(
        image,
        id: 'c-album',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Album',
        score: 90000,
      )
      // 検索語に一致しない（両ソートで除外されていることの確認用）。
      ..store['c-beta'] = _record(
        image,
        id: 'c-beta',
        playedAt: DateTime(2026, 11, 21),
        songName: 'Beta',
        score: 80000,
      );

    await _pumpList(tester, repository);
    await _search(tester, 'al');

    // 既定（実施日の新しい順）: Album(11/22) が Alpha(11/20) より上。
    expect(
      find.byKey(const ValueKey<String>('records-sort-segment')),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('record-row-c-album')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('record-row-c-alpha')),
            )
            .dy,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-beta')),
      findsNothing,
    );

    // 検索中でもスコア順へ切り替えられる（フィルタ→ソートの合成）。
    await tester.tap(find.text('スコアの高い順'));
    await tester.pumpAndSettle();

    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('record-row-c-alpha')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('record-row-c-album')),
            )
            .dy,
      ),
    );
    // 絞り込みは維持される。
    expect(
      find.byKey(const ValueKey<String>('record-row-c-beta')),
      findsNothing,
    );
    expect(find.text('確定 2 件'), findsOneWidget);
  });

  testWidgets('曲名が未入力のレコードは検索語に一致しない（空クエリでは表示）', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
      )
      ..store['p-empty'] = _record(
        image,
        id: 'p-empty',
        playedAt: DateTime(2026, 11, 21),
        status: PlayRecordStatus.pending,
      );

    await _pumpList(tester, repository);

    // 空クエリでは未確定（曲名未入力）も一覧に出る。
    expect(
      find.byKey(const ValueKey<String>('record-row-p-empty')),
      findsOneWidget,
    );

    await _search(tester, 'harm');

    expect(
      find.byKey(const ValueKey<String>('record-row-p-empty')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsOneWidget,
    );
    // 未確定が 0 件になったのでグループ見出しも出ない（既存規約）。
    expect(find.text('未確定 1 件'), findsNothing);
  });

  testWidgets('サジェストは保存済みレコードの曲名から出て、楽曲 DB 全件は使わない', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
      )
      // 同名の別レコード（重複排除の確認用）。
      ..store['c-harm-2'] = _record(
        image,
        id: 'c-harm-2',
        playedAt: DateTime(2026, 11, 21),
        songName: 'Harmonia',
      )
      ..store['c-sec'] = _record(
        image,
        id: 'c-sec',
        playedAt: DateTime(2026, 11, 20),
        songName: 'Second Heaven',
      );

    // DB にだけ存在する曲名。候補に出てはいけない。
    final _FakeSongRepository songDb = _FakeSongRepository(<SongEntry>[
      const SongEntry(
        id: 'db-1',
        title: 'Unrecorded Song',
        normalizedKey: 'unrecordedsong',
      ),
      const SongEntry(id: 'db-2', title: 'Harmonia', normalizedKey: 'harmonia'),
    ]);

    await _pumpList(tester, repository, songRepository: songDb);

    // 空クエリでは候補を出さない（入力に応じて出す）。
    expect(find.byKey(_suggestionsKey), findsNothing);

    // 'n' は 3 レコードすべての曲名に含まれる（候補は重複排除で 2 種）。
    // DB 全件由来なら 'Unrecorded Song' も候補になるが、レコード由来なので出ない。
    await _search(tester, 'n');

    expect(find.byKey(_suggestionsKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('records-suggestion-Harmonia')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('records-suggestion-Second Heaven')),
      findsOneWidget,
    );
    expect(find.text('Unrecorded Song'), findsNothing);
  });

  testWidgets('候補タップで検索語が確定して絞り込まれ、ソートは維持される', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 20),
        songName: 'Harmonia',
        score: 90000,
      )
      ..store['c-sec'] = _record(
        image,
        id: 'c-sec',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Second Heaven',
        score: 95000,
      );

    await _pumpList(tester, repository);
    // 候補が出る途中入力（完全一致ではない）。
    await _search(tester, 'harmon');

    final Finder chip = find.byKey(
      const ValueKey<String>('records-suggestion-Harmonia'),
    );
    expect(chip, findsOneWidget);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    // 検索語が候補の曲名で確定する（TextField の controller 値で確認）。
    expect(
      tester.widget<TextField>(find.byKey(_searchFieldKey)).controller!.text,
      'Harmonia',
    );
    // 絞り込みが実行されている。
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-sec')),
      findsNothing,
    );
    // 完全一致した候補は集合から外れる。このデータは「Harmonia（完全一致）」と
    // 「Second Heaven（'harmonia' を含まない）」だけなので、除外後に候補は 0 件
    // となりコンテナ自体が消える（部分一致の別曲が残る場合はコンテナは残る。
    // その規則は「完全一致した候補 1 個だけを隠し、近い別曲の候補は残す」で検証）。
    expect(find.byKey(_suggestionsKey), findsNothing);
    expect(chip, findsNothing);
    // ソート選択 UI は残る（検索の前後で常に表示）。
    expect(
      find.byKey(const ValueKey<String>('records-sort-segment')),
      findsOneWidget,
    );
  });

  testWidgets('完全一致した候補 1 個だけを隠し、近い別曲の候補は残す', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
      )
      // 曲名の末尾に数字が付いただけの別曲。
      ..store['c-harm2'] = _record(
        image,
        id: 'c-harm2',
        playedAt: DateTime(2026, 11, 21),
        songName: 'Harmonia2',
      );

    await _pumpList(tester, repository);
    await _search(tester, 'Harmonia');

    // WHY: 曲名の末尾に数字や UPPER が付いただけの別曲が多数あるため、
    // 完全一致した候補だけを隠し、部分一致で残る近い別曲は候補として残す
    // （2026-11-24 ユーザー指示）。全体非表示にすると別曲を選べなくなる。
    expect(find.byKey(_suggestionsKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('records-suggestion-Harmonia')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('records-suggestion-Harmonia2')),
      findsOneWidget,
    );

    // 一覧の絞り込みは部分一致なので 2 件とも出る（候補の出し分けとは独立）。
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm2')),
      findsOneWidget,
    );
  });

  testWidgets('候補が上限 8 件を超えるときは先頭 8 件と「他 N 件」を表示する', (
    WidgetTester tester,
  ) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository();
    for (int i = 1; i <= 10; i++) {
      final String id = 'c-song-$i';
      repository.store[id] = _record(
        image,
        id: id,
        playedAt: DateTime(2026, 11, 1).add(Duration(days: i)),
        songName: 'Song${i.toString().padLeft(2, '0')}',
      );
    }

    await _pumpList(tester, repository);
    await _search(tester, 'song');

    expect(find.byType(ActionChip), findsNWidgets(8));
    expect(tester.widget<Text>(find.byKey(_overflowKey)).data, '他 2 件');
    // 「他 N 件」はタップ不可の静的ラベル（押せる見た目だと「押しても何も
    // 起きない」欠陥に見える）。タップ可能な Chip の内側に無いことを確認する。
    expect(
      find.ancestor(
        of: find.byKey(_overflowKey),
        matching: find.byType(ActionChip),
      ),
      findsNothing,
    );
  });

  testWidgets('一致 0 件のときは案内文を出し、行と件数見出しを出さない', (WidgetTester tester) async {
    final File image = createTestImageFile();
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store['c-harm'] = _record(
        image,
        id: 'c-harm',
        playedAt: DateTime(2026, 11, 22),
        songName: 'Harmonia',
      )
      ..store['p-empty'] = _record(
        image,
        id: 'p-empty',
        playedAt: DateTime(2026, 11, 21),
        status: PlayRecordStatus.pending,
      );

    await _pumpList(tester, repository);
    await _search(tester, 'zzz');

    expect(
      tester.widget<Text>(find.byKey(_noMatchKey)).data,
      '「zzz」に一致する記録はありません',
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-c-harm')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('record-row-p-empty')),
      findsNothing,
    );
    // 0 件のグループ見出しは既存規約どおり出さない。
    expect(find.text('確定 1 件'), findsNothing);
    expect(find.text('未確定 1 件'), findsNothing);
    // 検索状態でも統計カードとソート切替は残す。
    expect(
      find.byKey(const ValueKey<String>('records-sort-segment')),
      findsOneWidget,
    );
  });
}
