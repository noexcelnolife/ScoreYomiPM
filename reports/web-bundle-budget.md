# Web ビルド成果物サイズ実測と GitHub Pages 制約 (Tier B-2)

## 0. 概要

- **タスク**: Tier B-2: Web ビルド成果物のサイズ実測と GitHub Pages 制約の確認
- **成果物**: `wt/feature-web/reports/web-bundle-budget.md`（本ファイル）
- **制約**: 読み取り専用調査＋ドキュメント作成のみ。`lib/` と `pubspec.yaml` は変更しない。`flutter build web --release` は実行してよい（`build/web` が更新されるだけ）。コミットはワークツリー内で行い、**push しない**。
- **用語**: 「スモークテスト」ではなく**「ビルド検証テスト」**と書く（ユーザー指示）。
- **ブランチ/ワークツリー**: `feature/web` / `wt/feature-web`（基点 `07d19ba`）。

## 1. ビルド検証テスト（`flutter build web --release`）の実行

### 実行コマンド

```powershell
cd C:\Users\ka\Documents\coding\ScoreYomiPM\wt\feature-web
$env:Path = "C:\dev\flutter\bin;" + $env:Path
flutter build web --release
```

### 生の出力（stdout/stderr 含む）

```
Compiling lib\main.dart for the Web...
Wasm dry run succeeded. Consider building and testing your application with the `--wasm` flag. See docs for more info: https://docs.flutter.dev/platform-integration/web/wasm
Use --no-wasm-dry-run to disable these warnings.
Font asset "CupertinoIcons.ttf" was tree-shaken, reducing it from 257628 to 844 bytes (99.7% reduction). Tree-shaking can be disabled by providing the --no-tree-shake-icons flag when building your app.
Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 3356 bytes (99.8% reduction). Tree-shaking can be disabled by providing the --no-tree-shake-icons flag when building your app.
Compiling lib\main.dart for the Web...                             49.5s
√ Built build\web
```

**終了コード: 0（ビルド成功）**

注: "Wasm dry run succeeded" は WASM 実験的フラグに関する警告であり、本ビルドでは `--wasm` フラグは使用していない。CanvasKit + Skwasm の JS/WASM 構成で出力されている。

## 2. `build/web` のファイル単位サイズ実測

実測コマンド:

```powershell
Get-ChildItem -Recurse build\web | Select-Object Name, Length | Sort-Object Length -Descending
```

```powershell
$total = (Get-ChildItem -Recurse build\web | Measure-Object -Property Length -Sum).Sum
$total / 1MB
```

### 実測結果（バイト単位）

