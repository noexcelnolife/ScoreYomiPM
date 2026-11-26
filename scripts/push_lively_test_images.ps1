# =====================================================================
# push_lively_test_images.ps1
#
# テスト画像（testimage/PC-LI-photo/*.jpg）を Android 端末の
# /data/local/tmp/lively/ へ adb push する補助スクリプト。
# PM Lively（PC 版）リザルト画面の OCR 実測（ground truth との
# 突き合わせ）用。
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File scripts\push_lively_test_images.ps1
#   （任意）-DeviceSerial <serial> で複数端末接続時に対象を指定
#   （任意）-Source <dir> -Destination <device-dir> で別の画像セットを配置
#     例: 切り出し版を再測定するとき
#       -Source build\lively_crop_rect -Destination /data/local/tmp/lively_crop
# =====================================================================

param(
    [string]$DeviceSerial = "",
    [string]$Source = "",
    [string]$Destination = "/data/local/tmp/lively"
)

$ErrorActionPreference = "Stop"

# --- adb.exe の解決 ---------------------------------------------------
$adb = $null
$adbInPath = Get-Command adb.exe -ErrorAction SilentlyContinue
if ($null -ne $adbInPath) {
    $adb = $adbInPath.Source
}
if ($null -eq $adb) {
    $candidate = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
    if (Test-Path $candidate) { $adb = $candidate }
}
if ($null -eq $adb -and $env:ANDROID_HOME) {
    $candidate = Join-Path $env:ANDROID_HOME "platform-tools\adb.exe"
    if (Test-Path $candidate) { $adb = $candidate }
}
if ($null -eq $adb) {
    Write-Error "adb.exe が見つかりません。PATH または ANDROID_HOME を確認してください。"
    exit 1
}
Write-Host "adb: $adb"

# --- 対象端末の解決 ---------------------------------------------------
$listOutput = & $adb devices
$devices = @()
foreach ($line in @($listOutput | Select-Object -Skip 1)) {
    if ($null -eq $line) { continue }
    $parts = ($line.ToString()) -split "\s+"
    if ($parts.Count -ge 2 -and $parts[1] -eq "device") {
        $devices += $parts[0]
    }
}

if ($devices.Count -eq 0) {
    Write-Error "接続済みの Android 端末がありません（adb devices を確認してください）。"
    exit 1
}
if ($DeviceSerial -eq "") {
    if ($devices.Count -gt 1) {
        Write-Error ("複数の端末が接続されています: " + ($devices -join ", ") +
            " 。-DeviceSerial で指定してください。")
        exit 1
    }
    $DeviceSerial = $devices[0]
}
Write-Host "target device: $DeviceSerial"
$serialArgs = @("-s", $DeviceSerial)

# --- 元画像の解決 ------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
if ($Source -ne "") {
    $sourceDir = if ([System.IO.Path]::IsPathRooted($Source)) {
        $Source
    } else {
        Join-Path $repoRoot $Source
    }
} else {
    $sourceDir = Join-Path $repoRoot "testimage\PC-LI-photo"
}

$images = Get-ChildItem -Path $sourceDir -File |
    Where-Object { $_.Extension -in ".jpg", ".jpeg", ".png" } |
    Sort-Object Name

if (@($images).Count -eq 0) {
    Write-Error "テスト画像が見つかりません: $sourceDir"
    exit 1
}
Write-Host ("push 対象: {0} 枚" -f @($images).Count)

# --- push -------------------------------------------------------------
$remoteDir = $Destination
& $adb @serialArgs shell "mkdir -p $remoteDir"
& $adb @serialArgs shell "chmod 755 $remoteDir"

foreach ($img in $images) {
    Write-Host ("push: {0}" -f $img.Name)
    & $adb @serialArgs push $img.FullName "$remoteDir/$($img.Name)" | Out-Null
    # 二重引用符を \" で渡すと adb shell 側で引用が閉じず "no closing quote" になるため単引用符で包む。
    & $adb @serialArgs shell "chmod 644 '$remoteDir/$($img.Name)'"
}

# --- 検証 --------------------------------------------------------------
$lsOutput = & $adb @serialArgs shell "ls $remoteDir"
$remoteFiles = @($lsOutput | Where-Object { "$_" -match "\S" })
Write-Host ("remote files: {0}" -f $remoteFiles.Count)
if ($remoteFiles.Count -lt @($images).Count) {
    Write-Warning ("push されたファイル数が想定より少ない可能性があります " +
        "(ls の結果: {0})。" -f $remoteFiles.Count)
}

Write-Host ("完了: {0} に {1} 枚の画像を配置しました。" -f $remoteDir, @($images).Count)
Write-Host ("次: flutter test integration_test/ocr_batch_lively_test.dart -d {0} " -f $DeviceSerial +
    "--dart-define=LIVELY_IMAGE_DIR={0}" -f $remoteDir)
