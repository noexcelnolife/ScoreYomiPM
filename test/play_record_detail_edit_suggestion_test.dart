// 曲名入力の全入口に曲名DBライブサジェストを配線する（タスク 01a21152）テスト。
//
// 網羅:
// (1) 記録詳細 →「修正」（スコア修正）の曲名欄で、辞書由来の候補チップが出て
//     タップで曲名欄が置換される
// (2) HomeScreen →「写真なしで手入力」の曲名欄でも同じ
//
// WHY(red-first): ライブ検索コールバック onSongTitleSearch は HomeScreen の
// 一次 OCR 経路にしか配線されておらず、記録詳細の「修正」「再OCR」と手入力
// 経路では null のまま = チップの表示源が OCR 時点の静的 songMatchResult に
// 限られる（ユーザー要望「スコア修正の時にも曲名DBをもとに曲名サジェストして
// ください」）。配線前は本テストがチップ未検出で落ちる。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';
import 'package:scoreyomipm/ocr/song_title_normalizer.dart';
import 'package:scoreyomipm/songdb/song_database_service.dart';
import 'package:scoreyomipm/ui/home_screen.dart';
import 'package:scoreyomipm/ui/ocr_result_screen.dart';
import 'package:scoreyomipm/ui/play_record_detail_screen.dart';

import 'fake_ocr_engine.dart';
import 'fake_play_record_repository.dart';
import 'root_bundle_warmup.dart';

/// 候補チップが複数出る（autoDecided にならない）辞書エントリ。
///
/// WHY: 曲名を完全一致まで打つと SongTitleMatcher は確定扱い（autoDecided）に
/// してチップを出さない。部分一致で 2 件が同距離になる「あ/い」の 2 曲を辞書に
/// 置き、入力「テスト曲」で必ず未確定 2 候補になるようにする。
List<SongEntry> _entries() {
  return <SongEntry>[
    SongEntry(
      id: 'suggest-a',
      title: 'テスト曲あ',
      normalizedKey: normalizeSongTitle('テスト曲あ'),
      notesCounts: <String, int>{'EX': 1000},
    ),
    SongEntry(
      id: 'suggest-i',
      title: 'テスト曲い',
      normalizedKey: normalizeSongTitle('テスト曲い'),
      notesCounts: <String, int>{'EX': 1100},
    ),
  ];
}

/// allSongs をそのまま返す SongRepository フェイク
/// （song_title_element_matcher_test.dart / home_screen_vr_link_test.dart と同形）。
class _FakeSongRepository implements SongRepository {
  _FakeSongRepository(this.songs);

  final List<SongEntry> songs;

  @override
  String get sourceName => 'fakeSuggest';

  @override
  bool get isAvailable => true;

  @override
  List<SongEntry> get allSongs => List<SongEntry>.unmodifiable(songs);

  @override
  SongEntry? findByNormalizedKey(String normalizedKey) {
    for (final SongEntry song in songs) {
      if (song.normalizedKey == normalizedKey) {
        return song;
      }
    }
    return null;
  }

  @override
  int get length => songs.length;

  @override
  bool containsNormalizedKey(String normalizedKey) {
    return findByNormalizedKey(normalizedKey) != null;
  }
}

class _FakeSongDatabaseService implements SongDatabaseService {
  @override
  Future<String> loadDistributionUrl() async => '';

  @override
  Future<void> saveDistributionUrl(String url) async {}

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async =>
      const SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl);

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
  }) async =>
      const SongImportResult(success: false);

  @override
  Future<SongDatabaseStatus> loadStatus() async => const SongDatabaseStatus(
    distributionUrl: '',
    main: SongDbSourceStatus(exists: false),
    additional: SongDbSourceStatus(exists: false),
  );
}

/// pickImage の戻り値だけを制御できるフェイク。
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this._result);

  final XFile? _result;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => _result;
}

/// 辞書から作られる候補チップ（0 件目）。
final Finder _firstChip = find.byKey(
  const ValueKey<String>('candidate-chip-0'),
);

/// 曲名入力欄。
final Finder _songNameField = find.byKey(
  const ValueKey<String>('field-input-songName'),
);

