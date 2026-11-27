import '../data/memo_template_repository.dart';
import '../ocr/song_repository.dart';
import '../songdb/song_database_service.dart';
import 'blob_store.dart';
import 'platform_capabilities.dart';

/// 実行環境ごとに異なる組み立て結果の束。
///
/// WHY(束ねるか): 保存先・辞書サービス・能力フラグは互いに整合していなければ
/// ならない（例: 辞書更新ができない環境に「ファイル保存前提の辞書サービス」を
/// 渡すと、押した瞬間に落ちる）。環境ごとの実装ファイルで一度に決めて返せば、
/// `main` 側に環境判定が漏れず、組み合わせの誤りも起こらない。
///
/// WHY(null 許容の項目があるか): 辞書リポジトリとメモテンプレートは
/// 「無くても記録の作成・閲覧は成立する」補助データ。無い環境では null を渡し、
/// UI 側が該当の入口を出さない（`OcrResultScreen` のテンプレートボタンなど）。
class AppEnvironment {
  const AppEnvironment({
    required this.capabilities,
    required this.blobStore,
    required this.songDatabaseService,
    this.mainSongRepository,
    this.additionalSongRepository,
    this.memoTemplateRepository,
  });

  /// この環境で可能な操作。
  final PlatformCapabilities capabilities;

  /// 記録・画像・テンプレートの保存先。
  final BlobStore blobStore;

  /// 収録曲 DB の配信更新サービス。
  final SongDatabaseService songDatabaseService;

  /// 配信で取得したメイン曲 DB（未取得なら null = シードのみで動作）。
  final SongRepository? mainSongRepository;

  /// ユーザーが追加した曲 DB（未追加なら null）。
  final SongRepository? additionalSongRepository;

  /// メモのテンプレート供給元（未対応環境では null）。
  final MemoTemplateRepository? memoTemplateRepository;
}
