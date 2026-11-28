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
`build.mjs` は両者の版を実際に読み比べ、食い違えばエラーで止まる（37 MiB を無駄に配らないため）。

`paddleocr-js` が既定で参照する CDN の版も 1.24.3 であり、固定によってそれと揃う。
`wasmPaths` は必ずローカルへ向けること（CDN 既定のままでは外部依存が残る）。

## 改変について

Apache-2.0 の要求に従い、改変したファイルを明示する。

- `web/ocr_vendor/paddleocr.bundle.js` は `dist/index.mjs` を esbuild でバンドル・minify したもの。
  **ソースの改変は行っていない**（`--external:fs --external:path` はバンドラ側の解決指示であり、
  ソースの書き換えではない）。
- `web/ocr_vendor/assets/worker-entry-*.js` は `dist/assets/` の**無改変コピー**。
- `web/ocr_vendor/ort-wasm-simd-threaded.wasm` は `onnxruntime-web/dist/` の**無改変コピー**。
