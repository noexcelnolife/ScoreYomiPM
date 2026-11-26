import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'data/play_record_repository.dart';
import 'ocr/downloaded_main_repository.dart';
import 'ocr/local_additional_repository.dart';
import 'ocr/mlkit_engine.dart';
import 'ocr/ocr_engine.dart';
import 'ocr/song_repository.dart';
import 'songdb/song_database_service.dart';
import 'songdb/song_db_paths.dart';
import 'ui/home_screen.dart';
import 'ui/sharing_intent_receiver.dart';

Future<void> main() async {
  // WHY: コンポジションルート。OCR 具体実装（MlKitOcrEngine）の生成は
  // ここでのみ行い、UI からは抽象 OcrEngine だけを見せる（DIP）。
  // アプリ終了時の dispose は明示しない（runApp 後は制御が戻らず、
  // プロセス終了時に OS 側でネイティブリソースが回収される）。
  final MlKitOcrEngine ocrEngine = MlKitOcrEngine();

  // WHY: Song DB の保存先（documents ディレクトリ）の解決は実行環境依存のため
  // 関数として注入し、テストでは一時ディレクトリへ差し替え可能にする（DIP）。
  final Directory documentsDirectory = await getApplicationDocumentsDirectory();
  final SongDatabaseService songDatabaseService = FileSongDatabaseService(
    documentsDirectoryResolver: () async => documentsDirectory,
  );

  // WHY: 配信 DL メイン DB・ローカル追加 DB の実体は documents ディレクトリ配下の
  // ファイルで、lib/songdb の書き込み先と lib/ocr リポジトリの読み込み先が
  // SongDbPaths で一致する。マージ優先順位（追加 > メイン > シード）と
  // フォールバック判定は MergedSongRepository 側に完結しており、ここでは
  // 素材となるリポジトリを OcrPipeline へ渡すだけに留める（DIP）。
  final SongRepository mainSongRepository = DownloadedMainRepository(
    '${documentsDirectory.path}/${SongDbPaths.mainDbRelativePath}',
  );
  final SongRepository additionalSongRepository = LocalAdditionalRepository(
    '${documentsDirectory.path}/${SongDbPaths.additionalDbRelativePath}',
  );

  // FR-4: プレイ記録の保存先。records.json と画像は documents 配下に置く。
  // WHY: ディレクトリ解決は実行環境依存のため関数として注入し、テストでは
  // 一時ディレクトリへ差し替え可能にする（DIP、SongDatabaseService と同型）。
  final PlayRecordRepository playRecordRepository = FilePlayRecordRepository(
    documentsDirectoryResolver: () async => documentsDirectory,
  );

  // FR-1: 共有インテント受信機（冷温起動両対応）。
  final SharingIntentReceiver sharingIntentReceiver = SharingIntentReceiver();

  runApp(
    ScoremanApp(
      ocrEngine: ocrEngine,
      songDatabaseService: songDatabaseService,
      playRecordRepository: playRecordRepository,
      mainSongRepository: mainSongRepository,
      additionalSongRepository: additionalSongRepository,
      sharingIntentReceiver: sharingIntentReceiver,
    ),
  );
}

/// PoC アプリのルートウィジェット。
class ScoremanApp extends StatelessWidget {
  const ScoremanApp({
    super.key,
    required this.ocrEngine,
    required this.songDatabaseService,
    required this.playRecordRepository,
    required this.mainSongRepository,
    required this.additionalSongRepository,
    required this.sharingIntentReceiver,
  });

  /// ホーム画面へ渡す OCR エンジン。アプリ全体で単一インスタンスを使い回す。
  final OcrEngine ocrEngine;

  /// ホーム画面へ渡す収録曲 DB 操作サービス（抽象のみを渡す・DIP）。
  final SongDatabaseService songDatabaseService;

  /// ホーム画面へ渡すプレイ記録リポジトリ（抽象のみを渡す・DIP）。
  final PlayRecordRepository playRecordRepository;

  /// OCR パイプラインへ渡すメイン DB リポジトリ（抽象のみを渡す・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  /// null の場合はシード辞書のみで動作する（本番の main.dart は常に実体を渡す）。
  final SongRepository? mainSongRepository;

  /// OCR パイプラインへ渡すローカル追加 DB リポジトリ（抽象のみを渡す・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  final SongRepository? additionalSongRepository;

  /// FR-1: 共有インテント受信機（冷温起動両対応）。
  final SharingIntentReceiver sharingIntentReceiver;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'スコアヨミPM',
      // WHY: 日本語専用アプリなので ja を明示する。宣言しないと MaterialApp の
      // 既定 supportedLocales が en_US のままになり、Android の CJK フォールバックが
      // 簡体字（SC）を選ぶため、漢字が中国語字形で描画される（直・骨・次・令 などで顕著）。
      // locale 単独では MaterialLocalizations が無くて落ちるので delegates と
      // supportedLocales を必ず対で指定する。
      locale: const Locale('ja'),
      supportedLocales: const <Locale>[Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        // WHY: ロケール指定だけでは端末のフォント資産に依存する。同梱フォントを
        // 既定に固定すれば、CJK の JP 字形を持たない ROM でも字形が変わらない。
        fontFamily: 'BIZUDPGothic',
      ),
      home: HomeScreen(
        ocrEngine: ocrEngine,
        songDatabaseService: songDatabaseService,
        playRecordRepository: playRecordRepository,
        mainSongRepository: mainSongRepository,
        additionalSongRepository: additionalSongRepository,
        sharingIntentReceiver: sharingIntentReceiver,
      ),
    );
  }
}
