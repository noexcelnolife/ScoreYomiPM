# tool/web_build_check.ps1
#
# Web ビルド検証テストスクリプト
#
# 目的:
#   flutter build web --release が成功してもブラウザで白画面になる
#   (dart:io は Web でもコンパイル通るが実行時に UnsupportedError) ため、
#   ビルド成否だけでなくブラウザ起動確認までをゲートとする。
#
# 手順:
#   1. flutter analyze / flutter test / flutter build web --release を順に実行
#   2. 各コマンドの生出力末尾20行と終了コードを表示
#   3. build\web を python -m http.server で配信
#   4. HTTP 200 が返るまで待機（最大30秒）
#   5. try/finally でサーバプロセスを必ず停止
#
# このスクリプトが保証しないこと（重要）:
#   HTTP 200 は「index.html が配信できた」だけであり、アプリが描画できた証拠では
#   ない。ブラウザの console にエラーが出ていないこととホーム画面が描画される
#   ことは、人間または AI がブラウザで目視確認する。ここを自動化したつもりに
#   ならないよう、結果表示にもその旨を出す。
#
# 使い方:
#   pwsh -File tool\web_build_check.ps1 -Port 8123
#   pwsh -File tool\web_build_check.ps1 -Port 8123 -SkipBuild
#
# 制約:
#   - lib/ は変更しない
#   - flutter は PATH に無いので C:\dev\flutter\bin\flutter.bat を使う
#   - コミットする（push はしない）

param(
    [int]$Port = 8123,
    [switch]$SkipBuild
)

# 外部コマンドの終了コードを例外にしない（手動で処理するため）
$ErrorActionPreference = "Continue"

# Flutter は PATH に入っていないため絶対パスで指定（AGENTS.md の前提）
$flutterExe = "C:\dev\flutter\bin\flutter.bat"

# 静的配信は python -m http.server を使う。PATH に無い環境（py ランチャーのみ）
# でも動くように、使える方を選ぶ。どちらも無ければ配信ステップだけ諦める。
$pythonExe = $null
$pythonArgs = @()
foreach ($candidate in @(
    @{ Exe = "python"; Prefix = @() },
    @{ Exe = "py"; Prefix = @("-3") }
)) {
    if (Get-Command $candidate.Exe -ErrorAction SilentlyContinue) {
        $pythonExe = $candidate.Exe
        $pythonArgs = $candidate.Prefix
        break
    }
}

# スクリプト配置ディレクトリの親（worktree ルート）を作業ディレクトリとする
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$worktreeRoot = Split-Path -Parent $scriptDir
$buildWebDir = Join-Path $worktreeRoot "build\web"

Set-Location $worktreeRoot

Write-Host "=== Web ビルド検証テスト開始 ==="
Write-Host "作業ディレクトリ: $worktreeRoot"
Write-Host "ポート: $Port"
Write-Host ""

# --- 関数: Flutter コマンド実行＋生出力の末尾20行＋終了コードを表示 ---
function Run-FlutterCommand {
    param(
        [string]$Label,
        [string[]]$Arguments
    )

    Write-Host "--- $Label 実行 ---"
    Write-Host "コマンド: $flutterExe $Arguments"

    # 2>&1 で stderr も stdout にマージし、生出力をすべてキャプチャ
    $output = & $flutterExe $Arguments 2>&1
    $exitCode = $LASTEXITCODE

    Write-Host "終了コード: $exitCode"
    Write-Host "--- 生出力（末尾20行）---"
    $output | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    Write-Host ""

    return $exitCode
}

# 実行結果を記録（すべてのステップを独立に実行し、最後にまとめて報告）
$results = @{}

# --- ステップ1: flutter analyze ---
$results["analyze"] = Run-FlutterCommand -Label "flutter analyze" -Arguments @("analyze")

# --- ステップ2: flutter test ---
$results["test"] = Run-FlutterCommand -Label "flutter test" -Arguments @("test")

# --- ステップ3: flutter build web --release ---
if ($SkipBuild) {
    Write-Host "--- flutter build web --release スキップ (-SkipBuild 指定) ---"
    Write-Host ""
    $results["build"] = 0
} else {
    $results["build"] = Run-FlutterCommand -Label "flutter build web --release" -Arguments @("build", "web", "--release")
}

