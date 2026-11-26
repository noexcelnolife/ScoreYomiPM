// Wave 2 ST-4 パイプライン統合テスト（fake engine TDD）。
// RegionOcrRunner を含む経路、寸法欠落時 null、anchor 皆無時 full extract 同等。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/downloaded_main_repository.dart';
import 'package:scoreyomipm/ocr/field_extractor.dart';
import 'package:scoreyomipm/ocr/local_additional_repository.dart';
import 'package:scoreyomipm/ocr/ocr_engine.dart';
import 'package:scoreyomipm/ocr/pipeline.dart';
import 'package:scoreyomipm/ocr/song_entry.dart';
import 'package:scoreyomipm/ocr/song_repository.dart';

class _FakeEngine implements OcrEngine {
  OcrPageResult? recognizeResult;
  OcrPageResult? recognizeRegionResult;
  int recognizeCallCount = 0;
  int recognizeRegionCallCount = 0;
  final List<Rect> requestedRegions = [];

  /// スケール別の領域 OCR 応答（null なら [recognizeRegionResult] を使用）。
  ///
  /// WHY: songTitle フォールバック spec（scale 2.0）だけがプライマリ
  /// （scale 1.0/3.0）と異なる応答を返す必要がある（ST-5 補完）。
  /// RegionTarget.values の順序や spec 群の内部構造に依存せず、
  /// pixelScale だけで応答を分離できる（呼び出し順非依存で決定的）。
  OcrPageResult? Function(double pixelScale)? regionResultForScale;

  @override
  Future<OcrPageResult> recognize(File imageFile) async {
    recognizeCallCount++;
    return recognizeResult ?? OcrPageResult(elements: [], fullText: '');
  }

  @override
  Future<OcrPageResult> recognizeRegion(
    File imageFile,
    Rect region, {
    required OcrScript script,
    double pixelScale = 1.0,
    // WHY 追加（docs/st5_f2_g_contrast_preprocess_design_confirmation_
    // 2026-11-22.md・docs コミット 18b2111・リード承認済み）: OcrEngine
    // インターフェースに狭帯前処理再試行フラグが追加されたため（red 段階
    // では受け取るのみ・パイプライン側の注入は実装コミット）。
    bool contrastRetry = false,
  }) async {
    recognizeRegionCallCount++;
    requestedRegions.add(region);
    // スケール別応答が設定されている場合はそちらを優先
    //（WHY: spec の構成順序によらず pixelScale で応答を分離する）。
    final byScale = regionResultForScale;
    if (byScale != null) {
      return byScale(pixelScale) ?? OcrPageResult(elements: [], fullText: '');
    }
    return recognizeRegionResult ?? OcrPageResult(elements: [], fullText: '');
  }

  @override
  Future<void> dispose() async {}
}

/// テスト用 fake SongRepository（ST-6 リポジトリ注入テスト用）。
///
/// TestSongRepository（merged_song_repository_test.dart）と同様のスタブ。
/// isAvailable=false で DB 未ダウンロード・ファイル欠落状態を模擬できる。
class _FakeSongRepository implements SongRepository {
  final String name;
  final List<SongEntry> songs;
  final bool available;

  _FakeSongRepository({
    required this.name,
    required this.songs,
    this.available = true,
  });

  @override
  String get sourceName => name;

