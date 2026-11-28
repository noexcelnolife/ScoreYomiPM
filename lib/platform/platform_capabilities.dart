/// 実行環境ごとに「できること」を表す能力フラグ。
///
/// WHY(UI に環境判定を書かせないか): `kIsWeb` や `Platform.isAndroid` を
/// ウィジェットへ散らすと、同じ画面が環境ごとに別物になり、テストで
/// 片方の環境しか検証できなくなる。能力は組み立て時（`main`）に注入し、
/// UI は「この能力があるか」だけを見る。
///
/// WHY(4 つに絞るか): 分岐が実際に必要になった能力だけを持つ。使われない
/// フラグは「対応済み」という誤解を生む。保存先の選択や共有の実装差は
/// ゲートウェイの条件付き実装側で吸収済みで、フラグを要さない。
abstract class PlatformCapabilities {
  /// 画像ファイルを選んで取り込めるか（端末のギャラリー／ブラウザの
  /// ファイル選択を問わない）。
  ///
  /// WHY(撮影と分けるか): 取り込みの入口は「保存済みの画像を選ぶ」と
  /// 「その場で撮る」の 2 つがあり、環境によって使える方が違う。1 つの
  /// フラグにまとめると「撮れないから選べない」という誤った含意が生まれ、
  /// ブラウザ版で読み取り導線まで閉じてしまう。
  bool get canPickImages;

  /// カメラで撮影して画像を取り込めるか。
  bool get canCaptureWithCamera;

  /// 画像を選ぶ入口の呼び名。
  ///
  /// WHY(呼び名まで能力にするか): ブラウザが開くのは OS のファイル選択で、
  /// 「ギャラリー」ではない。だが UI に `kIsWeb` を書かない方針なので、
  /// 環境ごとに変わる文言も能力として注入する。`canCaptureWithCamera` から
  /// 推測すると「カメラが無い＝ブラウザ」という誤った結び付きが残る。
  String get imagePickerLabel;

  /// 他アプリからの共有インテントを受け取れるか。
  bool get canReceiveShareIntent;

  /// 配信 URL からの取得・更新ができるか。
  bool get canUpdateSongDatabaseFromUrl;

  /// ローカル JSON の取り込みができるか。
  bool get canImportSongDatabaseJson;
}

/// 端末アプリ（Android/iOS 相当）の能力。すべて有効。
class LocalCapabilities implements PlatformCapabilities {
  const LocalCapabilities();

  @override
  bool get canPickImages => true;

  @override
  bool get canCaptureWithCamera => true;

  @override
  String get imagePickerLabel => 'ギャラリーから選択';

  @override
  bool get canReceiveShareIntent => true;

  @override
  bool get canUpdateSongDatabaseFromUrl => true;

  @override
  bool get canImportSongDatabaseJson => true;
}