# --- ステップ4: build\web を配信し HTTP 200 を確認 ---
$serverProcess = $null
$httpCheckResult = $null

try {
    if ($pythonExe -eq $null) {
        Write-Host "エラー: python も py も見つかりません。配信ステップをスキップします。"
        $httpCheckResult = "no_python"
    }
    elseif (-not (Test-Path $buildWebDir)) {
        Write-Host "エラー: $buildWebDir が存在しません。ビルドを実行してください。"
        $httpCheckResult = "build_dir_missing"
    }
    else {
        Write-Host "--- Python HTTP サーバー起動 ---"
        Write-Host "ディレクトリ: $buildWebDir"
        Write-Host "ポート: $Port"

        # python -m http.server をバックグラウンドで起動
        # WindowStyle Hidden でコンソールウィンドウを出さない
        $serverProcess = Start-Process -FilePath $pythonExe -ArgumentList (@($pythonArgs) + @("-m", "http.server", $Port, "--directory", $buildWebDir)) -PassThru -WindowStyle Hidden

        $url = "http://localhost:$Port/"
        $maxWaitSeconds = 30
        $elapsedSeconds = 0
        $pollIntervalSeconds = 1

        Write-Host "--- HTTP 200 応答待ち（最大 ${maxWaitSeconds}秒） ---"

        while ($elapsedSeconds -lt $maxWaitSeconds) {
            try {
                $response = Invoke-WebRequest -Uri $url -TimeoutSec 3 -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    $httpCheckResult = "ok"
                    Write-Host "HTTP 200 応答を確認しました（${elapsedSeconds}秒経過）"
                    break
                }
            }
            catch {
                # サーバー起動中は接続拒否になるのでリトライ
            }

            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds
        }

        if ($httpCheckResult -ne "ok") {
            $httpCheckResult = "timeout"
            Write-Host "タイムアウト: ${maxWaitSeconds}秒以内に HTTP 200 応答が得られませんでした。"
        }
    }

    Write-Host ""
    Write-Host "=== Web ビルド検証テスト結果 ==="
    Write-Host "flutter analyze: 終了コード $($results["analyze"])"
    Write-Host "flutter test:    終了コード $($results["test"])"
    Write-Host "flutter build:   終了コード $($results["build"])"
    if ($httpCheckResult -eq "ok") {
        Write-Host "HTTP 確認:        成功 (200 OK)"
    }
    elseif ($httpCheckResult -eq "build_dir_missing") {
        Write-Host "HTTP 確認:        スキップ (build\web 不在)"
    }
    elseif ($httpCheckResult -eq "no_python") {
        Write-Host "HTTP 確認:        スキップ (python 不在)"
    }
    else {
        Write-Host "HTTP 確認:        失敗 (タイムアウト)"
    }
    Write-Host ""
    Write-Host "注意: HTTP 200 は配信できたことだけを示す。描画と console エラー 0 件は"
    Write-Host "      ブラウザで目視確認すること（このスクリプトは保証しない）。"

    # 全ステップ成功かつ HTTP 200 なら成功
    $allOk = ($results["analyze"] -eq 0) -and ($results["test"] -eq 0) -and ($results["build"] -eq 0) -and ($httpCheckResult -eq "ok")

    if ($allOk) {
        Write-Host ""
        Write-Host "=== Web ビルド検証テスト: すべて成功 ==="
        Write-Host "ブラウザで http://localhost:$Port/ にアクセスして動作を確認してください。"
        exit 0
    }
    else {
        Write-Host ""
        Write-Host "=== Web ビルド検証テスト: 一部失敗 ==="
        exit 1
    }
}
finally {
    # サーバープロセスを必ず停止する（プロセスを残さない）
    Write-Host "--- Python HTTP サーバー停止 ---"
    if ($serverProcess -ne $null) {
        try {
            if (-not $serverProcess.HasExited) {
                $serverProcess.CloseMainWindow() | Out-Null
                Start-Sleep -Seconds 1
                if (-not $serverProcess.HasExited) {
                    $serverProcess.Kill()
                }
            }
        }
        catch {
            # 停止に失敗してもスクリプトを中断しない
        }
    }
}