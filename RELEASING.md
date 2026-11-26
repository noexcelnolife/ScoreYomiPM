# リリース手順書（ScoreYomiPM 初回リリース）

ユーザーが初回リリースを**自分だけで再現できる**レベルで書かれた手順書である。
すべて PowerShell で実行することを前提とする。`flutter` は `C:\dev\flutter\bin` にあり、PATH には入っていないので、実行前に `$env:Path = "C:\dev\flutter\bin;" + $env:Path` を設定すること。

## 前提

- 作業場所：`C:\Users\ka\Documents\coding\ScoreYomiPM\app`（ブランチ `main`）。`wt/feat-a` `wt/feat-b` は開発用の worktree であり、**リリースビルドは `app` で行う**
- Flutter バージョン：3.50.1 stable（`C:\dev\flutter`）
- 配布先：GitHub Releases（APK のみ、Google Play は使用しない）
- `android/key.properties` と `**/*.jks` は `.gitignore` 対象（リポジトリにコミットしない）

---

## 1. keystore 生成（ユーザーが実行）

以下の `keytool` コマンドを PowerShell でそのまま貼り付けて実行する。

```powershell
keytool -genkeypair -v -keystore "android\scoreyomipm-release.jks" -alias scoreyomipm-release -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=ScoreYomiPM Release, OU=ScoreYomiPM, O=ScoreYomiPM, L=Tokyo, ST=Tokyo, C=JP"
```

- **`-storepass` / `-keypass` は書かない。** コマンドラインにパスワードを書くと PowerShell の履歴（`Get-History`）やプロセス一覧に平文で残る。keytool が対話的に要求するので、その場で入力すること。ストアパスワードと鍵パスワードは同じにしても構わない（`-keypass` を聞かれたら同じ値を入れる）。
- `-dname` の `ST=` は都道府県。`S=` は keytool が受け付けない。

### 置き場所と注意

- 生成した `.jks` は `android\scoreyomipm-release.jks`（`android/` 直下）に置く。`.gitignore` に `*.jks` が含まれているため、リポジトリにコミットされることはない。
- **この `.jks` を絶対に失くしてはいけない。** 同じ `applicationId`（`com.scoreyomipm.app`）で別の鍵で署名した APK を配布すると、Android OS は「署名が異なるため更新インストール不可」と判断し、ユーザーは既存アプリを手動でアンインストールしてから再インストールする必要が生じる。
- パスワード（ストアパスワード、鍵パスワード）はリポジトリ外に保管する。`.local/`（`C:\Users\ka\Documents\coding\ScoreYomiPM\.local/`）など、バージョン管理下にない場所にテキストファイルとして保管すること。

---

## 2. android/key.properties のテンプレート

`android\key.properties` を以下の内容で作成する。

```
storeFile=C:/Users/ka/Documents/coding/ScoreYomiPM/app/android/scoreyomipm-release.jks
storePassword=<1 で設定したストアパスワード>
keyAlias=scoreyomipm-release
keyPassword=<1 で設定した鍵パスワード>
```

