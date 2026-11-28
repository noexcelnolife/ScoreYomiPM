import 'platform_capabilities.dart';

/// ブラウザ版の能力。
///
/// 画像の取り込みから OCR、結果画面への反映までは Android 版と同じく動く。
/// 対応していないのは次の 3 点で、いずれも「ブラウザという環境の都合」である。
///
/// - **初回の OCR に時間がかかる**（[canPickImages] は true のまま）。
///   推論はブラウザ内（WebAssembly）で行うため、初回だけ認識エンジンと
///   モデルをまとめて取得する。実測で約 69MB（うちモデル 21.5MB）。
///   2 回目以降はブラウザのキャッシュとエンジンの再利用で短くなる。
///   待ち時間の説明は `OcrEngine.isPreparing` を見て画面が出す。
/// - **カメラで撮影できない**（[canCaptureWithCamera] は false）。
///   ブラウザからカメラを直接開く標準的な手段が無い（`capture` 属性は
///   モバイルのブラウザでしか効かない）。代わりに OS のファイル選択を開く
///   （[imagePickerLabel] は「ファイルを選択」）。押しても何も起きない導線は
///   残さない。
/// - **共有の受け取りができない**（[canReceiveShareIntent] は false）。
///   共有インテントはモバイル OS の仕組みで、ブラウザに対応する受け口が無い。
///
/// 辞書は URL からの更新を行わない（[canUpdateSongDatabaseFromUrl] は false）。
/// 取得は `package:http` 経由でブラウザの fetch に落ちるため、配信元が
/// ブラウザからの取得（CORS）を許すか未確認であることが理由。確認が取れたら
/// 有効にしてよい。追加 JSON の取り込みはファイル選択で行える
/// （[canImportSongDatabaseJson]）。
///
/// これらは「未対応」ではなく「この環境では行わない」という製品判断であり、
/// 記録の作成・閲覧・画像表示・ZIP バックアップは引き続き利用できる。
class WebCapabilities implements PlatformCapabilities {
  const WebCapabilities();

  @override
  bool get canPickImages => true;

  @override
  bool get canCaptureWithCamera => false;

  /// ブラウザが開くのは OS のファイル選択なので、そちらの呼び名にする。
  @override
  String get imagePickerLabel => 'ファイルを選択';

  @override
  bool get canReceiveShareIntent => false;

  @override
  bool get canUpdateSongDatabaseFromUrl => false;

  @override
  bool get canImportSongDatabaseJson => true;
}
