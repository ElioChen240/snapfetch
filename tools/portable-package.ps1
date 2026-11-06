# 闪取 SnapFetch 便携版打包脚本
# 用法: .\tools\portable-package.ps1   （需先完成 flutter build windows --release，或加 -Build 让脚本代跑）
# 产物: release\SnapFetch-<版本>-win64-portable.zip
param(
    [switch]$Build,
    [switch]$Force   # 跳过「产物陈旧」检查（确认过目录干净时用）
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

# 代码里的 AppInfo.version 必须一致（否则包内「关于」显示旧版本）
$appInfo = Get-Content "lib/core/app_info.dart" -Raw
if ($appInfo -notmatch "version\s*=\s*'$version'") {
    throw "lib/core/app_info.dart 的版本与 pubspec.yaml($version) 不一致，请同步"
}

# 项目主页：从 git remote 自动取，取不到则用 app_info.dart 里的
$AppUrl = (git config --get remote.origin.url 2>$null)
if ($AppUrl -match '^https://github\.com/[^/]+/[^/.]+') { $AppUrl = $Matches[0] } else { $AppUrl = '' }
if (-not $AppUrl) {
    if ($appInfo -match "repoUrl = '([^']+)'") { $AppUrl = $Matches[1] } else { $AppUrl = 'https://github.com/' }
}
Write-Host "[OK] Repo URL: $AppUrl" -ForegroundColor Cyan

if ($Build) {
    # ★ 必须先清空 Release：flutter build 只覆盖自己产出的文件，
    #   不会删除上一次构建留下的东西。删依赖后不清理，旧插件 DLL
    #   （sqlite3.dll / tray_manager / window_manager …）会被原样打进分发包。
    $releaseDir = Join-Path $root "build\windows\x64\runner\Release"
    if (Test-Path $releaseDir) {
        Write-Host ">>> 清理旧构建产物：$releaseDir" -ForegroundColor Cyan
        Remove-Item $releaseDir -Recurse -Force
    }
    Write-Host ">>> flutter build windows --release ..." -ForegroundColor Cyan
    & flutter build windows --release --console=plain
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
}

$src = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path "$src\SnapFetch.exe")) {
    throw "Release 产物不存在：请先 flutter build windows --release（或加 -Build）"
}

# ---- 陈旧产物守卫 ----
# 上次构建早于 pubspec.lock（依赖变过）→ 目录里极可能留着已删依赖的 DLL。
$lock = Get-Item "pubspec.lock"
$exe = Get-Item "$src\SnapFetch.exe"
if ($exe.LastWriteTime -lt $lock.LastWriteTime -and -not $Force) {
    throw @"
Release 产物比 pubspec.lock 还旧，里面可能残留已删除依赖的原生 DLL
（实测会多带 sqlite3.dll、tray_manager、window_manager 等约 50 MB）。
请用 .\tools\portable-package.ps1 -Build（会先清空 Release 再构建），
或确认产物是干净的后加 -Force。
"@
}
$stale = Get-ChildItem $src -Filter *.dll |
    Where-Object { $_.LastWriteTime -lt $exe.LastWriteTime.AddMinutes(-5) }
if ($stale -and -not $Force) {
    Write-Warning ("有 {0} 个 DLL 的时间戳早于本次构建，可能是上次构建残留：{1}" -f `
        $stale.Count, (($stale | Select-Object -First 5 -ExpandProperty Name) -join ', '))
    throw "确认无误后加 -Force 继续。"
}

$outDir = Join-Path $root "release"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

# ---- 组装便携包目录 ----
$stage = Join-Path $outDir "SnapFetch"
New-Item -ItemType Directory -Path $stage | Out-Null

# ★ 排除两类东西，缺一就有问题：
#   1) 运行时数据（安全红线，绝不能打进分发包）：
#      - SnapFetch-data：用户凭证/任务/设置/收藏/历史
#      - *.WebView2：WebView2 浏览器数据（Cookies / Login Data / History / LocalStorage）
#      - downloads：回退下载目录
#   2) 平台官方图标 assets\icons\platforms\*.png：各平台 logo 是注册商标，
#      本机跑 tools/fetch-platform-icons.ps1 取来自用可以，打进公开分发包不行。
#      剔除后应用启动时 Image.asset 失败会走 errorBuilder，自动改用自绘
#      品牌色块（lib/ui/widgets/platform_logo.dart），界面不留空洞。
Get-ChildItem $src -Force | Where-Object {
    $_.Name -notlike '*WebView2' -and
    $_.Name -notin @('SnapFetch-data', 'downloads', '.snapfetch_write_test')
} | ForEach-Object {
    Copy-Item $_.FullName $stage -Recurse -Force
}
Remove-Item (Join-Path $stage 'data\flutter_assets\assets\icons\platforms\*.png') -Force -ErrorAction SilentlyContinue
Write-Host "[OK] 平台官方图标已从分发包剔除（运行时自动回落自绘徽记）" -ForegroundColor Cyan

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
闪取 SnapFetch v$version —— 粘贴网盘分享链接，直接高速下载
独立实现 · 非官方 · 开源 (AGPL-3.0)

【使用】
1. 双击 SnapFetch.exe 运行（免安装）
2. 「账号」页登录网盘（应用内完成，凭证仅存本机并加密）
3. 「解析」页粘贴夸克 / UC / 123 云盘的分享链接（带提取码的整段文案也可以）
4. 勾选文件 → 下载所选 → 「下载」页看进度（可暂停/继续/续传）

【若启动提示缺 WebView2 Runtime】
双击包内的 MicrosoftEdgeWebview2Setup.exe 安装后再运行 SnapFetch.exe

【数据位置】
本程序是便携版：设置 / 加密凭证 / 任务 / 收藏 / 解析历史都写在
SnapFetch.exe 旁边的 SnapFetch-data 目录里（实测这样最稳：未签名的程序
往用户目录写文件容易被国产杀软按进程拦）。
下载目录默认是你的「下载」文件夹，可在「设置」里改，改到哪就存到哪。
删掉 SnapFetch-data 目录即完全清除本机数据，不留残余。

【已知情况】
- 未签名 exe：火绒/360 等可能提示或拦截写入。放行本程序即可，不是软件缺陷。
- 平台接口会改版：解析失效通常是平台侧字段变化，项目开源可自行修改。

【免责声明】
仅供个人学习与技术交流，请勿用于商业用途。
下载内容版权归原作者所有，请遵守所在地法律与相关平台服务条款。
使用第三方网盘可能触发账号风控，风险由使用者自行承担。
本项目与各网盘平台无隶属关系；包内不含任何平台商标图形。

项目主页：$AppUrl
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

# 校验和：Release 正文要贴，用户也能自验下载是否被篡改
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content -Path "$zip.sha256" -Value "$hash  $(Split-Path -Leaf $zip)" -Encoding ascii
Write-Host "[OK] SHA256: $hash" -ForegroundColor Green
Write-Host '     （已写入 release\SnapFetch-<版本>-win64-portable.zip.sha256）'