| ファイル | パス | サイズ (bytes) | サイズ (MB, 換算) | 備考 |
|:---|:---|:---:|:---:|:---|
| canvaskit.wasm | `build/web/canvaskit/canvaskit.wasm` | 7,315,452 | 6.98 | CanvasKit 本体 |
| skwasm_heavy.wasm | `build/web/canvaskit/skwasm_heavy.wasm` | 5,232,730 | 4.99 | Skwasm 重量版 |
| skwasm.wasm | `build/web/canvaskit/skwasm.wasm` | 3,612,593 | 3.45 | Skwasm 軽量版 |
| wimp.wasm | `build/web/canvaskit/wimp.wasm` | 3,604,775 | 3.44 | WIMP |
| BIZUDPGothic-Regular.ttf | `build/web/assets/assets/fonts/BIZUDPGothic-Regular.ttf` | 4,669,688 | 4.45 | 日本語フォント（Regular） |
| BIZUDPGothic-Bold.ttf | `build/web/assets/assets/fonts/BIZUDPGothic-Bold.ttf` | 4,640,596 | 4.43 | 日本語フォント（Bold） |
| main.dart.js | `build/web/main.dart.js` | 4,387,699 | 4.19 | Dart→JS コンパイル結果 |
| NOTICES | `build/web/assets/NOTICES` | 1,446,213 | 1.38 | ライセンス通知ファイル |
| canvaskit.js.symbols | `build/web/canvaskit/canvaskit.js.symbols` | 1,363,368 | 1.30 | シンボルマップ |
| skwasm_heavy.js.symbols | `build/web/canvaskit/skwasm_heavy.js.symbols` | 1,682,276 | 1.60 | シンボルマップ |
| skwasm.js.symbols | `build/web/canvaskit/skwasm.js.symbols` | 1,550,388 | 1.48 | シンボルマップ |
| wimp.js.symbols | `build/web/canvaskit/wimp.js.symbols` | 1,810,678 | 1.73 | シンボルマップ |
| flutter.js.map | `build/web/flutter.js.map` | 58,794 | 0.06 | ソースマップ |
| canvaskit.wasm (chromium) | `build/web/canvaskit/chromium/canvaskit.wasm` | 5,463,539 | 5.21 | Chromium 版 CanvasKit |
| canvaskit.wasm (webparagraph) | `build/web/canvaskit/webparagraph/canvaskit.wasm` | 3,753,480 | 3.58 | WebParagraph 版 CanvasKit |
| skwasm.js | `build/web/canvaskit/skwasm.js` | 63,987 | 0.06 | Skwasm ランタイム |
| skwasm_heavy.js | `build/web/canvaskit/skwasm_heavy.js` | 64,100 | 0.06 | Skwasm 重量版ランタイム |
| wimp.js | `build/web/canvaskit/wimp.js` | 59,634 | 0.06 | WIMP ランタイム |
| canvaskit.js | `build/web/canvaskit/canvaskit.js` | 87,031 | 0.08 | CanvasKit ランタイム |
| flutter_bootstrap.js | `build/web/flutter_bootstrap.js` | 14,127 | 0.01 | Flutter ブートストラップ |
| flutter.js | `build/web/flutter.js` | 13,169 | 0.01 | Flutter ランタイム |
| favicon.png | `build/web/favicon.png` | 917 | 0.00 | |
| index.html | `build/web/index.html` | 2,154 | 0.00 | |
| manifest.json | `build/web/manifest.json` | 953 | 0.00 | |
| version.json | `build/web/version.json` | 92 | 0.00 | |
| その他（assets, icons, shaders 等） | 各種 | 計数不可（個別ファイル小） | - | 画像・シェーダー・マニフェスト等 |

**`build/web` 合計サイズ: 53,474,856 bytes（約 51.0 MB）**

※ファイル総数は取得に失敗（PowerShell の Measure-Object.Count がオブジェクト返却）。概算で 60〜80 ファイル。

### サイズ内訳のサマリー

| カテゴリ | 代表ファイル | 合計概算 (MB) |
|:---|:---|:---:|
| CanvasKit / Skwasm WASM | canvaskit.wasm, skwasm_heavy.wasm, skwasm.wasm, wimp.wasm (+ chromium/webparagraph 版) | ~20 |
| Dart コンパイル結果 | main.dart.js | ~4.2 |
| 日本語フォント (BIZ UDPGothic) | Regular + Bold | ~8.9 |
| アイコンフォント（ツリーシェイク後） | MaterialIcons-Regular.otf, CupertinoIcons.ttf | ~0.004 |
| その他（NOTICES, symbols, js, assets 等） | NOTICES, *.symbols, flutter.js 等 | ~10 |
| **合計** | | **約 51 MB** |

### 15 MB 予算に対する示唆

- 現状の `build/web` 合計は **約 51 MB** で、Tier B で OCR モデルを追加する際の 15 MB 初回ダウンロード予算を既に大幅超過している。
- ただし、GitHub Pages への配信では全ファイルを一度にダウンロードするわけではなく、初回レンダリングに必要なファイル（`main.dart.js` + 必要な assets + フォント + CanvasKit WASM のうち 1 種）がボトルネックとなる。
- **BIZ UDPGothic（Regular + Bold で ~8.9 MB）が初回ダウンロードの大部分を占める**。フォントのサブセット化（※注）が最も効果的な削減策。
- OCR モデル（例: PP-OCRv5 mobile rec 16.5 MB）を追加すると、初回ダウンロードはさらに増加。遅延読み込み・IndexedDB キャッシュ・量子化モデルの検討が必須。

> **注（§3 参照）**: Flutter Web の `--tree-shake-icons` は**アイコンフォント専用**であり、通常テキストフォント（BIZ UDPGothic 等）には適用されない。サブセット化は標準機能ではない。

## 3. 日本語フォントのサブセット化（Flutter Web 標準機能か）

### 結論

