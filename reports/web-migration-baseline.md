# Web ビルド基準線（実測）

測定: リーダー（2026-11-25, branch `feature/web` @ `57936b0` 時点）
初版（`e19b265` に同梱）は**測定値が事実と異なっていた**ため、リーダーが実測で置き換えた。

## 0. 最重要の結論

**`flutter build web` が成功することは、Web で動くことを意味しない。**

- `dart:io` は Web でも **コンパイルできる**（Dart の Web コンパイラは未対応ライブラリのスタブを持ち、呼び出しは実行時に `UnsupportedError` を投げる）。
- したがって「`dart:io` を import しているからビルドが落ちる」という前提は誤り。落ちるのは**実行時**。
- 実測: ビルドは成功し、成果物をブラウザで開くと **白画面 + `Uncaught Error`**（`main.dart.js` の起動時点）。

**Web 可否のゲートは「ブラウザで起動して例外が出ないこと」で判定する。ビルド成否では判定できない。**

## 1. 環境

| 項目 | 値 |
|---|---|
| 作業場所 | `C:\Users\ka\Documents\coding\ScoreYomiPM\wt\feature-web`（worktree, branch `feature/web`） |
| Flutter | `C:\dev\flutter\bin\flutter.bat`（PATH 外） |
| 配信 | `python -m http.server 8123 --directory build\web` |
| 確認ブラウザ | Chrome（DevTools 経由で console を取得） |

## 2. 実測値

| 検証 | コマンド | 結果 |
|---|---|---|
| 静的解析 | `flutter analyze` | **No issues found!** |
| テスト | `flutter test` | **844 passed / 22 skipped / 3 failed**（失敗理由は下記 §4） |
| Web ビルド | `flutter build web --release` | **成功（exit 0, 約 49 秒）** |
| **実行** | 成果物をブラウザで開く | **白画面。console に `Uncaught Error`（起動時）** |
| 成果物サイズ | `build\web` 合計 | 51.0 MB / 59 ファイル |

## 3. 成果物サイズの内訳（上位）

| サイズ | ファイル | 備考 |
|---|---|---|
| 大きい | `canvaskit/*` の複数バリアント | ビルドに全レンダラ分が入る。配信時に使うのは 1 つ |
| 8.9 MB | BIZ UDPGothic（Regular/Bold） | **日本語フォントが実質の初期ダウンロード支配要因** |
| 4.2 MB | `main.dart.js` | — |
| — | `assets/anchors/**` | 位置合わせ用の画像群 |

Tier A では削らない。フォントのサブセット化は公開判断のときの課題として記録する。

## 4. テスト 3 件の失敗は Web と無関係（レガシー欠陥）

`song_dictionary_test.dart` の 3 件は `docs/ground_truth_template.csv` を読む。
`.gitignore` が `/docs/*` を除外し `/docs/media/` だけ追跡しているため、**クリーンな clone / worktree には CSV が存在しない**。

- 対処: worktree へ `app\docs\ground_truth_template.csv` をコピー（未追跡）→ 3 件とも成功、**847 件全緑**。
- 恒久対処（別件）: テスト用の固定データは `test/fixtures/` に置く。`docs/` は社内資料なのでテストが依存してはならない。

## 5. これからのゲート

1. `flutter analyze` → No issues found
2. `flutter test` → 全緑（worktree では §4 の CSV をコピー済みであること）
3. `flutter build web --release` → 成功
4. **`build\web` を配信してブラウザで開き、console エラー 0 件・ホーム画面が描画される**
5. `flutter build apk --debug` → 成功（Android 版の退行なし）

4 が満たせるまでは「Web 対応済み」と報告しない。
