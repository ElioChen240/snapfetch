# 闪取 SnapFetch 便携版打包脚本
# 用法: .\tools\portable-package.ps1   （需先完成 flutter build windows --release，或加 -Build 让脚本代跑）
# 产物: release\SnapFetch-<版本>-win64-portable.zip
param(
    [switch]$Build
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
Write-Host "Working directory: $root" -ForegroundColor Cyan

# 版本号唯一来源：pubspec.yaml
$versionLine = (Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$version = ($versionLine -split '\+')[0]
Write-Host "[OK] App version: $version" -ForegroundColor Green

if ($Build) {
    Write-Host ">>> flutter build windows --release ..." -ForegroundColor Cyan
    & flutter build windows --release --console=plain
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
}

$src = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path "$src\SnapFetch.exe")) {
    throw "Release 产物不存在：请先 flutter build windows --release（或加 -Build）"
}

$outDir = Join-Path $root "release"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

# ---- 组装便携包目录 ----
$stage = Join-Path $outDir "SnapFetch"
New-Item -ItemType Directory -Path $stage | Out-Null

# ★ 排除运行时数据（安全红线，绝不能打进分发包）：
#   - SnapFetch-data：用户凭证/任务/设置
#   - *.WebView2：WebView2 浏览器数据（Cookies / Login Data / History / LocalStorage）
#   - downloads：回退下载目录
Get-ChildItem $src -Force | Where-Object {
    $_.Name -notlike '*WebView2' -and
    $_.Name -notin @('SnapFetch-data', 'downloads', '.snapfetch_write_test')
} | ForEach-Object {
    Copy-Item $_.FullName $stage -Recurse -Force
}

# WebView2 引导安装器（老机器缺 Runtime 时用户可双击安装）
$bootstrapper = Join-Path $root "packaging\MicrosoftEdgeWebview2Setup.exe"
if (Test-Path $bootstrapper) {
    Copy-Item $bootstrapper $stage -Force
    Write-Host "[OK] WebView2 bootstrapper included" -ForegroundColor Green
} else {
    Write-Host "[WARN] 未找到 WebView2 bootstrapper（packaging/MicrosoftEdgeWebview2Setup.exe）" -ForegroundColor Yellow
}

# 使用说明
$readme = @"
闪取 SnapFetch v$version —— 粘贴分享链接，直接高速下载
独立实现 · 非官方 · 开源 (AGPL-3.0)

【使用】
1. 双击 SnapFetch.exe 运行（免安装）
2. 「账号」页登录网盘（应用内完成，凭证仅存本机加密）
3. 「解析」页粘贴分享链接或视频口令
4. 勾选文件 → 下载所选 → 「下载」页查看进度

【若启动提示缺 WebView2 Runtime】
双击包内的 MicrosoftEdgeWebview2Setup.exe 安装后再运行 SnapFetch.exe

【数据位置】
下载任务 / 凭证 / 设置：C:\Users\<你>\AppData\Roaming\com.snapfetch\snapfetch\data
（删除该目录即完全卸载，不留残余）

【免责声明】
仅供个人学习与技术交流，请勿用于商业用途。
下载内容版权归原作者所有，请遵守所在地法律与相关平台服务条款。
使用第三方网盘可能触发账号风控，风险由使用者自行承担。

https://github.com/  (项目主页见 README.md)
"@
Set-Content -Path (Join-Path $stage "使用说明.txt") -Value $readme -Encoding UTF8

# ---- 压缩 ----
$zip = Join-Path $outDir "SnapFetch-$version-win64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ""
Write-Host "Portable package ready: $zip ($size MB)" -ForegroundColor Green