**不可。Flutter Web の標準機能として日本語フォント（通常テキストフォント）のサブセット化はサポートされていない。**

`--tree-shake-icons` は**アイコンフォント（MaterialIcons / CupertinoIcons）専用**であり、テキストフォントとは別物である点に注意。

### 一次情報の根拠

1. **ビルド出力そのもの**（実行結果）:
   - `Font asset "CupertinoIcons.ttf" was tree-shaken, reducing it from 257628 to 844 bytes (99.7% reduction).`
   - `Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 3356 bytes (99.8% reduction).`
   - BIZUDPGothic-Regular.ttf / BIZUDPGothic-Bold.ttf は**ツリーシェイクされず、フルサイズ（~4.4 MB × 2）で出力されている**。

2. **Flutter 公式ソースコード** (`flutter/packages/flutter_tools/lib/src/build_system/targets/icon_tree_shaker.dart`):
   - `IconTreeShaker` クラスは `fontManifest` に基づき、コンパイル済みカーネルから `const IconData` インスタンスをスキャンし、使用されるグリフのみを抽出する。
   - 対象はアイコンフォントのみ。通常テキストフォント（`Text` ウィジェット等で使用するフォントファミリ）は対象外。

3. **Flutter コミュニティの知見**:
   - Issue flutter/flutter#197143「Web: fonts without use are not tree shaken」— テキストフォントはツリーシェイクされない。
   - Medium「Optimizing fonts for Flutter Web」（2026-11-18, Yuri Novicow）— フォントサブセット化には `pyftsubset`（Python fonttools）を**ビルドパイプライン外で手動実行**する必要があると記載。
   - FlutterLocalisation「Fix Flutter Web Tofu Boxes」— 日本語フォントは `pyftsubset` で必要なコードポイントまで絞り込むことを推奨。

### 実行方法（参考：標準機能ではないため）

Flutter の標準機能としてはサポートされていないため、以下は**ビルドパイプライン外での手動処理**となる:

```bash
pip install fonttools brotli
pyftsubset BIZUDPGothic-Regular.ttf \
  --text='必要な文字列' \
  --layout-features='*' \
  --no-hinting \
  --desubroutinize \
  --flavor=woff2 \
  --output-file=BIZUDPGothic-Regular-subset.woff2
```

### BIZ UDPGothic のライセンス

- ファイル `build/web/assets/assets/fonts/OFL.txt`（SIL Open Font License, v1.1）が同梱されている。
- OFL は **permissive ライセンス**。GPL/AGPL/SSPL ではないため、プロジェクトのライセンス制約に抵触しない。

## 4. GitHub Pages 配信における制約（一次情報）

### 4.1 リポジトリサイズ上限

