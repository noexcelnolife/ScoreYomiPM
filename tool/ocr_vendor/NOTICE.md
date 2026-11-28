# Web 版 OCR の第三者ソフトウェア

`tool/ocr_vendor/build.mjs` が `npm` で取得し、`web/ocr_vendor/` に配置するもの。
生成物はリポジトリに含めない（`reports/web-decisions.md` D-W16）。
各パッケージの LICENSE 全文は `build.mjs` が `web/ocr_vendor/licenses/` へ複製する。

| パッケージ | 版 | ライセンス | 用途 |
|---|---|---|---|
| `@paddleocr/paddleocr-js` | 0.4.2 | Apache-2.0 | OCR 本体（前処理・推論・後処理） |
| `@techstark/opencv-js` | ^4.10.0-release.1 | Apache-2.0 | 画像の前処理（OpenCV の WASM ビルド） |
| `onnxruntime-web` | **1.24.3 固定** | MIT | ONNX モデルの推論実行 |
| `js-yaml` | ^4.1.0 | MIT | モデル設定（YAML）の解析 |
| `clipper-lib` | ^6.4.2 | BSL-1.0 | 多角形演算（検出枠の整形） |
| `esbuild` | 0.28.2 | MIT | ビルド時のみ。配布物には含まれない |

## 版の固定

`package.json` の直接依存は版を固定し、推移依存は `package-lock.json` で固定する。
`npm ci` はこの lockfile からのみインストールするため、再ビルドで同じ構成になる。

### `onnxruntime-web` を 1.24.3 に固定する理由

`@paddleocr/paddleocr-js` のワーカーは ONNX Runtime Web を**内包済み**で、その版は
`worker-entry-*.js` 内に `ONNX Runtime Web v1.24.3` と書かれている。wasm は JS 側の糊と
版が一致しないと実行時に落ちる。`paddleocr-js` の宣言は `^1.22.0` なので、そのままでは
1.31.x が入り、**ワーカー内蔵の糊 1.24.3 と wasm 1.31.x が食い違う**。
`build.mjs` は両者の版を実際に読み比べ、食い違えばエラーで止まる。

`paddleocr-js` が既定で参照する CDN の版も 1.24.3 であり、固定によってそれと揃う。
`wasmPaths` は必ずローカルへ向けること（CDN 既定のままでは外部依存が残る）。

## 改変について

Apache-2.0 の要求に従い、改変したファイルを明示する。

- `web/ocr_vendor/paddleocr.bundle.js` は `dist/index.mjs` を esbuild でバンドル・minify したもの。
  **ソースの改変は行っていない**（`--external:fs --external:path` はバンドラ側の解決指示であり、
  ソースの書き換えではない）。
- `web/ocr_vendor/assets/worker-entry-*.js` は `dist/assets/` の**無改変コピー**。
- `web/ocr_vendor/ort-wasm-simd-threaded.jsep.mjs` と `ort-wasm-simd-threaded.jsep.wasm` は
  `onnxruntime-web/dist/` の**無改変コピー**。

  jsep 版を配る理由: `onnxruntime-web` 1.24.3 の dist は webgpu 実行プロバイダを含む既定バンドルで、
  実行時に要求するのはこの 2 本（糊と本体）だけだった（ブラウザ実測）。jsep でない
  `ort-wasm-simd-threaded.wasm` は**一度も要求されない**。`ortOptions.backend` を `'wasm'` に
  固定しても jsep が選ばれる。糊（.mjs）を欠くと本体だけでは読めないため、必ず 2 本 1 組で配る。

## 同梱するモデル

PP-OCRv5 mobile の det / rec の 2 本だけを同梱する。**ビルド時に取得**し、SHA-256 で内容を固定する
（`build.mjs` の `MODEL_SOURCES`）。git には置かない。

| ファイル | バイト | SHA-256 | ライセンス |
|---|---|---|---|
| `PP-OCRv5_mobile_det.tar` | 4,843,520 | `781056046c9ed77a15c94681605db6a0f62317c2e9cce6931c71da2478d4bc30` | Apache-2.0 |
| `PP-OCRv5_mobile_rec.tar` | 16,701,440 | `f7e792bc836f36e7ef895ad47c426d75b0b75b1650caa6d63fe9418441ffba8c` | Apache-2.0 |

取得元（PaddlePaddle 公式のモデル置き場。いずれも `paddle3.0.0`）:

- `https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-OCRv5_mobile_det_onnx_infer.tar`
- `https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-OCRv5_mobile_rec_onnx_infer.tar`

### PP-OCRv6_tiny を採用しなかった理由

同梱していた `PP-OCRv6_tiny_det.tar` / `PP-OCRv6_tiny_rec.tar` は削除した。
認識辞書が 6,904 字で**かなを 1 文字も含まず**（`桜` も無い）ため、「千本桜」を「千本桉」と読む。
辞書への語彙追加では直らない構造的な不能であり、精度調整の対象にならない。

削除時に記録した SHA-256:

| ファイル | バイト | SHA-256 |
|---|---|---|
| `PP-OCRv6_tiny_det.tar` | 1,792,000 | `ff6ab415b0a6e0c488550f2fb5d5046f1719848df220b2dc21b56402a65bc05d` |
| `PP-OCRv6_tiny_rec.tar` | 4,526,080 | `1e13b22717b1edd89d4cde4fda272b6c17d5b505c97c2baea99da1a3a2d54b29` |
| `ppocr_keys_v1.txt` | 74,075 | `1ed855693cef6d875c437d68e01e9139bad40b769ac1264018306d512720553e` |
