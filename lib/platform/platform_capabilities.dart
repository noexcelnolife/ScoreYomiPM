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
  /// カメラ・ギャラリーから画像を取り込み、OCR を実行できるか。
  bool get canCaptureImages;

  /// 他アプリからの共有インテントを受け取れるか。
  bool get canReceiveShareIntent;

  /// 曲データベースの配信更新（URL 取得・追加 JSON の取り込み）ができるか。
  bool get canUpdateSongDatabase;
}

/// 端末アプリ（Android/iOS 相当）の能力。すべて有効。
class LocalCapabilities implements PlatformCapabilities {
  const LocalCapabilities();

  @override
  bool get canCaptureImages => true;

  @override
  bool get canReceiveShareIntent => true;

  @override
  bool get canUpdateSongDatabase => true;
}
