# 計測ハーネス文書（ac_v1 校正）

30 枚実機写真（`testimage/AC-HC-photo/`）を用いた ac_v1 校正の計測ハーネスと成果物の所在。
本ファイルの以前の版には「テンプレート生成完了」等の事実と異なる記載があり、2026-11-23 に
リードが全容を引き取り、実測に基づいて書き直した。

## batch_measurement_output.txt

- エミュレータ実機 30 枚一括計測（`integration_test/ocr_batch_ac_test.dart`）の stdout 記録。
- 30 記録の JSONL（file/elapsedMs/elementCount/elements/fullText）+ summary 行。
- ac 校正の一次データ。要素 bbox は生写真座標（1-38px のはみ出しは ML Kit の正常挙動）。

## generate_overlays.ps1 / .tmp_measure.ps1

- PowerShell 補助スクリプト。`tool/generate_ac_overlay.dart` を 30 枚分呼び出し、
  `build/ac_overlay_batch/` へオーバーレイ JPG を生成する。
- 注意: オーバーレイは canonical 位置に枠を描いた「位置の可視化」であり、
  NCC テンプレート PNG ではない。実 NCC テンプレートは
  `tool/generate_ac_anchor_templates.dart` が `assets/anchors/ac_v1/label_*.png`
  として生成する（7 枚・モーダル解像度 2048x1536 基準）。
- `.tmp_measure.ps1` は作業用の一時スクリプト（コミット対象外・任意整理）。

## 実測校正の流れ

1. ML Kit batch measurement → `lib/ocr/batch_measurement_output.txt`（30 枚）。
2. `tool/build_ac_fixture.dart` → `test/fixtures/ocr/ac_hc_batch_results.json`
   （画像寸法焼き込み・回転疑いなし）。
3. `tool/measure_ac_windows.dart` → dx 窓実測（`lib/ocr/field_extractor.dart` の
   `_acV1Windows` へ反映済み）+ 抽出率ベースライン。
4. `tool/generate_ac_anchor_templates.dart` → 主群 4:3横バケット（23 枚）中央値
   canonical + モーダル解像度 2048x1536 から NCC テンプレート 7 枚生成 +
   frameRight 画素実測（canonical 0.8633）。
5. `test/ac_batch_extraction_test.dart`（抽出率回帰ゲート・ランタイム基準）+
   `test/ac_anchor_pack_contract_test.dart`（asset 契約: 定数ミラー・canonical 固定）。

## 現在の状態（2026-11-23 実測校正完了時点）

- 30/30 枚の ML Kit 一括計測完了（回転疑いなし）。
- 抽出率ランタイム基準（`_parseNumericValue` の 1 文字復元込み）:
  score 27/30, cool 29/30, great 26/30, good 17/30, bad 14/30, maxCombo 29/30。
- NCC テンプレート 7 枚生成 + canonical 実測化 + asset 契約テスト緑。
- 検証で判明した限界（正直な報告）:
  - 単一スケール NCC はモーダル解像度 2048x1536 近傍でしか当たらない
    （4K 写真はほぼ 0・1024x768 も低い）。テーブルは `tool/ac_generate_output.txt`。
  - score のヒット誤差中央値 205px（2048px 幅基準）: ヒットが BEST SCORE 行の
    另一の SCORE 要素へ着く誤着を含む。
  - frameRight は列強度中央値 18.6 < 閾値 25 でヒット 3/30（ac 画面には
    その位置に安定した全高エッジがない）。
  - これらは抽出機能への影響がない（ac 幾何は ML Kit テキストアンカー主経路が
    NCC パックアンカーを消費しない）。マルチスケール対応は未決課題
   （裁定 Q3: フォールバック必要 → 01a2065a）。

## 関連ファイル

- `test/fixtures/ocr/ac_hc_batch_results.json` - 実機計測の正（寸法焼き込み）。
- `tool/ac_generate_output.txt` - テンプレート生成 + 検証サマリの全出力。
- `docs/ocr_ac_field_remeasurement_design_2026-11-23.md` - フィールド別再計測設計
  （誤読語彙の実測表と回収経路）。
