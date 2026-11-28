/// 収録曲 DB の操作を提供しない環境向けの [SongDatabaseService]。
///
/// WHY(実装を用意するか): Web 版は辞書の配信更新・追加取り込みを行わない
/// （`PlatformCapabilities.canUpdateSongDatabase == false`）。UI 側は入口を
/// 隠すが、隠し漏れや将来の導線追加で呼ばれても**落ちない**ことを保証する。
/// 失敗は戻り値で表し、例外にしない（失敗が想定内の操作のため）。
library;

import 'dart:typed_data';

import 'song_database_service.dart';

/// 常に「未対応」を返すサービス。
class UnsupportedSongDatabaseService implements SongDatabaseService {
  const UnsupportedSongDatabaseService();

  /// 未対応であることを示すメッセージ。
  static const String _message = 'この環境では曲データベースの更新に対応していません。';

  @override
  Future<String> loadDistributionUrl() async => '';

  @override
  Future<SongDatabaseStatus> loadStatus() async {
    return const SongDatabaseStatus(
      distributionUrl: '',
      main: SongDbSourceStatus(exists: false),
      additional: SongDbSourceStatus(exists: false),
    );
  }

  @override
  Future<void> saveDistributionUrl(String url) async {
    // 保存先が無いため何もしない（URL は端末ごとの設定であり、
    // 未対応環境で保持しても更新に使えない）。
  }

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async {
    return const SongDbUpdateResult(
      status: SongDbUpdateStatus.failed,
      message: _message,
    );
  }

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async {
    return const SongDbUpdateResult(
      status: SongDbUpdateStatus.failed,
      message: _message,
    );
  }

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async {
    return const SongImportResult(success: false, message: _message);
  }
}
