# Web 移行基準線レポート (web-migration-baseline.md)

## 作業概要
- 作業場所: `C:\Users\ka\Documents\coding\ScoreYomiPM\wt\feature-web` (branch: feature/web)
- 作業日: 2026-11-25
- Flutter: 3.50.1 stable (`C:\dev\flutter\bin\flutter.bat`)
- Android SDK: build-tools 36.0.0

---

## 1. flutter create --platforms=web .

**実行コマンド:**
```
flutter create --platforms=web .
```

**終了コード:** `0`

**結果:** 成功。`web/` ディレクトリが生成された。
- `web\favicon.png`
- `web\icons\Icon-192.png`
- `web\icons\Icon-512.png`
- `web\icons\Icon-maskable-192.png`
- `web\icons\Icon-maskable-512.png`
- `web\index.html`
- `web\manifest.json`

**副作用 (既存ファイル変更):**
- `.metadata` (変更)
- `analysis_options.yaml` (変更: build/platform ディレクトリ除外追加)
→ これらは意図しない変更として `git checkout --` で元に戻した。

---

## 2. flutter build web --release

**実行コマンド:**
```
flutter build web --release
```

**終了コード:** `0`

**結果:** 成功。エラー件数 0。
- 出力: `build\web`
- Wasm dry run 警告あり (致命的ではない)

**失敗ファイル一覧:** なし (0 件)

---

## 3. flutter analyze (基準線)

**実行コマンド:**
```
flutter analyze
```

**終了コード:** `1`

**結果:** 104 issues found

**エラー詳細 (原因ファイル別):**

### lib\platform\blob_store.dart (dart:io 依存エラー, 22 errors)
`dart:io` の `File`, `Directory`, `Uint8List`, `Platform` は Web プラットフォームでは利用不可。

| 行 | エラー種別 | 内容 |
|----|-----------|------|
| 8:10 | non_type_as_type_argument | `Uint8List` は型として使用不可 |
| 11:34 | undefined_class | `Uint8List` 未定義 |
| 32:9 | undefined_class | `Directory` 未定義 |
| 37:10 | non_type_as_type_argument | `Uint8List` |
| 39:18 | undefined_method | `File` メソッド未定義 |
| 45:34 | undefined_class | `Uint8List` |
| 47:18 | undefined_method | `File` |
| 55:18 | undefined_method | `File` |
| 62:18 | undefined_method | `File` |
| 69:17 | undefined_method | `Directory` |
| 72:20 | undefined_method | `File` |
| 78:21 | type_test_with_undefined_name | `File` は定義されていない型 |
| 90:17 | undefined_method | `Directory` |
| 95:18 | undefined_method | `File` |
| 100:59 | undefined_identifier | `Platform` |
| 103:53 | undefined_identifier | `Platform` |
| 111:24 | undefined_identifier | `Platform` |
| 112:10 | undefined_identifier | `Platform` |
| 126:21 | non_type_as_type_argument | `Uint8List` |
| 129:10 | non_type_as_type_argument | `Uint8List` |
| 132:34 | undefined_class | `Uint8List` |
| 133:19 | undefined_identifier | `Uint8List` |

### test\blob_store_test.dart (package:test 未定義, 82 errors)
`package:test` が `pubspec.yaml` の依存関係にないため、テスト用関数・クラスがすべて未定義。

| エラー種別 | 件数 | 代表例 |
|-----------|------|--------|
| uri_does_not_exist | 1 | `package:test/test.dart` |
| undefined_function | 多数 | `group`, `setUp`, `test`, `expect`, `equals`, `throwsA`, `isA` |
| undefined_identifier | 多数 | `isNull`, `isTrue`, `isFalse` |
| depend_on_referenced_packages | 1 | `test` パッケージが依存関係にない |

---

## 4. flutter test (基準線)

**実行コマンド:**
```
flutter test
```

**終了コード:** `1`

**結果:** pass: 839 / skipped: 22 / failed: 8

**失敗テスト (8 件):**
すべて `test\blob_store_test.dart` の `IoBlobStore` クラスに関するテスト。

| テスト名 | エラー |
|---------|--------|
| IoBlobStore 書き込み後の読み取り（往復） | PathNotFoundException: Cannot open file... (OS Error: ファイル名、ディレクトリ名、またはボリューム ラベルの構文が間違っています。, errno = 123) |
| IoBlobStore exists は存在時 true、不在時 false | 同上 |
| IoBlobStore listKeys は prefix でフィルタし昇順にソートする | 同上 |
| IoBlobStore delete でエントリを削除できる | 同上 |
| IoBlobStore deleteWhere は prefix 一致をすべて削除する | 同上 |
| ... and 3 more | 同上 |

**原因:** `lib\platform\blob_store.dart` が `dart:io` (`File`, `Directory`) を使用しており、Web プラットフォームでは `dart:io` が利用不可。一時ディレクトリパスの生成に `Platform` を使用している箇所も問題。

---

## 5. 原因カテゴリ集計

| カテゴリ | 件数 | 対象ファイル |
|---------|------|-------------|
| dart:io 未対応 (Web 非対応) | 22 | `lib\platform\blob_store.dart` |
| package:test 未依存 | 82 | `test\blob_store_test.dart` |
| テスト実行失敗 (dart:io 実行時エラー) | 8 | `test\blob_store_test.dart` |
| **合計** | **112** | |

---

## 6. 修正方針 (今後の作業)

1. `lib\platform\blob_store.dart` を Web 対応にする:
   - `dart:io` を `dart:html` / `indexed_db` / `shared_preferences_web` などに置き換え
   - または `kIsWeb` で分岐し、Web では代替実装を使用

2. `test\blob_store_test.dart` を Web 対応にする:
   - `package:test` を `pubspec.yaml` の `dev_dependencies` に追加
   - または Web ではテストをスキップする処理を追加

---

## 7. web/index.html 修正

- `<title>scoreyomipm</title>` → `<title>スコアヨミPM</title>`
- `<meta name="description" content="A new Flutter project.">` → `<meta name="description" content="スコアヨミPM">`

---

## コミット対象

- `web/` (Web プラットフォーム生成物)
- `lib/platform/` (既存ソース、Web 非対応部分を含む)
- `test/blob_store_test.dart` (既存テスト)
- `reports/` (本レポート)

**コミットしないもの:**
- `.metadata` (戻した)
- `analysis_options.yaml` (戻した)
- `build/` (.gitignore 対象)