一次情報: [GitHub Docs「GitHub Pages limits」](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

| 項目 | 制限 | 出典 |
|:---|:---|:---|
| ソースリポジトリ推奨上限 | 1 GB | GitHub Docs |
| 公開サイト最大サイズ | 1 GB | GitHub Docs |
| 帯域幅（ソフト上限） | 100 GB/月 | GitHub Docs |
| ビルド頻度（ソフト上限） | 10 回/時間 | GitHub Docs |
| デプロイタイムアウト | 10 分 | GitHub Docs |

現状の `build/web` は約 51 MB なので、GitHub Pages の 1 GB サイズ上限には収まる。ただし OCR モデルを追加するとサイズが増えるため、モデルの遅延読み込みや CDN 分散を検討する必要がある。

### 4.2 `--base-href` の要否

GitHub Pages のプロジェクトサイト（`https://<user>.github.io/<repository>/`）として配信する場合、**`--base-href` の指定が必要**。

```bash
flutter build web --release --base-href "/<repository>/"
```

これにより、アプリ内の相対パス（`/assets/`, `/canvaskit/` 等）が正しく解決される。`--base-href` を指定しないと、ルートパス（`https://<user>.github.io/`）を基準としてアセットが 404 になる。

### 4.3 COOP/COEP ヘッダを付けられないこと（重要）

一次情報:
- [GitHub Community Discussion #13309「Allow setting COOP and COEP headers in Github Pages」](https://github.com/orgs/community/discussions/13309)
- [Thomas Steiner「Setting the COOP and COEP headers on static hosting like GitHub Pages」（2025-03-08）](https://blog.tomayac.com/2025/03/08/setting-coop-coep-headers-on-static-hosting-like-github-pages/)
- [gzuidhof/coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker)

**結論: GitHub Pages はサーバー側で COOP / COEP レスポンスヘッダを設定できない。**

| 項目 | 状況 |
|:---|:---|
| COOP/COEP ヘッダの直接設定 | **不可**（GitHub Pages 側でサポートなし） |
| 回避策 | Service Worker を使ってクライアント側でヘッダを付与する（`coi-serviceworker` 等） |
| 回避策の問題点 | ページのリロードが発生する、既存の Service Worker と競合する可能性がある、追加の運用コスト |

### OCR 候補への影響

Tier B-1 で検討中の OCR エンジンのうち、SharedArrayBuffer / WebAssembly スレッドを使用するもの（PaddleOCR.js の worker モード、Tesseract.js のスレッド化など）は、**クロスオリジン分離（Cross-Origin Isolated）が必要**であり、COOP/COEP ヘッダが必須。

GitHub Pages でこれらの OCR エンジンをマルチスレッドモードで動作させるには、Service Worker によるヘッダ付与が必要。これにより実装・運用が複雑化する。

## 5. リーダーの判断が必要な点

以下の項目について、リーダーの判断・指示を求める。

1. **フォントサブセット化の方針**: BIZ UDPGothic（~8.9 MB）を pyftsubset 等で手動サブセット化するか、あるいはシステムフォントフォールバックに委ねるか。標準機能ではないため、ビルドパイプラインへの組み込み工数が必要。
2. **CanvasKit の版選定**: `canvaskit.wasm` (~7.0 MB) / `skwasm.wasm` (~3.4 MB) / `wimp.wasm` (~3.4 MB) のうち、どのレンダラを採用するか。Skwasm/WIMP の方が軽量だが、機能・互換性の確認が必要。
3. **OCR モデルの配信戦略**: 初回ダウンロード 15 MB 予算内に収めるため、OCR モデル（例: PP-OCRv5 mobile rec 16.5 MB）を初回バンドルに含めず、遅延読み込み + IndexedDB キャッシュにするか。あるいは OCR なしで開始し、後から追加するか（Tier A と並行）。
4. **GitHub Pages での COOP/COEP 対応**: OCR エンジンがマルチスレッド WASM を必要とする場合、Service Worker によるヘッダ付与を導入するか、それともシングルスレッドモード（WASM backend = "wasm", simd = false 等）で妥協するか。
5. **`--base-href` の指定値**: GitHub Pages プロジェクトサイトとして配信する場合、リポジトリ名に基づく `--base-href` の値を確定する。

## 6. 情報源

1. Flutter 公式 ドキュメント: `flutter build web --release` 出力（実測、2026-11-25）
2. Flutter ソースコード `icon_tree_shaker.dart`: https://github.com/flutter/flutter/tree/main/packages/flutter_tools/lib/src/build_system/targets/icon_tree_shaker.dart
3. flutter/flutter Issue #197143「Web: fonts without use are not tree shaken」: https://github.com/flutter/flutter/issues/197143
4. Medium「Optimizing fonts for Flutter Web」（2026-11-18）: https://medium.com/@yurinovicow/optimizing-fonts-for-flutter-web-cab635f67507
5. GitHub Docs「GitHub Pages limits」: https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
6. GitHub Community Discussion #13309「Allow setting COOP and COEP headers in Github Pages」: https://github.com/orgs/community/discussions/13309
7. Thomas Steiner「Setting the COOP and COEP headers on static hosting like GitHub Pages」（2025-03-08）: https://blog.tomayac.com/2025/03/08/setting-coop-coep-headers-on-static-hosting-like-github-pages/
8. gzuidhof/coi-serviceworker: https://github.com/gzuidhof/coi-serviceworker
9. PaddleOCR PP-OCRv5 mobile rec.onnx 16.5 MB（Hasmolam/cosmic-ext-translator releases）: https://github.com/Hasmolam/cosmic-ext-translator/releases/tag/models-v1

---

> 作成：2026-11-25（公開前監査 役割、調査のみ・実装なし）。本ファイルは `lib/` および `pubspec.yaml` への変更を含まない。