- **`storeFile` は絶対パスで書く**（区切りは `/`。`\` はプロパティのエスケープ文字として扱われるため使わない）。
- 相対パスも書けるが、その基準ディレクトリは **`android/app/`** である（Gradle の `Project.file()` がプロジェクトディレクトリから解決するため）。`key.properties` の置き場所（`android/`）ではないので注意。`../scoreyomipm-release.jks` と書いた場合は `android/scoreyomipm-release.jks` を指す。この基準を取り違えると `storeFile` が見つからずビルドが落ちるため、**絶対パスを推奨する**。
- `key.properties` も `.gitignore` の `**/android/key.properties` で除外されている。`git check-ignore -v android/key.properties` で確認できる。

---

## 3. ビルド（flutter build apk --release）

プロジェクトルート（`app`）で実行する。**前回のビルド成果物が混ざらないよう、先に `flutter clean` を実行する。**

```powershell
$env:Path = "C:\dev\flutter\bin;" + $env:Path
flutter clean
flutter pub get
flutter build apk --release
```

**成果物のサイズ（2026-11-25 実測）**: universal APK は **94.2MB**。

`flutter build apk --release --split-per-abi` を使うと ABI ごとに分かれ、次のようになる（実測値）。

| APK | サイズ | 用途 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 38.7MB | **現行の実機はほぼこれ。主配布物** |
| `app-armeabi-v7a-release.apk` | 33.1MB | 2016年頃までの 32bit 端末向け |
| `app-x86_64-release.apk` | 40.5MB | エミュレータ向け（通常は配布不要） |

Release に添付するのは **arm64-v8a + armeabi-v7a の 2 本**を推奨する（94MB の universal 1 本でも動くが、利用者のダウンロードが重くなる）。

### 成果物

ビルド成功時、以下のパスに APK が生成される。

```
build\app\outputs\flutter-apk\app-release.apk
```

`--split-per-abi` を指定しない限り、1 つの fat APK が生成される。ABI 分割が必要な場合は `flutter build apk --release --split-per-abi` を実行し、`build\app\outputs\flutter-apk\` 配下に ABI ごとの APK が生成される。

---

## 4. 署名の検証（必須）

ビルドした APK がリリース鍵で署名されていることを確認する。**デバッグ鍵（CN=Android Debug）で署名されている場合は公開を中止する。**

`apksigner` と `aapt` は Android SDK の build-tools 配下にある（この環境では `C:\Users\ka\AppData\Local\Android\Sdk\build-tools\36.0.0\`）。

```powershell
$bt  = "C:\Users\ka\AppData\Local\Android\Sdk\build-tools\36.0.0"
$apk = "build\app\outputs\flutter-apk\app-release.apk"

# 署名の確認
& "$bt\apksigner.bat" verify --verbose --print-certs $apk

# 要求権限の確認
& "$bt\aapt.exe" dump permissions $apk
```

**権限の期待値**（2026-11-25 の実測。これ以外が出たら要調査）:

```
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.CAMERA'
uses-permission: name='android.permission.ACCESS_NETWORK_STATE'
uses-permission: name='com.scoreyomipm.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
```

`RECORD_AUDIO` / `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` が出てきたら、`main/AndroidManifest.xml` の `tools:node="remove"` 指定が効いていない（古い manifest が混ざっている可能性があるので `flutter clean` して再ビルド）。**debug ビルドでは Flutter が `INTERNET` を自動付与するため、権限の過不足は release APK でしか検出できない。**

### 判定基準

- 出力に `CN=Android Debug` が含まれる場合：**即座に公開を中止する**。デバッグ鍵で署名されており、第三者が同じ署名で偽 APK を作成できる。
- 出力の証明書 SHA-256 フィンガープリントが、意図したリリース鍵（1 で生成した keystore の鍵）のものと一致することを確認する。
- リリース鍵の SHA-256 フィンガープリントを記録しておき、リリースノートに公開する（GitHub 配布では署名が唯一の信頼の根拠となるため、利用者の検証手段として必須）。

---

## 5. GitHub Release 手順

### タグ名の規約

`v<バージョン>` の形式とする。例：`v1.0.0`。

### APK のファイル名

`scoreyomipm-<バージョン>-release.apk` のように、バージョンを含むファイル名にリネームしてアップロードする。

### リリースノートに必ず書くこと

- 変更内容とバージョン
- インストール方法（APK のダウンロードURL）
- **非公式配布である旨**（Google Play を介さないため、Play Protect やセキュリティ警告が出る可能性があることを明記）
- リリース署名鍵の SHA-256 フィンガープリント（署名検証用）
- 更新通知の方法

### リリースの公開

GitHub Releases でリリースを公開し、タグを付与する。

---

## 6. versionCode の更新ルール

`pubspec.yaml` の `version: 1.0.0+1` の `+1` 部分（versionCode）を、リリースごとに必ず1以上上げる。

- 理由：Android OS は versionCode でアプリの新旧を判断する。versionCode が同じまたは古い APK を配布すると、ユーザー側で「アップデートがない」と判断され、新しい APK がインストールされない。
- `versionName`（`1.0.0`）はユーザー向け表示バージョンで、必ずしも上げる必要はないが、リリースごとに versionCode は必ずインクリメントすること。

---

## 7. 初回 push 前にだけ行う履歴の整理

`.gitignore` で除外したファイルでも、**過去のコミットには残っている**（このリポジトリでは内部資料 `spec.md` / `popn_score_app_plan.md` / `docs/` の設計メモ 71 件）。そのまま push すると、GitHub のコミット履歴から中身を読めてしまう。**初回 push の直前に履歴を 1 コミットへ作り直す。**

```powershell
cd C:\Users\ka\Documents\coding\ScoreYomiPM\app

