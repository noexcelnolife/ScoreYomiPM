$images = @(
  'G_j8SovaUAAeeHL.jpg',
  'HAtmq0LaMAA3fQw.jpg',
  'HE8eMwTb0AAwJOV.jpg',
  'HE9FveQaEAApshk.jpg',
  'HFCNzIBa4AAJQac.jpg',
  'HFJY5E-bIAAqzBA.jpg',
  'HFNsUYSbIAA9gmx.jpg',
  'HgbGrbia8AAdP8d.jpg',
  'HGRWuJeakAAwRV4.jpg',
  'HHxpJnDboAAMHWJ.jpg',
  'HJS4fvoa4AAGDEF.jpg',
  'HOjcQkDbIAARv7s.jpg',
  'HSi7ZNDbcAAzaF7.jpg',
  'HV8q_4WaEAEbLHQ.jpg',
  'HW7cJQabkAETBKb.jpg',
  'HWhP_5lbsAAjrj1.jpg',
  'HWNFzW0awAAChzB.jpg',
  'HWr-kM7aYAAJApR.jpg',
  'HWSQHQCbAAAa4xE.jpg',
  'HWxJNvybwAEQz48.jpg',
  'HXAfzXHbMAEdBHI.jpg',
  'HXexEwtaIAA-sF2.jpg',
  'HXfcDNma4AAplrZ.jpg',
  'HXoFHBhbYAAKdr-.jpg',
  'HXpqyrfakAAbo3G.jpg',
  'HXQFG2CaUAAR4sc.jpg',
  'HXt-zFta4AAbrtN.jpg',
  'HXtt8jgaMAEF8Tp.jpg',
  'HXuql59aUAE_WYF.jpg',
  'HXurIALa0AAkc0R.jpg'
)

# testimage/ はローカル検証用の画像置き場で、端末ごとに場所が変わる。
# 個人の絶対パスを書くと別環境で動かないため、スクリプト位置（lib/ocr）からリポジトリ直下を求め、
# 実行時のカレントディレクトリにも依存させない。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$photoDir = Join-Path (Join-Path $repoRoot 'testimage') 'AC-HC-photo'

foreach ($img in $images) {
  $photoPath = Join-Path $photoDir $img
  $outPath = Join-Path $photoDir "ac_v1_overlay_$img"
  $cmd = "C:\dev\flutter\bin\cache\dart-sdk\bin\dart run tool/generate_ac_overlay.dart $photoPath $outPath"
  Write-Host "Processing: $img"
  Invoke-Expression $cmd
  Write-Host "Done`n"
}