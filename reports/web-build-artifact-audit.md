# Web ビルド成果物の監査

実施: 2026-11-25（リーダー。teammate のメッセージ配信が失敗したため代行）
対象: `wt/feature-web/build/web`（`flutter build web --release` の出力。**`--base-href` 指定なし**）
ファイル数: 59 / 合計 53,278,508 B（50.8 MB）

## 1. 判定のまとめ

| 観点 | 判定 |
| --- | --- |
| 秘密情報（API キー・トークン）の混入 | **問題なし** |
| ローカル絶対パスの混入 | **問題なし** |
| ライセンス情報の同梱 | **問題なし** |
| 公開時の URL 解決（`base href`） | **要対応** |
| 初回ダウンロード量 | 要検討（§4） |

## 2. 走査結果

走査対象: `build/web` 配下の 20 MB 未満の全ファイル（59 件）。`Select-String -SimpleMatch -List` で
最初のヒットのみ取得し、ヒットしたパスを記録した。

| パターン | ヒット | 内訳 |
| --- | --- | --- |
| `C:\\Users` | 0 | — |
| `C:/Users` | 0 | — |
| `Documents\coding` / `Documents/coding` | 0 | — |
| `apiKey` | 0 | — |
| `Bearer ` | 0 | — |
| `ghp_` | 0 | — |
| `client_secret` | 0 | — |
| `AIza` | 0 | — |
| `sk-` | 6 | **すべて誤検知**（`BIZUDPGothic-Bold.ttf`、`canvaskit.wasm`、`skwasm_heavy.wasm` などのバイナリ中の偶然一致） |

個人名・メールアドレス・電話番号の走査は行っていない（監査パターン集の担当領域。§5 の未実施項目）。

## 3. ライセンス

- `build/web/assets/NOTICES` が**存在する**（約 1.4 MB）。Flutter が `pubspec.lock` の依存から生成しており、
  `showLicensePage` はこれを読む。今回追加した `idb_shim` も pub 依存なので自動的に含まれる。
- 一方、`web/` に手で置く js（将来の OCR 用 vendoring）は `NOTICES` に載らない。
  `reports/web-ocr-integration-options.md` §4 のとおり、別途同梱が必要。

## 4. 容量の内訳

| サイズ | ファイル |
| --- | --- |
| 7,315,452 | `canvaskit/canvaskit.wasm` |
| 5,463,539 | `canvaskit/chromium/canvaskit.wasm` |
| 5,232,730 | `canvaskit/skwasm_heavy.wasm` |
| 4,669,688 | `assets/assets/fonts/BIZUDPGothic-Regular.ttf` |
| 4,640,596 | `assets/assets/fonts/BIZUDPGothic-Bold.ttf` |
| 4,187,135 | `main.dart.js` |

- レンダラ 3 種で約 18.0 MB、フォント 2 種で約 9.3 MB。この 2 つで 27.3 MB を占める。
- レンダラは初回にどれか 1 つだけ取得される（すべてをダウンロードするわけではない）。
  ただし配信物としては全部含まれるため、Pages の容量とリポジトリの重さには効く。
- フォントはサブセット化しない限り削れない（`reports/web-bundle-budget.md`）。

## 5. 要対応: `base href` が `/` のまま

`build/web/index.html` は `<base href="/">` を出力している。リポジトリ名配下（`/ScoreYomiPM/`）で配信すると、
`main.dart.js` などの取得先が `https://<user>.github.io/main.dart.js` に解決されて**真っ白になる**。

- 対応: Web の公開用ビルドは必ず `--base-href /ScoreYomiPM/` を付ける。
  `tool/web_build_check.ps1` はローカル確認用に `/` で作っているため、**この 2 つを混同しない**こと。
- 判定は「公開テスト」で行う。ローカル配信が通っても、この設定漏れは検出できない。

## 6. 未実施（他タスクの担当領域）

- 個人情報パターン（メール・電話・氏名らしき文字列）の走査
- 画像の EXIF（`assets/` 配下）
- 商標リスク（`docs/` の記述）— `docs/` は Web ビルドに含まれないため配信物としては対象外
- 既知脆弱性（`pubspec.lock` の依存の CVE 確認）
