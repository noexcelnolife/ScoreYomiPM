# Web 版ブラウザ検証記録（2026-11-25）

対象: `feature/web` ワークツリー（`C:\Users\ka\Documents\coding\ScoreYomiPM\wt\feature-web`）
ビルド: `flutter build web --release` → `√ Built build\web`（44.9 秒）
配信: `py -3 -m http.server 8124 --directory build\web` → `http://127.0.0.1:8124/`

## 1. 判定

計画 §5 のうち、ブラウザでしか判定できない項目は**通過**。
`flutter build web` の成功は動作の証拠にならない（`dart:io` はコンパイルが通り実行時に落ちる）ため、
判定はすべてブラウザ上の観測結果で行った。以下の「観測した事実」はセマンティクスツリーと
IndexedDB の直接読み出しによる。

## 2. 実施項目と結果

| 項目 | 結果 | 観測した事実 |
| --- | --- | --- |
| console エラー 0 件 | 通過 | `error` / `warn` の取得結果は空。デバッグ用の `[debug] Injecting <script> tag` はエラー扱いしない |
| ホーム画面が描画される | 通過 | 見出し「スコアヨミPM」、ボタン「記録一覧」「記録を追加」「エクスポート・インポート」 |
| Web 注記の表示 | 通過 | 「ブラウザ版は画像からの読み取りに対応していません。記録は手入力か、バックアップの復元で追加してください」（計画 §6.4 と一致） |
| 「画像を取り込む」を出さない | 通過 | セマンティクスツリーに存在しない |
| 「収録曲辞書」の節を出さない | 通過 | セマンティクスツリーに存在しない |
| 手入力画面へ到達 | 通過 | 「記録を追加」→ 見出し「スコア手入力」、入力欄 9 個と保存ボタン |
| 手入力で実値を保存 | 通過 | 曲名 `ブラウザ検証曲` / スコア `95000` →「スコアを保存しました。続けて入力できます。」 |
| IndexedDB への永続化 | 通過 | DB `scoreyomipm:1`、ストア `blobs`、キー `records/records.json` |
| 再読み込み後もデータが残る | 通過 | リロード後も「最近の記録 ブラウザ検証曲 2026/11/28 95000」 |
| 記録一覧 → 記録詳細 | 通過 | 「記録一覧」→ 行タップ → 見出し「記録詳細」、「修正」「削除」が有効 |
| ZIP バックアップの実行 | 通過（生成まで） | 「ZIP を作成しています…」が出て、完了後に通常表示へ戻る。console エラーなし。**生成物の中身は未検証**（後述） |
| CSV 出力の実行 | 通過（実行まで） | console エラーなし。**生成物の中身は未検証** |
| バックアップからの復元 | **未検証** | OS のファイル選択ダイアログが必要で、ブラウザ自動操作では代替できない |

保存されたレコード（`records/records.json` の実体を IndexedDB から直接読んだ結果）:

```json
[{"id":"r1795797653503000-1","playedAt":"2026-11-28T01:40:53.503",
  "songName":"ブラウザ検証曲","songId":null,"score":95000,
  "cool":null,"great":null,"good":null,"bad":null,"maxCombo":null,
  "level":null,"clearMedal":null,"difficulty":null,"machine":"H☆C!!",
  "memo":null,"status":"confirmed","source":"playshare","resultImagePath":""}]
```

## 3. 永続化要求（D14）の実機確認

`navigator.storage.persist` を `StorageManager.prototype` 上で計測用に包み、リロード後に 1 件保存した。

- 呼び出し回数: **1 回**（同一セッション内の 2 件目以降は増えない設計どおり）
- `navigator.storage.persisted()` の戻り: **false**

`false` は Chrome がこのオリジン（localhost・操作履歴なし）を自動昇格の対象外としたため。
設計では戻り値を捨て、拒否されても保存を続ける（`lib/platform/storage_persistence_web.dart`）。
保存自体は成立しており、判定に影響しない。

## 4. 検証手順上の注意（再検証する人向け）

- Flutter Web はキャンバス描画のため、セマンティクスを有効にしないと DOM に文言が出ない。
  `flt-semantics-placeholder` をクリックすると有効になる。
- **`fill_form` 相当の DOM 直接代入では Flutter の入力欄に値が入らない。**
  入力欄をクリックしてから実キー入力で打つこと。この手順を省くと「空のまま保存」になり、
  `songName: null` / スコア既定値のレコードができる（アプリの不具合ではない）。
- 保存後に必ずページを再読み込みし、値が残ることを確認する（IndexedDB の永続化判定）。

## 5. 残る未検証項目（P6 で扱う）

1. ZIP / CSV のダウンロード内容の妥当性（生成ファイルを開いて中身を確認する）
2. バックアップからの復元（ファイル選択が必要）
3. Android 実機での退行（`flutter build apk --debug` の成功までは確認済み）
4. GitHub Pages 配信時の挙動（base href `/ScoreYomiPM/`、Service Worker のキャッシュ更新）
