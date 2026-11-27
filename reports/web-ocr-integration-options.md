# Web 版 OCR の組み込み経路（Tier B-3）

作成: 2026-11-25（リーダー。teammate のメッセージ配信が失敗したため代行）
前提: `feature/web`。Node.js / npm / npx は**この開発機に無い**。Node の導入はユーザー承認事項のため未実施。
断定できない値は「推定」と明記する。

## 1. 実測した事実（npm レジストリ / jsDelivr の API から取得）

### `@paddleocr/paddleocr-js` 0.4.2（Apache-2.0）

| 項目 | 値 | 出所 |
| --- | --- | --- |
| 配布形態 | **ESM のみ**（`exports["."].import.default = ./dist/index.mjs`、CJS / UMD なし） | registry.npmjs.org |
| メインの js | `dist/index.mjs` = 81,588 B | data.jsdelivr.com |
| ワーカー用 js | `dist/assets/worker-entry-*.js` = **11,341,486 B**（+ sourcemap 12.1 MB） | 同上 |
| 同梱物 | 71 ファイル、展開後 23,798,562 B（**モデルは含まない**） | registry.npmjs.org |
| 実行時依存 | `@techstark/opencv-js ^4.10`, `onnxruntime-web ^1.22`, `clipper-lib ^6.4`, `js-yaml ^4.1` | 同上 |
| モデル | **`inference.onnx` と `inference.yml` を tar に詰めたものを `url:` で指定**する方式。同梱されない | README |

依存パッケージの展開後サイズ（新版の値。PaddleOCR が要求する版とは限らない）:

| パッケージ | ライセンス | 展開後 |
| --- | --- | --- |
| `@techstark/opencv-js` 5.0.0 | Apache-2.0 | 14,731,296 B |
| `onnxruntime-web` 1.31.1 | MIT | 150,622,959 B（全変種の合計。実際に配るのは wasm と js の数個） |
| `clipper-lib` 6.4.2 | BSL（Boost Software License。**GPL 系ではない**） | 214,824 B |
| `js-yaml` 5.0.0 | MIT | 1,626,579 B |

README から読み取れる追加の制約:

- `wasmPaths` の既定は **`https://cdn.jsdelivr.net/npm/onnxruntime-web/dist/`**。自前ホスティングしない限り
  実行時に外部へ取得しに行く。
- Worker モード（`worker: true`）は「**モジュールワーカーを出力・読み込みできるバンドラ／実行環境**」を要求する。
  → バンドラ無しでは成立しない。**メインスレッド（シングルスレッド）固定**が前提になる（D-W3 と整合）。

## 2. ボトルネックは「バンドラ無し」ではなく「bare import の解決」

`dist/index.mjs` は `onnxruntime-web` / `@techstark/opencv-js` などを **bare specifier** で import する。
ブラウザは bare specifier を解決できないため、`web/` に js を置いて `<script type="module">` で読むだけでは動かない。
必要なのは次のいずれか。

| 経路 | Node の要否 | 判定 | 理由 |
| --- | --- | --- | --- |
| A. import map で bare specifier を自前ホスティング先へ割り当てる | 不要 | **条件付きで可能** | `web/index.html` に `<script type="importmap">` を足し、各依存の ESM 配布物を `web/vendor/` へ手で置く。ブラウザ標準機能だけで解決できる。ただし 5 パッケージ ×（js + wasm）のバージョン整合を手作業で維持することになる |
| B. esbuild 等で 1 回だけバンドルし、成果物を `web/vendor/` にコミット | **要（1 回だけ）** | **推奨** | 以後 Node 不要。bare import もモデル取得も 1 ファイルに畳める。リポジトリに入るのは生成物のみ |
| C. CDN の事前バンドル（esm.sh 等）を実行時に読む | 不要 | **却下** | 実行時に外部へ取得しに行く。外部送信なし・オフライン動作の要件を満たせない |
| D. Tesseract.js に切り替える | 不要 | 保留 | Tesseract.js は UMD と ESM の配布があり、`jpn` 学習データを自前ホスティングすれば import map 無しで動く見込み。精度の見込みは PaddleOCR より低い |