/// 実 I/O（シード辞書の rootBundle 読み込み）を含む検索結果の反映を待つ。
///
/// WHY: ライブ検索は初回に BundledSeedRepository.load() を挟むため、fake async
/// だけでは Future が進まない。実時間を少しずつ進めながら pump する
/// （home_screen_vr_link_test の runAsync ポーリングと同じ手法）。
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 画面を縦に伸ばして、チップと曲名欄がスクロール外に出ないようにする。
///
/// WHY: 判定 4 値＋曲名欄＋チップで既定の 800x600 には収まらず、タップ位置が
/// 画面外になる。既存の #10・#12 / home_screen_vr_link_test と同じ拡大で、
/// 実機の本番挙動には影響しない。
void _enlargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 詳細画面に表示するレコードを 1 件作る（写真なし手入力のレコード）。
PlayRecord _record({required String id, String? songName}) {
  return PlayRecordDraft(
    songName: songName,
    status: PlayRecordStatus.confirmed,
    source: PlayRecordSource.playshare,
  ).toPlayRecord(
    id: id,
    resultImagePath: '',
    playedAt: DateTime(2026, 11, 24, 10, 30),
  );
}

bool _exists(Finder finder) => finder.evaluate().isNotEmpty;

void main() {
  setUpAll(warmRootBundleAssets);
  // WHY(シード辞書のプリロード): rootBundle はアセット文字列を Future ごと
  // キャッシュする。テスト A の fake async ゾーン内で完了した Future を
  // テスト B のゾーンから await すると解決通知が届かず、LiveSongTitleSearch の
  // シードロードが永久に待ち状態になる（2 本目がチップ 0 件で落ちる）。
  // ゾーン外で 1 度だけ読み込んでおけば、各テストは完了済み Future を待つだけ
  // になる。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await rootBundle.loadString('assets/songs/seed_v2.json');
  });

  testWidgets('(1) 修正: 曲名欄の入力で辞書由来の候補チップが出てタップで置換される', (
    WidgetTester tester,
  ) async {
    final PlayRecord record = _record(id: 'r-suggest', songName: 'テスト曲');
    final FakePlayRecordRepository repository = FakePlayRecordRepository()
      ..store[record.id] = record;
    _enlargeViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              PlayRecordDetailScreen.route(
                playRecordRepository: repository,
                ocrEngine: FakeOcrEngine(),
                recordId: record.id,
                mainSongRepository: _FakeSongRepository(_entries()),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('edit-record-button')));
    await tester.pumpAndSettle();
    expect(
      find.byType(OcrResultScreen),
      findsOneWidget,
      reason: 'スコア修正が開けていない',
    );

    // 入力し直す（前回の値とは別のクエリでライブ検索を走らせる）。
    await tester.enterText(_songNameField, 'テスト');
    await tester.pump();
    await tester.enterText(_songNameField, 'テスト曲');
    await _pumpUntilFound(tester, _firstChip);

    expect(
      _firstChip,
      findsWidgets,
      reason:
          'スコア修正の曲名欄で辞書由来の候補チップが出ない'
          '（onSongTitleSearch 未配線なら red）',
    );

    final String tappedTitle =
        (tester.widget<ActionChip>(_firstChip.first).label as Text).data!;
    expect(
      tappedTitle,
      anyOf('テスト曲あ', 'テスト曲い'),
      reason: 'チップが辞書（DB）由来の曲名になっていない',
    );

    await tester.tap(_firstChip.first);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_songNameField).controller!.text,
      tappedTitle,
      reason: 'チップのタップで曲名欄が置換されていない',
    );
  });

  testWidgets('(2) 手入力: 曲名欄の入力で辞書由来の候補チップが出てタップで置換される', (
    WidgetTester tester,
  ) async {
    _enlargeViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          ocrEngine: FakeOcrEngine(),
          songDatabaseService: _FakeSongDatabaseService(),
          playRecordRepository: FakePlayRecordRepository(),
          imagePicker: _FakeImagePicker(null),
          mainSongRepository: _FakeSongRepository(_entries()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('画像を取り込む'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真なしで手入力'));
    await tester.pumpAndSettle();
    expect(
      find.byType(OcrResultScreen),
      findsOneWidget,
      reason: '手入力画面が開けていない',
    );

    await tester.enterText(_songNameField, 'テスト');
    await tester.pump();
    await tester.enterText(_songNameField, 'テスト曲');
    await _pumpUntilFound(tester, _firstChip);

    expect(
      _firstChip,
      findsWidgets,
      reason:
          '手入力経路の曲名欄で辞書由来の候補チップが出ない'
          '（_openManualEntry のコールバック未配線なら red）',
    );

    final String tappedTitle =
        (tester.widget<ActionChip>(_firstChip.first).label as Text).data!;
    await tester.tap(_firstChip.first);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_songNameField).controller!.text,
      tappedTitle,
      reason: 'チップのタップで曲名欄が置換されていない',
    );
    expect(_exists(find.byType(OcrResultScreen)), isTrue);
  });
}
