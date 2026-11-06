<#
  build-installer.ps1 — 打安装包（Inno Setup）

  为什么单独一个脚本：版本号真源是 pubspec.yaml。以前 .iss 里也写了一份，
  改版本漏改这里 → 发出去的 setup 文件名/属性是旧版本。现在版本由本脚本
  从 pubspec 读出后用 /DMyAppVersion= 传给 ISCC，.iss 不再自己维护。

  用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-installer.ps1
      powershell ... -File tools/build-installer.ps1 -Build   # 顺带先跑 flutter build
  前置：装好 Inno Setup 6/7（免费），产物 release\SnapFetch-<版本>-setup.exe
#>
param(
  [switch]$Build,
  [switch]$Force   # 跳过「产物陈旧」检查
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 版本真源：pubspec.yaml
$versionLine = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$version = ($versionLine -split '\+')[0]
Write-Host "[OK] version = $version" -ForegroundColor Green

# 与代码里的 AppInfo.version 对齐（不一致时 test/app_info_test.dart 会红，这里提前拦）
$appInfo = Get-Content 'lib/core/app_info.dart' -Raw
if ($appInfo -notmatch "version\s*=\s*'$version'") {
  throw "lib/core/app_info.dart 的版本与 pubspec.yaml($version) 不一致，请同步"
}

if ($Build) {
  # 同 portable-package.ps1：先清空 Release，避免上次构建的残留 DLL 进包
  $rel = Join-Path $root 'build\windows\x64\runner\Release'
  if (Test-Path $rel) {
    Write-Host ">>> 清理旧构建产物：$rel" -ForegroundColor Cyan
    Remove-Item $rel -Recurse -Force
  }
  Write-Host '>>> flutter build windows --release ...' -ForegroundColor Cyan
  & flutter build windows --release --console=plain
  if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
}

$release = Join-Path $root 'build\windows\x64\runner\Release\SnapFetch.exe'
if (-not (Test-Path $release)) {
  throw 'Release 产物不存在：先跑 flutter build windows --release（或加 -Build）'
}

# 陈旧产物守卫：产物比 pubspec.lock 旧 = 可能残留已删依赖的 DLL
if ((Get-Item $release).LastWriteTime -lt (Get-Item 'pubspec.lock').LastWriteTime -and -not $Force) {
  throw 'Release 产物比 pubspec.lock 旧，可能残留已删除依赖的 DLL。请用 -Build，或确认干净后加 -Force。'
}

# 找 ISCC.exe（Inno Setup 6 或 7，机器级或用户级安装都试）
$candidates = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  'C:\Program Files\Inno Setup 7\ISCC.exe',
  'C:\Program Files\Inno Setup 6\ISCC.exe'
)
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
  throw '未找到 ISCC.exe。请先安装 Inno Setup（https://jrsoftware.org/isinfo.php），或加 winget install JRSoftware.InnoSetup'
}

Write-Host ">>> $iscc /DMyAppVersion=$version ..." -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$version" (Join-Path $root 'installer\SnapFetch.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC 失败（exit $LASTEXITCODE）" }

$out = Join-Path $root "release\SnapFetch-$version-setup.exe"
if (-not (Test-Path $out)) { throw "预期产物不存在：$out" }
$mb = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host ''
Write-Host "安装包就绪：$out ($mb MB)" -ForegroundColor Green
Write-Host '提示：未签名的 setup 在部分国产杀软上会被静默拦截，便携版不受影响。' -ForegroundColor Yellow
