// Flutter Web の起動スクリプト（テンプレート）。
// `flutter build web` はこのファイルの {{...}} を実体に置き換えて
// build/web/flutter_bootstrap.js を作る。
//
// WHY(自前で持つか): 既定の生成物は
//   _flutter.loader.load({ serviceWorkerSettings: { serviceWorkerVersion: "..." } })
// を呼び、Flutter 製の service_worker スタブを登録する。そのスタブは
// 「自分を unregister して開いている全タブを強制リロードする」ため、
// 入力途中のフォームが消える。アプリ独自の web/service_worker.js を使うので、
// ここで null を渡して Flutter 側の登録を止める。
// 詳細は web/service_worker.js の先頭コメントと reports/web-pwa-plan.md。

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: null,
});
