<#
  fetch-platform-icons.ps1 — 取各平台官网发布的图标到 assets/icons/platforms/

  为什么要单独跑：平台 logo 是注册商标，本仓库不提交这些图片
  （见 .gitignore）。跑一次，界面就是「手机版那种真实图标」；
  不跑则自动退回自绘的品牌色块，功能不受影响。

  用法： powershell -NoProfile -ExecutionPolicy Bypass -File tools/fetch-platform-icons.ps1
  需要联网；单个平台取不到只警告，不中断。
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'assets\icons\platforms'
$tmp = Join-Path $env:TEMP ('sf_icons_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36'

function Get-Icon([string]$url, [string]$dest) {
  Invoke-WebRequest -Uri $url -UserAgent $ua -TimeoutSec 25 -OutFile $dest
}

# 统一转成 PNG 并按目标边长居中留白（避免非正方形图标被拉伸）
function Save-Square([string]$src, [string]$dest, [int]$side, [int]$cropW = 0) {
  $img = [System.Drawing.Image]::FromFile($src)
  try {
    $w = if ($cropW -gt 0) { $cropW } else { $img.Width }
    $h = $img.Height
    $scale = [Math]::Min($side / $w, $side / $h)
    $dw = [int][Math]::Round($w * $scale); $dh = [int][Math]::Round($h * $scale)
    $bmp = New-Object System.Drawing.Bitmap $side, $side
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img,
      (New-Object System.Drawing.Rectangle ([int](($side - $dw) / 2), [int](($side - $dh) / 2), $dw, $dh)),
      (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
      [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
  } finally { $img.Dispose() }
}

# 平台 → 官网图标地址（均来自各平台自己的站点，改版失效时只需改这里）
$jobs = @(
  @{ id = 'quark';  url = 'https://image.quark.cn/s/uae/g/3o/broccoli/resource/202602/f6439020-13b4-11f1-9342-3944993de2f6.png'; crop = 0 }
  @{ id = 'pan123'; url = 'https://statics.123957.com/static-by-custom/favicon.ico'; crop = 0 }
  # UC 官网只给「松鼠图形 + UC网盘 字标」的横版 logo，取左侧图形区（字标前有整列透明间隔）
  @{ id = 'uc';     url = 'https://g.alicdn.com/code/npm/@ali/uc-pegasus-source-project-uc-cloud-drive-login-static-page/1.1.11/assets/logo.366b53.png'; crop = 122 }
)

foreach ($j in $jobs) {
  $raw = Join-Path $tmp ("raw_" + $j.id)
  $dest = Join-Path $outDir ($j.id + '.png')
  try {
    Get-Icon $j.url $raw
    Save-Square $raw $dest 144 $j.crop
    Write-Host ("  OK  {0,-8} -> {1}" -f $j.id, $dest)
  } catch {
    Write-Warning ("{0} 图标获取失败：{1}（界面将使用自绘品牌色块）" -f $j.id, $_.Exception.Message)
  }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host '完成。重新 flutter build 即可生效。'