# 1) worktree を外す（branch を差し替えられなくなるため）
git worktree remove ..\wt\feat-a --force
git worktree remove ..\wt\feat-b --force

# 2) 現在の作業ツリーだけを持つ孤立ブランチを作る（.gitignore が効く）
git checkout --orphan release-clean
git add -A
git commit -m "ScoreYomiPM v1.0.0"

# 3) main を差し替えて古い履歴を捨てる
git branch -D main
git branch -m main

# 4) 古い履歴を参照しているブランチとオブジェクトを消す
#    これをしないと feat-a/feat-b から古いコミット（内部資料入り）を辿れてしまう
git branch -D feat-a feat-b
git reflog expire --expire=now --all
git gc --prune=now
```

- 実行前に、**`feat-a` / `feat-b` の変更が `main` に取り込まれていること**を確認する（取り込む前に worktree を消すと作業が失われる）。
- 実行前に `git log --oneline` で消えてよい履歴か確認する。このリポジトリは 2026-11-25 に初期化したもので、外部由来の履歴は無い。
- 実行後に `git log --oneline --all` が **1 行**になり、`git ls-tree -r HEAD --name-only | Select-String '^(docs/|db/)'` が **`docs/media/` 以外を返さない**ことを確認する。
- **push 後のやり直しは不可能**（全員の手元と食い違う）。push 前の 1 回だけ行う。

## 8. タグ付けとリリース作成

以下は**ユーザー自身が実行する**（チームに push 権限は無い）。

```powershell
git tag -a v1.0.0 -m "ScoreYomiPM v1.0.0"
git push origin main
git push origin v1.0.0
```

GitHub の画面で Releases → Draft a new release → タグ `v1.0.0` を選択 → APK を添付 → 本文を記入して公開する。`gh` CLI を使う場合は `gh release create v1.0.0 <APKのパス> --title "v1.0.0" --notes-file <メモのパス>`。

## 9. （参考）key.properties 無しでのビルド失敗例

`android/key.properties` を忘れた状態では、**release だけが意図的に失敗**し、**debug / profile は通る**（デバッグ鍵へのフォールバックは削除済み）。

- debug / profile を通すのは、鍵を作る前からアプリを動かして開発できるようにするためである。debug APK を配布することはないので、デバッグ鍵で署名されていても危険はない。
- release を止めるのは、鍵を設定し忘れたまま配布すると「誰でも同じ署名で偽 APK を作れる」状態になるためである。

**「release が失敗する」ことを「リポジトリが壊れている」と誤解しないこと。鍵を作るまでは release が失敗するのが正しい挙動である。**

### 9.1 release（失敗する）

実行コマンド：
```powershell
$env:Path = "C:\dev\flutter\bin;" + $env:Path
flutter build apk --release
```

実行結果（生出力・2026-11-25 実測）：
```
FAILURE: Build failed with an exception.

* What went wrong:
リリース署名が未設定です: C:\Users\ka\Documents\coding\ScoreYomiPM\app\android\key.properties が見つかりません。 release APK は keystore 署名が必須で、デバッグ鍵へのフォールバックは意図的に用意していません。手順は RELEASING.md を参照してください。

* Try:
> Run with --stacktrace option to get the stack trace.
> Run with --info or --debug option to get more log output.
> Run with --scan to get full insights from a Build Scan (powered by Develocity).
> Get more help at https://help.gradle.org.

BUILD FAILED in 2s
Running Gradle task 'assembleRelease'...                         2,930ms
Gradle task assembleRelease failed with exit code 1
```

exit code：`1`

このメッセージが出たら**第 1 節と第 2 節をやり直す**。メッセージに書かれた絶対パスが、実際に `key.properties` を置いた場所と一致しているかも確認すること。

### 9.2 debug（成功する）

```powershell
flutter build apk --debug
```

実行結果（2026-11-25 実測）：`✓ Built build\app\outputs\flutter-apk\app-debug.apk`（約 36 秒）。exit code は `0`。

