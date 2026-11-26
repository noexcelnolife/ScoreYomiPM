// アプリのバージョン表記（タスク 01a20c14）。
//
// WHY: バックアップ manifest に「どの版で作ったか」を記録したいが、そのためだけに
// package_info_plus を足すとプラットフォームチャネル依存が増える。リリース手順を
// 増やさない方針（リード裁定 2026-11-24）で定数を持つ。
//
// WHY(テストで突合): 定数は手動同期なのでリリース時に更新し忘れる。pubspec.yaml の
// version と一致することを test/app_info_test.dart が検証し、ずれたら落ちる。
// ずれても復元は壊れない（データ層はこの値を検証に使わない・表示専用）。
//
// WHY(kAppVersion): リードの呼称が kAppVersion だったため、この名前で公開する
// （バックアップ manifest の appVersion フィールドとは別物）。
const String kAppVersion = '1.0.0+1';