  @override
  bool get isAvailable => available;

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

/// songTitle 帯の OCR 結果を返す fake engine を構築する。
///
/// full-page 結果は寸法のみ（領域 OCR を有効化する目的）。
/// recognizeRegionResult は全領域共通で返るため、songTitle 帯にも
/// [songTitleText] が OCR されたことになる（_runSongMatching は
/// songTitle 帯の要素テキストを照合に使う）。
///
/// [width]/[height]: full-page の寸法（横画像・縦スクショ両方のテストに
/// 使う。デフォルトは既存テスト互換の 1080x1920）。
_FakeEngine _engineWithSongTitle(
  String songTitleText, {
  int width = 1080,
  int height = 1920,
}) {
  final engine = _FakeEngine();
  engine.recognizeResult = OcrPageResult(
    elements: [],
    fullText: '',
    imageWidth: width,
    imageHeight: height,
  );
  engine.recognizeRegionResult = OcrPageResult(
    elements: [
      OcrElement(
        text: songTitleText,
        boundingBox: Rect.fromLTRB(10, 10, 200, 30),
        confidence: 0.9,
      ),
    ],
    fullText: songTitleText,
    imageWidth: 190,
    imageHeight: 20,
  );
  return engine;
}

void main() {
  // WHY: songMatching ステージ（ST-6）が rootBundle で bundledSeed アセットを
  // 読むため、素の test() では TestWidgetsFlutterBinding の初期化が必須。
  // 未初期化だと loadString が失敗し、パイプライン内の catch で
  // songMatchResult が null になる（リポジトリ注入テストが成立しない）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OcrPipeline Wave 2 region OCR integration', () {
    test('spec あり: full-page extract + region OCR merge 結果が設定される', () async {
      // Arrange
      final engine = _FakeEngine();
      final imageFile = File('test.png');

      // full-page OCR 結果（GOOD=14 を正しく抽出、BAD は未抽出）
      engine.recognizeResult = OcrPageResult(
        elements: [
          OcrElement(
            text: 'GOOD',
            boundingBox: Rect.fromLTRB(100, 100, 200, 110),
            confidence: 0.95,
          ),
          OcrElement(
            text: '14',
            boundingBox: Rect.fromLTRB(200, 100, 240, 110),
            confidence: 0.92,
          ),
          OcrElement(
            text: 'BAD',
            boundingBox: Rect.fromLTRB(100, 150, 200, 160),
            confidence: 0.93,
          ),
        ],
        fullText: 'GOOD 14 BAD',
        imageWidth: 1080,
        imageHeight: 1920,
      );

      // region OCR 結果（BAD=321 を補正抽出）
      engine.recognizeRegionResult = OcrPageResult(
        elements: [
          OcrElement(
            text: 'BAD',
            boundingBox: Rect.fromLTRB(100, 150, 200, 160),
            confidence: 0.93,
          ),
          OcrElement(
            text: '321',
            boundingBox: Rect.fromLTRB(200, 150, 240, 160),
            confidence: 0.90,
          ),
        ],
        fullText: 'BAD 321',
        imageWidth: 300,
        imageHeight: 100,
      );

      // Act
      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(imageFile);

      // Assert: full-page extract 経由で GOOD=14、region OCR 経由で BAD=321 がマージされる
      expect(engine.recognizeCallCount, equals(1));
      expect(engine.recognizeRegionCallCount, greaterThan(0));
      expect(context.extractionResult, isNotNull);
      expect(
        context.extractionResult!.numericFields[NumericFieldKind.good]?.value,
        equals(14),
      );
      expect(
        context.extractionResult!.numericFields[NumericFieldKind.bad]?.value,
        equals(321),
      );
    });

    test('寸法欠落時: FR-3 null フォールバック、extractionResult=null', () async {
      // Arrange
      final engine = _FakeEngine();
      final imageFile = File('test.png');

      engine.recognizeResult = OcrPageResult(
        elements: [],
        fullText: '',
        imageWidth: null,
        imageHeight: null,
      );

      // Act
      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(imageFile);

      // Assert
      expect(context.extractionResult, isNull);
      expect(engine.recognizeRegionCallCount, equals(0));
    });

    test(
      'numeric アンカー無し: full extract が機能、region OCR は songTitle/level のみ',
      () async {
        // Arrange
        final engine = _FakeEngine();
        final imageFile = File('test.png');

        // numeric ラベル（GOOD/BAD/SCORE 等）のアンカーが何も無いページ結果。
        // songTitle/level spec は常に生成されるため region OCR は呼ばれる。
        // SCORE アンカー cx≈0.139、列窓[0.20,0.30] → 値要素は cx≈0.34〜0.44 に配置。
        engine.recognizeResult = OcrPageResult(
          elements: [
            OcrElement(
              text: 'SCORE',
              boundingBox: Rect.fromLTRB(100, 50, 200, 60),
              confidence: 0.9,
            ),
            OcrElement(
              text: '12345',
              boundingBox: Rect.fromLTRB(370, 45, 450, 65),
              confidence: 0.88,
            ),
          ],
          fullText: 'SCORE 12345',
          imageWidth: 1080,
          imageHeight: 1920,
        );

        // Act
        final pipeline = OcrPipeline(engine: engine);
        final context = await pipeline.run(imageFile);

        // Assert: full extract で score=12345 が取得される。
        // region OCR は songTitle/level 用に呼ばれる（numeric アンカー無しのため
        // numeric 用 spec は生成されず、region OCR 結果はマージに寄与しない）。
        expect(context.extractionResult, isNotNull);
        expect(
          context
              .extractionResult!
              .numericFields[NumericFieldKind.score]
              ?.value,
          equals(12345),
        );
        expect(engine.recognizeRegionCallCount, greaterThan(0));
      },
    );
  });

  group('OcrPipeline songMatching リポジトリ注入（ST-6 統合）', () {
    test('additional > main: 同一キー競合で additional のエントリが採用される', () async {
      final engine = _engineWithSongTitle('Test Song');
      final main = _FakeSongRepository(
        name: 'downloadedMain(fake)',
        songs: [
          const SongEntry(
            id: 'm1',
            title: 'Main Ver',
            normalizedKey: 'testsong',
          ),
        ],
      );
      final additional = _FakeSongRepository(
        name: 'localAdditional(fake)',
        songs: [
          const SongEntry(
            id: 'a1',
            title: 'Additional Ver',
            normalizedKey: 'testsong',
          ),
        ],
      );

      final pipeline = OcrPipeline(
        engine: engine,
        mainSongRepository: main,
        additionalSongRepository: additional,
      );
      final context = await pipeline.run(File('test.png'));

      expect(context.songMatchResult, isNotNull);
      expect(
        context.songMatchResult!.bestMatchOriginal,
        equals('Additional Ver'),
      );
      // マージ済みリポジトリにも additional エントリが反映されている
      final mergedEntry = context.songRepository!.findByNormalizedKey(
        'testsong',
      );
      expect(mergedEntry?.id, equals('a1'));
    });

    test('main > seed: 実 seed の同名キーを main 注入が上書きする', () async {
      final engine = _engineWithSongTitle('Harmonia');
      final main = _FakeSongRepository(
        name: 'downloadedMain(fake)',
        songs: [
          // WHY: 実シードの 'harmonia'（Harmonia）と競合させるため
          // normalizedKey を明示指定する（テストフィクスチャの意図的競合）。
          const SongEntry(
            id: 'm1',
            title: 'Harmonia Main',
            normalizedKey: 'harmonia',
          ),
        ],
      );

      final pipeline = OcrPipeline(engine: engine, mainSongRepository: main);
      final context = await pipeline.run(File('test.png'));

      expect(context.songMatchResult, isNotNull);
      expect(
        context.songMatchResult!.bestMatchOriginal,
        equals('Harmonia Main'),
      );
      expect(context.songMatchResult!.bestDistance, equals(0));
      expect(context.songMatchResult!.autoDecided, isTrue);
    });

    test('未注入時: シードのみで照合する（現状維持の回帰）', () async {
      final engine = _engineWithSongTitle('Harmonia');

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      expect(context.songMatchResult, isNotNull);
      expect(context.songMatchResult!.bestMatchOriginal, equals('Harmonia'));
      expect(context.songMatchResult!.bestDistance, equals(0));
      expect(context.songMatchResult!.autoDecided, isTrue);
      // 注入ソースがマージに含まれていないこと
      expect(
        context.songRepository!.sourceName,
        isNot(contains('downloadedMain')),
      );
      expect(
        context.songRepository!.sourceName,
        isNot(contains('localAdditional')),
      );
    });

    test('照合成功時: context.matchedSong へ解決済み SongEntry が注入される', () async {
      final engine = _engineWithSongTitle('Harmonia');

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      // WHY: FR-6 §2-5 Plan A。後段の曲別上限チェック等は bestMatch* の
      // 文字列ではなく辞書解決済みエントリを参照する。seed_v2 の Harmonia
      // は notesCounts {LIGHT:135, EX:1036} で totalNotes=1036（max）。
      //（設計確認書 fr6_matched_song_context_injection §2・リード承認）
      expect(context.matchedSong, isNotNull);
      expect(context.matchedSong!.id, equals('popn_hc_001'));
      expect(context.matchedSong!.totalNotes, equals(1036));
      expect(context.matchedSong!.notesCountFor('LIGHT'), equals(135));
    });

    test('downloadedMain 経路: 実 JSON 一時ファイルの解決エントリが matchedSong になる', () async {
      final dir = await Directory.systemTemp.createTemp('scoreyomipm_main');
      final file = File('${dir.path}${Platform.pathSeparator}main_v2.json');
      await file.writeAsString(
        '{"songs":[{"id":"main_test_001",'
        '"title":"Main Repo Song","normalizedKey":"mainreposong",'
        '"notesCounts":{"EX":999}}]}',
      );
      // WHY: 3 リポジトリ経路の消費側整合（fr6 設計 §3）。実 JSON → 実
      // DownloadedMainRepository（lazy 読込）→ pipeline →
      // context.matchedSong.notesCountFor まで通す（fake でなく実ディスク読込）。
      final repo = DownloadedMainRepository(file.path);

      final pipeline = OcrPipeline(
        engine: _engineWithSongTitle('Main Repo Song'),
        mainSongRepository: repo,
      );
      final context = await pipeline.run(File('test.png'));

      expect(context.matchedSong, isNotNull);
      expect(context.matchedSong!.id, equals('main_test_001'));
      expect(context.matchedSong!.notesCountFor('EX'), equals(999));
      await dir.delete(recursive: true);
    });

    test('localAdditional 経路: 実 JSON 一時ファイルの解決エントリが matchedSong になる', () async {
      final dir = await Directory.systemTemp.createTemp('scoreyomipm_add');
      final file = File('${dir.path}${Platform.pathSeparator}additional.json');
      await file.writeAsString(
        '{"songs":[{"id":"add_test_001",'
        '"title":"Additional Song","normalizedKey":"additionalsong",'
        '"notesCounts":{"HARD":1234}}]}',
      );
      // WHY: additional はマージ最優先。seed に無い曲名のため additional の
      // エントリが採用されることが matchedSong でも確認できる（fr6 設計 §3）。
      final repo = LocalAdditionalRepository(file.path);

      final pipeline = OcrPipeline(
        engine: _engineWithSongTitle('Additional Song'),
        additionalSongRepository: repo,
      );
      final context = await pipeline.run(File('test.png'));

      expect(context.matchedSong, isNotNull);
      expect(context.matchedSong!.id, equals('add_test_001'));
      expect(context.matchedSong!.notesCountFor('HARD'), equals(1234));
      await dir.delete(recursive: true);
    });

    test('照合不成立時: matchedSong は null（null 契約ガード）', () async {
      final engine = _engineWithSongTitle('存在しない曲XYZ');

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      expect(context.matchedSong, isNull);
    });

    test('要素なし: matchedSong は null（null 契約ガード）', () async {
      final engine = _FakeEngine();

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      expect(context.matchedSong, isNull);
    });

    test('unavailable な注入ソースはスキップされ seed で照合する', () async {
      final engine = _engineWithSongTitle('Harmonia');
      final main = _FakeSongRepository(
        name: 'downloadedMain(fake)',
        songs: [
          const SongEntry(
            id: 'm1',
            title: 'Harmonia Main',
            normalizedKey: 'harmonia',
          ),
        ],
        available: false, // DB 未ダウンロード・ファイル欠落を模擬
      );

      final pipeline = OcrPipeline(engine: engine, mainSongRepository: main);
      final context = await pipeline.run(File('test.png'));

      expect(context.songMatchResult, isNotNull);
      // main がマージからスキップされるため seed の 'Harmonia' が採用される
      expect(context.songMatchResult!.bestMatchOriginal, equals('Harmonia'));
      expect(
        context.songRepository!.findByNormalizedKey('harmonia')?.id,
        isNot(equals('m1')),
      );
    });

    test('注入 main の新曲（シード外）で自動決定照合が成立する', () async {
      final engine = _engineWithSongTitle('New Main Song');
      final main = _FakeSongRepository(
        name: 'downloadedMain(fake)',
        songs: [
          const SongEntry(
            id: 'm1',
            title: 'New Main Song',
            normalizedKey: 'newmainsong',
          ),
        ],
      );

      final pipeline = OcrPipeline(engine: engine, mainSongRepository: main);
      final context = await pipeline.run(File('test.png'));

      expect(context.songMatchResult, isNotNull);
      expect(
        context.songMatchResult!.bestMatchNormalized,
        equals('newmainsong'),
      );
      expect(
        context.songMatchResult!.bestMatchOriginal,
        equals('New Main Song'),
      );
      expect(context.songMatchResult!.bestDistance, equals(0));
      expect(context.songMatchResult!.autoDecided, isTrue);
      expect(context.songRepository!.sourceName, contains('downloadedMain'));
    });

    test('songTitle 帯の genre 行混入でも曲名行を自動決定する（ST-5 本実装）', () async {
      final engine = _FakeEngine();
      engine.recognizeResult = OcrPageResult(
        elements: [],
        fullText: '',
        imageWidth: 1080,
        imageHeight: 1920,
      );
      // usnb54 型（実 fixture 値）: genre 行 + 曲名行の 2 行構成
      engine.recognizeRegionResult = OcrPageResult(
        elements: [
          OcrElement(
            text: 'SOFT',
            boundingBox: Rect.fromLTRB(552, 24, 658, 67),
            confidence: 0.66,
          ),
          OcrElement(
            text: 'ROCIK',
            boundingBox: Rect.fromLTRB(666, 24, 773, 67),
            confidence: 0.68,
          ),
          OcrElement(
            text: 'LONG',
            boundingBox: Rect.fromLTRB(788, 24, 892, 67),
            confidence: 0.77,
          ),
          OcrElement(
            text: 'Homesiok',
            boundingBox: Rect.fromLTRB(556, 84, 698, 114),
            confidence: 0.58,
          ),
          OcrElement(
            text: 'Pt.2&3',
            boundingBox: Rect.fromLTRB(709, 84, 814, 114),
            confidence: 0.70,
          ),
        ],
        fullText: 'SOFT ROCIK LONG\nHomesiok Pt.2&3',
        imageWidth: 1200,
        imageHeight: 114,
      );

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      // genre 行（SOFT ROCIK LONG）に引っ張られず曲名行で自動決定する
      expect(context.songMatchResult, isNotNull);
      expect(context.songMatchResult!.bestMatchOriginal, 'Homesick Pt.2&3');
      expect(context.songMatchResult!.bestDistance, 1);
      expect(context.songMatchResult!.autoDecided, isTrue);
    });
  });

  group('OcrPipeline songTitle フォールバック（ST-5 補完）', () {
    test('横画像: songTitle プライマリ空要素時、フォールバック spec で照合が成立する', () async {
      // WHY: 実測で横画像の scale 1.0 固定バンド [0.16, 0.30] は ML Kit の
      // 揺らぎで曲名要素 0 候補になる run があり（probe 実測・24/30 の残り）、
      // 縦拡張帯 [0.14, 0.34] × scale 2.0 の再 OCR で検出が回復する
      //（g7p9b2 / ay7zmq）。pipeline 統合レベルで「プライマリ空 →
      // フォールバック採用 → 照合成立」を検証する。寸法は横画像（w > h）
      // であることが前提（縦スクショは portrait バンドに分岐する別経路）。
      final engine = _FakeEngine();
      engine.recognizeResult = OcrPageResult(
        elements: [],
        fullText: '',
        imageWidth: 1200,
        imageHeight: 800,
      );
      // スケール別応答: scale 1.0（プライマリ）は 0 要素、scale 2.0
      //（フォールバック）は曲名行 2 要素を返す。WHY 同一行 2 要素:
      // 実データの曲名行は複数要素に分割されるため、行内連結 → 照合の
      // 本実装（ST-5）経路をそのまま通す。GOOD/BAD 等の scale 2.0
      // フォールバックにも曲名要素が返るが、full-page に要素が無く
      // numeric アンカーが立たないため数値系 spec は 1 本も生成されず影響しない。
      engine.regionResultForScale = (pixelScale) => pixelScale == 2.0
          ? OcrPageResult(
              elements: [
                OcrElement(
                  text: 'Homesick',
                  boundingBox: Rect.fromLTRB(10, 10, 200, 30),
                  confidence: 0.9,
                ),
                OcrElement(
                  text: 'Pt.2&3',
                  boundingBox: Rect.fromLTRB(210, 10, 400, 30),
                  confidence: 0.9,
                ),
              ],
              fullText: 'Homesick Pt.2&3',
              imageWidth: 1200,
              imageHeight: 320,
            )
          : OcrPageResult(
              elements: const [],
              fullText: '',
              imageWidth: 1200,
              imageHeight: 320,
            );

      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      // songTitle のプライマリ固定バンド [0.16, 0.30] → px (0, 128, 1200, 240)、
      // フォールバック広帯域 [0.14, 0.34] → px (0, 112, 1200, 272) の順に
      // 実行されること。WHY 順序検証: プライマリが空のときだけフォールバック
      // が走る runner 契約の統合確認。level など他 target は難易度要素なしで
      // も median フォールバック spec を持つ（実測 QA-Docs レポート §5-4 と
      // 同現象）ため、呼び出し総数ではなく songTitle バンドの実行と順序を検証する。
      final primaryIndex = engine.requestedRegions.indexOf(
        const Rect.fromLTRB(0, 128, 1200, 240),
      );
      final fallbackIndex = engine.requestedRegions.indexOf(
        const Rect.fromLTRB(0, 112, 1200, 272),
      );
      expect(primaryIndex, isNonNegative, reason: 'プライマリ固定バンドが実行されること');
      expect(
        fallbackIndex,
        greaterThan(primaryIndex),
        reason: 'プライマリ空の後にフォールバックが実行されること',
      );
      // フォールバック結果の曲名行で seed 照合が自動決定する
      expect(context.songMatchResult, isNotNull);
      expect(context.songMatchResult!.bestMatchOriginal, 'Homesick Pt.2&3');
      expect(context.songMatchResult!.bestDistance, 0);
      expect(context.songMatchResult!.autoDecided, isTrue);
    });

    test('縦スクショ: portrait バンドで曲名照合が成立し横バンドは呼ばれない', () async {
      // WHY: 縦スクショ実測（scr001-009 前処理後 1071x2316・h > w 9/9・
      // probe で確認）では曲名行は cy 0.441-0.442 にあり、横画像バンド
      // [0.16, 0.30] / [0.14, 0.34] は帯内 0 要素の捨て打ちになる。
      // pipeline 統合レベルで「縦寸法 → portrait バンドのみ実行 → 照合成立」
      // と「横バンド（primary/fallback）が 1 つも呼ばれない」を検証する。
      // 縦の実データ効果（期待 2/9）は fake では検証不能のためここでは
      // 主張しない（実測は QA-Docs の効果検証計測で確定する）。
      // px 換算（1071x2316）: 横 primary [0.16,0.30] → y [370, 695]・
      // 横 fallback [0.14,0.34] → y [324, 788]・portrait [0.40,0.47] →
      // y [926, 1089]。
      final engine = _engineWithSongTitle('Sorrows', width: 1071, height: 2316);
      final pipeline = OcrPipeline(engine: engine);
      final context = await pipeline.run(File('test.png'));

      // portrait バンド呼び出しで曲名要素が取得され照合が成立する
      expect(context.songMatchResult, isNotNull);
      expect(context.songMatchResult!.bestMatchOriginal, 'Sorrows');
      expect(context.songMatchResult!.autoDecided, isTrue);
      // 横バンド（full width・上記 y 範囲）の完全一致矩形が 1 つも無いこと。
      expect(
        engine.requestedRegions,
        isNot(contains(const Rect.fromLTRB(0, 370, 1071, 695))),
      );
      expect(
        engine.requestedRegions,
        isNot(contains(const Rect.fromLTRB(0, 324, 1071, 788))),
      );
      // portrait バンドが実行されること。
      expect(
        engine.requestedRegions,
        contains(const Rect.fromLTRB(0, 926, 1071, 1089)),
      );
    });
  });
}
