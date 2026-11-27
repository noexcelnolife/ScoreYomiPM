import 'package:material_ui/material_ui.dart';

import 'data/memo_template_repository.dart';
import 'data/play_record_repository.dart';
import 'ocr/ocr_engine.dart';
import 'ocr/ocr_engine_factory.dart';
import 'ocr/song_repository.dart';
import 'platform/app_environment.dart';
import 'platform/app_environment_factory.dart';
import 'platform/platform_capabilities.dart';
import 'songdb/song_database_service.dart';
import 'ui/home_screen.dart';
import 'ui/sharing_intent_receiver.dart';

/// アプリの組み立て（コンポジションルート）。
///
/// WHY(ここで環境判定をしないか): `main` は「何を組み立てて誰に渡すか」だけを
/// 書き、環境ごとの差は `createAppEnvironment()` / `createOcrEngine()` の
/// 条件付き export に閉じる。ここで `kIsWeb` や `Platform.isAndroid` を書くと、
/// 起動経路そのものが環境ごとに枝分かれし、Web で起動しない不具合（白画面）を
/// 追いにくくなる。
///
/// WHY(起動前にプラグインを呼ばないか): `runApp` より前の例外は画面を持たない
/// まま落ちる。Web に実装が無いプラグイン（documents ディレクトリ等）を
/// 無条件に呼ぶと白画面になるため、環境ごとの実装側で解決する。
Future<void> main() async {
  final AppEnvironment environment = await createAppEnvironment();

  runApp(
    ScoremanApp(
      capabilities: environment.capabilities,
      // WHY(ここで dispose しないか): runApp 後は制御が戻らず、プロセス終了時に
      // OS 側でネイティブリソースが回収される。
      ocrEngine: createOcrEngine(),
      songDatabaseService: environment.songDatabaseService,
      playRecordRepository: FilePlayRecordRepository(
        blobStore: environment.blobStore,
      ),
      mainSongRepository: environment.mainSongRepository,
      additionalSongRepository: environment.additionalSongRepository,
      sharingIntentReceiver: SharingIntentReceiver(),
      memoTemplateRepository: environment.memoTemplateRepository,
    ),
  );
}

/// アプリのルートウィジェット。
class ScoremanApp extends StatelessWidget {
  const ScoremanApp({
    super.key,
    required this.capabilities,
    required this.ocrEngine,
    required this.songDatabaseService,
    required this.playRecordRepository,
    required this.mainSongRepository,
    required this.additionalSongRepository,
    required this.sharingIntentReceiver,
    this.memoTemplateRepository,
  });

  /// この環境で可能な操作（UI はここだけを見る）。
  final PlatformCapabilities capabilities;

  /// ホーム画面へ渡す OCR エンジン。アプリ全体で単一インスタンスを使い回す。
  final OcrEngine ocrEngine;

  /// ホーム画面へ渡す収録曲 DB 操作サービス（抽象のみを渡す・DIP）。
  final SongDatabaseService songDatabaseService;

  /// ホーム画面へ渡すプレイ記録リポジトリ（抽象のみを渡す・DIP）。
  final PlayRecordRepository playRecordRepository;

  /// OCR パイプラインへ渡すメイン DB リポジトリ（抽象のみを渡す・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  /// null の場合はシード辞書のみで動作する。
  final SongRepository? mainSongRepository;

  /// OCR パイプラインへ渡すローカル追加 DB リポジトリ（抽象のみを渡す・DIP）。
  ///
  /// WHY: null 許可は OcrPipeline の optional パラメータ契約に合わせたもの。
  final SongRepository? additionalSongRepository;

  /// FR-1: 共有インテント受信機（冷温起動両対応）。
  ///
  /// WHY(能力が無い環境でも生成するか): 生成自体はプラグインを呼ばないため安全で、
  /// 購読の有無は `capabilities.canReceiveShareIntent` で決める。ここで null を
  /// 許すと、呼び出し側すべてに null 判定が増える。
  final SharingIntentReceiver sharingIntentReceiver;

  /// メモのテンプレート供給元（任意）。
  ///
  /// WHY null 許容か: テンプレートはメモ入力の補助にすぎず、無くても入力・保存は
  /// 成立する。null なら入力画面で「テンプレート」ボタンを出さない。
  final MemoTemplateRepository? memoTemplateRepository;

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
        capabilities: capabilities,
        ocrEngine: ocrEngine,
        songDatabaseService: songDatabaseService,
        playRecordRepository: playRecordRepository,
        mainSongRepository: mainSongRepository,
        additionalSongRepository: additionalSongRepository,
        sharingIntentReceiver: sharingIntentReceiver,
        memoTemplateRepository: memoTemplateRepository,
      ),
    );
  }
}
