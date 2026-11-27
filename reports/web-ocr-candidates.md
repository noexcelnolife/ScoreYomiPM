# Web 版 OCR エンジン候補 比較表 (Tier B-1 調査報告)

## 0. 概要

- **タスク**: Tier B-1: Web 版で使える OCR エンジンの調査（実装しない・比較表を作る）
- **成果物**: `wt/feature-web/reports/web-ocr-candidates.md`（本ファイル）
- **制約**: 調査のみ。`lib/` や `pubspec.yaml` へのコード変更・実装は行わない。Flutter Web への組み込み検討材料として比較表と推奨をまとめる。
- **ブランチ/ワークツリー**: `feature/web` / `wt/feature-web`（基点 `main` @ `7d4dd88` = v1.0.3+4）。コミットはワークツリー内で行い、**push しない**。

## 1. 受け入れ基準（リーダー提示）

Web 版 OCR エンジンを採用するには、以下をすべて満たす必要がある。

| No. | 受け入れ基準 |
|:---:|---|
| A-1 | 一致率が ML Kit 比 −3pt 以内 |
| A-2 | 初回ダウンロード ≤15MB |
| A-3 | オフライン動作（ブラウザ内完結） |
| A-4 | ブラウザ外サーバーへの外部送信なし |

追加のプロジェクト制約（ライセンス）:

| No. | 制約 |
|:---:|---|
| L-1 | GPL / AGPL / SSPL は採用不可（permissive ライセンスのみ許容） |

## 2. 評価方針・注記

- 本報告の数値（モデルサイズ・初回ダウンロード容量・一致率等）は **未実測** のものを「推定」と明記する。実装前に実測必須。
- 実測できない指標（一致率の pt 差等）は推定として扱い、「計測できない指標を計測済みと主張しない」。
- `dart:io` は Web ビルドで import できないため、Web 版では条件付き import（`if dart.library.io` / `if dart.library.js_interop`）が必須。現行 `OcrEngine` は `File` ベース（`lib/ocr/ocr_engine.dart`）なので、Web 移行時はバイト入力への変更が前提（web-migration-plan §技術判断）。
- マルチスレッド WASM / SharedArrayBuffer には COOP / COEP レスポンスヘッダーが必要（web-migration-plan §技術判断）。
- `flutter build web` 成功 ≠ ブラウザ動作保証。検証ゲートは `build/web` 配信後のブラウザで console エラー 0 件 + ホーム画面描画（web-migration-plan §検証ゲート）。

## 3. 比較表（基本情報）

| エンジン | 提供元 / ライセンス | バージョン / 最終リリース | 日本語 OCR 支援 (URL) | 初回ダウンロード (MB) | ランタイム (メモリ / 速度) | オフライン動作 | 外部送信 | Flutter Web での利用方法 | 既知の制約 |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| **Tesseract.js** | naptha / Apache-2.0 | v7.0.0 / 2025-12-15 | 対応（`@tesseract.js-data/jpn` v1.0.0, tessdata jpn）。https://github.com/naptha/tesseract.js, https://www.npmjs.com/package/@tesseract.js-data/jpn | 推定 10〜15 超（core WASM 数 MB + jpn.traineddata 推定 8〜11 MB。デフォルト構成で言語データ込み 15.34 MB の実績あり） | CPU WASM / Web Worker。メモリ 推定 数十 MB〜100 MB 級、速度 推定 中〜低（画像サイズ依存） | ○（自己ホスティング後、CDN 不要） | △（デフォルトは CDN 経由で第三者へ接続。自前ホスティングで回避可能） | `package:js` 経由で tesseract.js を呼び出し、`if dart.library.js_interop` の条件付き import で出し分け | スレッド化 WASM に COOP/COEP ヘッダー要。日本語は tessdata_fast/best の使い分け。画像デコードは別途必要 |
| **PaddleOCR.js**（`@paddleocr/paddleocr-js` 公式 SDK） | PaddlePaddle / Apache-2.0 | v0.4.2 / 最終公開 約 2026-07（npm「4 ヶ月前」） | 対応（`lang: "ch"`、PP-OCRv5 単一モデルで CJK incl. 日本語）。https://github.com/PaddlePaddle/PaddleOCR, https://www.npmjs.com/package/@paddleocr/paddleocr-js | 推定 20 超（det モバイル 数 MB + rec モバイル 16.5 MB + 辞書。遅延読み込みで分散可能） | ONNX Runtime Web（WASM または WebGPU backend、worker モード対応）。メモリ 推定 中〜高、速度 推定 中（モバイルモデル） | ○（モデルを IndexedDB / Service Worker でキャッシュ後） | ○（モデルは CDN / 自前ホスティング取得、推論はブラウザ内完結） | `package:js` + onnxruntime-web スクリプト読み込み、条件付き import で出し分け | マルチスレッドに COOP/COEP ヘッダー要。初回モデル取得にネットワーク要。OpenCV.js 前提のパスあり |
| **@ocr-web/core + @ocr-web/models-ppocrv5** | bent-hsu / MIT | core v0.2.0 / models-ppocrv5 v0.1.1（約 2026-07） | 対応（PP-OCRv5 CJK 18,384 文字 incl. 日本語）。https://www.jsdelivr.com/package/npm/@ocr-web/core | 推定 数十 KB（core）+ モデル det+rec 約 20 超（同上） | onnxruntime-web ピア依存、`wasmPaths` 設定要。メモリ/速度 推定 Paddle 相当 | ○（モデルキャッシュ後） | ○（モデルは CDN / 自前ホスティング取得、推論はブラウザ内完結） | `package:js`、条件付き import で出し分け | `wasmPaths` 設定要、COOP/COEP ヘッダー要、モデルサイズ |
| **transformers.js + GLM-OCR / Florence-2** | Hugging Face / MIT | transformers.js v3 系 / GLM-OCR 0.9B | 誤認識報告あり（日本語は 1286px でも誤認、実用的でないとの報告）。https://github.com/huggingface/transformers.js | 推定 100 超（0.9B 級 VL モデル） | WebGPU 優先 / WASM フォールバック。メモリ 推定 高、速度 推定 低〜中（CPU フォールバック時） | ○（モデルキャッシュ後） | ○（推論はブラウザ内完結） | `package:js`、条件付き import で出し分け | モデル巨大で初回ダウンロード基準を大幅超過。日本語精度不安 |
| **クラウド API**（参考：Google Cloud Vision / AWS Textract / Azure Document Intelligence） | 各社 / 従量課金・独自条件 | 各社 API | 対応あり（Textract 東京リージョン等で日本語対応） | 数 KB（SDK のみ） | サーバー側推論、ネットワーク依存 | × | ×（画像をサーバーへ送信） | `http` パッケージで REST API 呼び出し | 「外部送信なし」基準に不適合。API キー管理・通信コスト・遅延あり |

