# 一键把下载目录恢复为默认（程序目录\downloads，安全软件允许写入）
# 用于：之前把下载目录改到用户目录后被火绒拦截、下载失败的情况
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exeDir = Join-Path $root 'build\windows\x64\runner\Release'
$settings = Join-Path $exeDir 'SnapFetch-data\settings.json'
if (Test-Path $settings) {
  $json = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
  $json | Add-Member -NotePropertyName download_dir -NotePropertyValue '' -Force
  # 无 BOM UTF-8：PowerShell 5.1 的 -Encoding UTF8 会写 BOM，Dart jsonDecode 会失败
  $text = $json | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText(
      $settings, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host '[OK] 已恢复默认下载目录' -ForegroundColor Green
  Write-Host "     文件将保存到: $exeDir\downloads"
} else {
  Write-Host '[i] 尚无设置文件，默认已是程序目录，无需处理'
}
