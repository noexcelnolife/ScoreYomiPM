# ランチャーアイコン（H1＝仰角 30 度から見た赤い半球押しボタン）の PNG 一式を生成する。
# 1024px の参照キャンバスをアダプティブアイコンの 108dp キャンバスとみなすので、
#   foreground / monochrome : 108dp -> 108, 162, 216, 324, 432 px
#   ic_launcher / round     :  48dp ->  48,  72,  96, 144, 192 px
# 出力先はこのスクリプトの位置から決めるため、置き場所が変わってもパスを直さなくてよい。
Add-Type -AssemblyName System.Drawing

$Repo = Split-Path -Parent $PSScriptRoot
$Res  = Join-Path $Repo 'android\app\src\main\res'
$Store = Join-Path $Repo 'store'
$Ref  = 1024.0

# ---- H1 geometry (identical to the approved preview) ------------------
$Deg   = 30.0
$Sin   = [math]::Sin($Deg * [math]::PI / 180.0)
$R     = 275.0
$Ry    = $R * $Sin
$DomeH = $R
$WallH = 50.0
$Cx    = $Ref / 2.0
$Cy    = ($Ref + $DomeH - $Ry - $WallH - 60.0) / 2.0
$WallBottom = $Cy + $Ry + $WallH
# 影（ボタン下の落ち影）は描かない。
# WHY(ユーザー決定 2026-11-25): 旧背景 #121A2B では黒い影が見えなかったが、
#   白背景にすると足元にグレーの帯が出る。白背景＋赤いボタンだけの見た目を
#   ユーザーが選んだため、影の描画そのものを外した（A 案=影ありは不採用）。

$BgColor     = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$WallTop     = [System.Drawing.ColorTranslator]::FromHtml('#C9302A')
$WallBottomC = [System.Drawing.ColorTranslator]::FromHtml('#6E1010')
$DomeLight   = [System.Drawing.ColorTranslator]::FromHtml('#FFDAD0')
$DomeDark    = [System.Drawing.ColorTranslator]::FromHtml('#A81812')

function New-WallPath {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc([single]($Cx - $R), [single]($Cy - $Ry), [single](2 * $R), [single](2 * $Ry), 0, 180)
    $p.AddLine([single]($Cx - $R), [single]$Cy, [single]($Cx - $R), [single]($Cy + $WallH))
    $p.AddArc([single]($Cx - $R), [single]($Cy - $Ry + $WallH), [single](2 * $R), [single](2 * $Ry), 180, -180)
    $p.CloseFigure()
    return $p
}

function New-DomePath {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc([single]($Cx - $R), [single]($Cy - $DomeH), [single](2 * $R), [single](2 * $DomeH), 180, 180)
    $p.AddArc([single]($Cx - $R), [single]($Cy - $Ry), [single](2 * $R), [single](2 * $Ry), 0, 180)
    $p.CloseFigure()
    return $p
}

function New-Graphics([System.Drawing.Bitmap]$bmp) {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.ScaleTransform(($bmp.Width / $Ref), ($bmp.Width / $Ref))
    return $g
}

function Draw-Foreground($g) {
    $wall = New-WallPath
    $rect = New-Object System.Drawing.RectangleF([single]($Cx - $R), [single]($Cy - $Ry), [single](2 * $R), [single]($Ry * 2 + $WallH))
    $wg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $WallTop, $WallBottomC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($wg, $wall)
    $wg.Dispose(); $wall.Dispose()

    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 60, 8, 8), [single]4)
    $g.DrawArc($pen, [single]($Cx - $R), [single]($Cy - $Ry), [single](2 * $R), [single](2 * $Ry), 8, 164)
    $pen.Dispose()

    $dome = New-DomePath
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($dome)
    $brush.CenterColor = $DomeLight
    $n = $dome.PointCount
    $colors = New-Object 'System.Drawing.Color[]' $n
    for ($i = 0; $i -lt $n; $i++) { $colors[$i] = $DomeDark }
    $brush.SurroundColors = $colors
    $brush.CenterPoint = New-Object System.Drawing.PointF([single]($Cx - $R * 0.30), [single]($Cy - $DomeH * 0.44))
    $g.FillPath($brush, $dome)
    $brush.Dispose(); $dome.Dispose()

    $bounce = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, 255, 235, 220))
    $g.FillEllipse($bounce, [single]($Cx + $R * 0.02), [single]($Cy + $Ry * 0.10), [single]($R * 0.62), [single]($Ry * 0.62))
    $bounce.Dispose()

    $hl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 255, 255, 255))
    $g.FillEllipse($hl, [single]($Cx - $R * 0.62), [single]($Cy - $DomeH * 0.80), [single]($R * 0.34), [single]($DomeH * 0.22))
    $hl.Dispose()
}