## 3. サイズの見込み（すべて推定。実測は未実施）

| 内訳 | 推定 | 根拠 |
| --- | --- | --- |
| opencv-js（js + wasm） | 8〜14 MB | パッケージ展開後 14.7 MB（5.x） |
| onnxruntime-web（wasm 数個 + js） | 6〜12 MB | 展開後 150 MB は全変種の合計。単一スレッド版でも複数 MB |
| PP-OCRv5 mobile モデル（det + rec、tar） | 10〜20 MB | ファイルサイズ未確認。**実装前に必ず実測すること** |
| 合計 | **24〜46 MB** | 上記の合算 |

**受け入れ基準「初回ダウンロード 15MB 以下」は満たせない見込み。** これは実装の工夫では解決せず、
基準そのものの見直しが必要（§5）。

なおアプリ本体は既に `build/web` で約 51 MB（`reports/web-bundle-budget.md`）。OCR の追加分だけを
15 MB に収めるという基準だったとしても、上記の見込みでは超過する。

## 4. ライセンス

- `@paddleocr/paddleocr-js`: Apache-2.0。**NOTICE の同梱が必要**（Apache-2.0 §4(d)）。
  Flutter の `showLicensePage` は pub パッケージしか列挙しないため、`web/vendor/` に置く js の
  ライセンスは**別途、配信物へ同梱**する必要がある（例: `web/vendor/LICENSES/` に各 LICENSE / NOTICE を置き、
  `build/web` へそのまま複製されるようにする）。
- `@techstark/opencv-js`: Apache-2.0（NOTICE 同梱）。
- `onnxruntime-web`: MIT（著作権表示の同梱）。
- `js-yaml`: MIT。`clipper-lib`: BSL（Boost）。いずれも許容。
- GPL / AGPL / SSPL は検出されず。

## 5. リーダーが決めるべきこと

1. **Node.js を開発環境へ導入するか**（ユーザー承認事項）。
   推奨: 導入する。用途は「esbuild で 1 回バンドルして生成物をコミットする」だけで、
   アプリのビルド経路（`flutter build web`）には組み込まない。手作業の import map 保守は
   依存 5 パッケージのバージョン整合を人手で保つことになり、再現できない。
2. **「初回ダウンロード 15MB 以下」の基準をどうするか**（ユーザー承認事項）。
   推奨: 基準を「**初回表示に OCR を含めない**」に置き換える。OCR 一式（推定 24〜46 MB）は
   利用者が初めて読み取りを実行したときに遅延取得し、Cache API / IndexedDB に保持する。
   アプリ本体（51 MB）に上乗せしても初回体験は悪化しない。
3. **vendoring を選ぶ場合、リポジトリへ何 MB 入るか**: 推定 20〜40 MB。
   GitHub のリポジトリ推奨上限 1 GB に対しては問題ないが、clone が重くなる。
   代替として「リリース時に Pages へ配置するだけで、リポジトリには入れない」も選べる（要ビルド手順の整備）。
4. **モデルの取得元**: 公式モデル tar の URL とサイズは未確認。実装前に一次情報で確定させる。
5. **Tesseract.js を先に試すか**: サイズ面では有利（推定 5〜8 MB）。精度の見込みは低い。
   「まず動くものを通す」なら Tesseract.js、「精度を優先する」なら PaddleOCR.js。**判断は未了**。

## 6. 次にやること（決まった場合）

1. Node 導入の可否が決まったら、esbuild で `@paddleocr/paddleocr-js` を単一 ESM にバンドルし、
   `web/vendor/` へ配置。サイズを実測して本レポートを更新する（推定を実測で置き換える）。
2. `web/index.html` から `globalThis.PaddleOcrFactory` を作り、`dart:js_interop` の `@JS()` から呼ぶ。
3. 原画像を `Uint8List` のまま JS へ渡し、結果を `OcrPageResult` へ変換する薄いアダプタを実装し、
   `OcrEngine` の Web 実装（現在の `UnsupportedOcrEngine`）と差し替える。
4. 精度測定は既存の `integration_test/ocr_batch_*` の画像セットを使い、ML Kit 版と −3pt 以内かを判定する。