### 補足：除外済み候補

| エンジン | 除外理由 |
|:---|:---|
| **meikiocr-web** | GPL-3.0-only。L-1（GPL/AGPL/SSPL 禁止）に抵触 |

## 4. 受け入れ基準ごとの ○△× 判定

| エンジン | A-1 一致率 −3pt 以内 (ML Kit 比) | A-2 初回 DL ≤15MB | A-3 オフライン | A-4 外部送信なし | 評価理由（1 行） |
|:---|:---:|:---:|:---:|:---:|:---|
| Tesseract.js | △（推定） | △（推定） | ○ | △ | 日本語対応・オフライン可能だが jpn 言語データ込みで 15 MB 付近〜超過の見込み；デフォルト CDN 接続は自前ホスティングで回避可能 |
| PaddleOCR.js (PP-OCRv5) | ○（推定） | △（推定） | ○ | ○ | PP-OCRv5 は ML Kit に近い精度の見込みだが det+rec モバイルで 20 MB 超の見込み；遅延読み込みで回避可能 |
| @ocr-web PP-OCRv5 | ○（推定） | △（推定） | ○ | ○ | ラッパー自体は軽量だがモデルサイズは Paddle 相当 |
| transformers.js (GLM-OCR) | ×（推定） | ×（推定） | ○ | ○ | 日本語誤認報告あり；0.9B モデルで 15 MB を大幅超過 |
| クラウド API（参考） | ○ | ○ | × | × | 画像を外部サーバーへ送信するため「外部送信なし」に不適合 |

## 5. 最初に試すべき 1 つ

**PaddleOCR.js（`@paddleocr/paddleocr-js`、PP-OCRv5 mobile）**

### 推奨理由

1. **ライセンス適合**: Apache-2.0（permissive）。PaddlePaddle 公式のブラウザ OCR SDK でメンテナンス活発。
2. **日本語対応**: `lang: "ch"` の PP-OCRv5 単一モデルで CJK（簡体字／繁体字／日本語／英語）をカバー。ML Kit に近い一致率の見込み（未実測・推定）。
3. **オフライン・外部送信なし**: ONNX Runtime Web / WebGPU でブラウザ内推論。モデルを IndexedDB 等にキャッシュすれば A-3 / A-4 を満たせる。
4. **Flutter Web 親和性**: `package:js` + 条件付き import で単一コードベースに組み込みやすい（web-migration-plan §技術判断と整合）。

### 実施前に確認すべき課題

- **初回ダウンロード ≤15MB**: det+rec モバイルで 20 MB 超の見込み。モデルの遅延読み込み・IndexedDB キャッシュ・量子化（INT8）モデルの検証を先に行い、実測で A-2 を検証すること。
- **日本語一致率 −3pt 以内**: ML Kit との実機比較計測が必須。計測前に「−3pt 以内」を主張しない。

### 代替案

**Tesseract.js**（Apache-2.0, v7.0.0）— 起動が軽量で実績豊富だが、日本語言語データ込みの初回ダウンロードが 15 MB 付近〜超過のボーダーラインで、デフォルトの CDN 接続は自前ホスティングが必要。

## 6. 情報源

1. naptha/tesseract.js (GitHub) — v7.0.0, 2025-12-15 リリース, Apache-2.0: https://github.com/naptha/tesseract.js
2. @tesseract.js-data/jpn (npm) — v1.0.0, MIT: https://www.npmjs.com/package/@tesseract.js-data/jpn
3. PaddlePaddle/PaddleOCR (GitHub) — PP-OCRv5 ブラウザ SDK, 日本語対応, 技術報告 arXiv:2507.05595: https://github.com/PaddlePaddle/PaddleOCR
4. @paddleocr/paddleocr-js (npm) — v0.4.2, Apache-2.0: https://www.npmjs.com/package/@paddleocr/paddleocr-js
5. @ocr-web/core (npm) — v0.2.0, MIT; @ocr-web/models-ppocrv5 (npm) — v0.1.1, MIT: https://www.jsdelivr.com/package/npm/@ocr-web/core
6. huggingface/transformers.js (GitHub) — MIT, GLM-OCR 0.9B: https://github.com/huggingface/transformers.js
7. note.com/ryoma_0923 — Transformers.js WebGPU による日本語 OCR の誤認識報告
8. naptha/tesseract.js Issue #806 — デフォルト構成での初回ダウンロード 15.34 MB 実績
9. Hasmolam/cosmic-ext-translator releases — PP-OCRv5 mobile rec.onnx 16.5 MB（日本語含む）

---

> 作成：2026-11-25（公開前監査 役割、調査のみ・実装なし）。本ファイルは `lib/` への変更を含まない。