function New-ForegroundBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)
    Draw-Foreground $g
    $g.Dispose()
    return $bmp
}

function New-LegacyBitmap([int]$size, [bool]$round) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = New-Graphics $bmp
    $g.Clear($BgColor)
    Draw-Foreground $g

    if ($round) {
        # round legacy icon: clip everything to the inscribed circle
        $g.ResetClip()
        $g.ResetTransform()
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse(0, 0, $size, $size)
        $outer = New-Object System.Drawing.SolidBrush($BgColor)
        $tmp = New-Object System.Drawing.Bitmap($size, $size)
        $gt = [System.Drawing.Graphics]::FromImage($tmp)
        $gt.DrawImage($bmp, 0, 0, $size, $size)
        $gt.Dispose()
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SetClip($path)
        $g.DrawImage($tmp, 0, 0, $size, $size)
        $g.Dispose(); $tmp.Dispose(); $path.Dispose(); $outer.Dispose()
        return $bmp
    }

    $g.Dispose()
    return $bmp
}

function New-MonochromeBitmap([int]$size) {
    # Solid silhouette; a thin transparent cut along the rim keeps the dome and the
    # base readable as two parts once the system tints it.
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)

    $black = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
    $dome = New-DomePath
    $g.FillPath($black, $dome)
    $dome.Dispose()
    $wall = New-WallPath
    $g.FillPath($black, $wall)
    $wall.Dispose()
    $black.Dispose()

    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $cut = New-Object System.Drawing.Pen([System.Drawing.Color]::Transparent, [single]10)
    $g.DrawArc($cut, [single]($Cx - $R), [single]($Cy - $Ry), [single](2 * $R), [single](2 * $Ry), 12, 156)
    $cut.Dispose()

    $g.Dispose()
    return $bmp
}

function Save-Png($bmp, [string]$path) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$densities = @(
    @{ Name = 'mdpi';    Fg = 108; Legacy = 48 },
    @{ Name = 'hdpi';    Fg = 162; Legacy = 72 },
    @{ Name = 'xhdpi';   Fg = 216; Legacy = 96 },
    @{ Name = 'xxhdpi';  Fg = 324; Legacy = 144 },
    @{ Name = 'xxxhdpi'; Fg = 432; Legacy = 192 }
)

$log = @()
foreach ($d in $densities) {
    Save-Png (New-ForegroundBitmap $d.Fg) (Join-Path $Res "drawable-$($d.Name)\ic_launcher_foreground.png")
    Save-Png (New-MonochromeBitmap $d.Fg) (Join-Path $Res "drawable-$($d.Name)\ic_launcher_monochrome.png")
    Save-Png (New-LegacyBitmap $d.Legacy $false) (Join-Path $Res "mipmap-$($d.Name)\ic_launcher.png")
    Save-Png (New-LegacyBitmap $d.Legacy $true) (Join-Path $Res "mipmap-$($d.Name)\ic_launcher_round.png")
    $log += ("{0,-8} foreground={1,3} monochrome={1,3} legacy={2,3} round={2,3}" -f $d.Name, $d.Fg, $d.Legacy)
}

# Play ストアの掲載用アイコンは APK に含まれない別成果物なので res/ ではなく store/ に置く。
Save-Png (New-LegacyBitmap 512 $false) (Join-Path $Store 'store_icon_512.png')

$log
"store_icon_512.png written to $Store"
