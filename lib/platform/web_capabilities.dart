import 'platform_capabilities.dart';

/// ブラウザ版の能力。
///
/// WHY(撮影・共有インテント・辞書更新を無効にするか):
/// - 撮影・ギャラリー取り込みは OCR が前提で、Web 版の OCR エンジンは未搭載。
///   押しても必ず失敗する導線を残さない。
/// - 共有インテントはモバイル OS の仕組みで、ブラウザには対応する受け口が無い。
/// - 辞書更新は「端末に保存済みの JSON を差し替える」処理で、追加 JSON の
///   取り込みはファイルパスを前提にしている。Web にはパスの概念が無い。
///
/// これらは「未対応」ではなく「この環境では行わない」という製品判断であり、
/// 記録の作成・閲覧・画像表示・ZIP バックアップは引き続き利用できる。
class WebCapabilities implements PlatformCapabilities {
  const WebCapabilities();

  @override
  bool get canCaptureImages => false;

  @override
  bool get canReceiveShareIntent => false;

  @override
  bool get canUpdateSongDatabaseFromUrl => false;

  @override
  bool get canImportSongDatabaseJson => true;
}
