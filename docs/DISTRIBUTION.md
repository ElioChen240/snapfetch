# 发布与分发 · 闪取 SnapFetch

> 配套：[TECH_PLAN.md](TECH_PLAN.md) §8.5 ｜ 产物由 CI（`build-windows.yml`）或本地脚本产出

## 产物清单（v0.1.0 实测）

| 形态 | 文件 | 体积 | 说明 |
| --- | --- | --- | --- |
| **便携版** | `SnapFetch-<版本>-win64-portable.zip` | ~35 MB | 解压即用，免安装；内含 `使用说明.txt` 与 WebView2 引导器 |
| **安装版** | `SnapFetch-<版本>-setup.exe` | ~28 MB | 每用户安装（无需管理员），开始菜单/桌面快捷方式，可卸载；**保留**用户数据 |
| 原始产物 | `build\windows\x64\runner\Release\` | ~80 MB | CI artifact 备用 |

> 对比参考：官方 Kotlin/Compose 桌面版便携包约 248 MB（含 JRE+CEF）。
> PRD §7 目标「便携版 < 150 MB」达成。

## 本地打包

```powershell
# 便携版（-Build 先代跑构建）
.\tools\portable-package.ps1 [-Build]

# 安装版（需 Inno Setup 6/7，装到用户目录即可）
& "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe" installer\SnapFetch.iss
```

产物落在 `release\`。

## WebView2 Runtime

- Win10/11 绝大多数机器已内置（应用内登录依赖）。
- 两个安装包都随附官方 Evergreen Bootstrapper（`MicrosoftEdgeWebview2Setup.exe`，1.9 MB）。
- 缺失时：账号页会提示；用户双击包内引导器安装即可（**需管理员**，官方 per-machine 安装）。
- 应用代码在「账号」页启动时检测 `WebViewEnvironment.getAvailableVersion()` 并提示。

## 版本号

唯一来源：`pubspec.yaml` 的 `version:`（如 `0.1.0+1`）。
- exe 版本资源：构建时 Flutter 自动注入 `Runner.rc`
- 安装包版本：`installer/SnapFetch.iss` 的 `#define MyAppVersion`（**发版需手动同步**，M6 可脚本化）
- 便携包文件名：打包脚本从 pubspec 读取

## 下载目录行为（面向分发，重要）

- **用户设置的目录严格优先**：改到哪就存到哪，不再有任何静默回退/自动改存。
- **未设置时默认**：优先 `%USERPROFILE%\Downloads`（正规软件惯例）；
  仅当本机安全软件按进程拦截本程序写用户目录时，才退回程序目录 `downloads\`。
  设置页会显示当前实际生效的完整路径，并有「打开」「选择文件夹」「恢复默认」。
- **个别机器报「拒绝访问」**：这是未签名 exe 被火绒/360 等 HIPS 按进程拦截，
  **不是软件缺陷**。用户把 `SnapFetch.exe` 加入信任区（或首次运行弹窗点允许）即可，
  之后可任意改下载目录。设置页已内置该提示文案。
- 正式分发若做代码签名，该现象会消失。

## 已知事项（发布前必读）

1. **未签名 → 杀软拦截安装包**：实测本机火绒会静默拦截 `setup.exe` 静默安装（便携版不受影响）。
   正式分发前应购买代码签名证书（EV/OV）签名 `SnapFetch-setup.exe`；个人 GitHub 发布初期
   可在 README 说明「安装包若被拦截请选择允许」。
2. **静默安装参数**：`SnapFetch-setup.exe /VERYSILENT`（Inno 标准参数）。
3. **安装包卸载保留用户数据**（`%APPDATA%\SnapFetch\data`，含加密凭证与任务；被杀软拦截写入时自动降级临时目录），
   这是刻意设计（防误删凭证）；彻底清除需手动删目录。

## 干净机器验收（人工，发布前执行）

- [ ] 全新 Win10 21H2（或 Win11）虚拟机：双击 setup 安装 → 启动 → 解析/下载冒烟 → 卸载
- [ ] 便携版解压到中文路径运行正常
- [ ] 无 WebView2 的机器：账号页提示 + 引导器安装后可用
- [ ] 杀软（Defender + 一款国产）下安装/运行不误报（未签名阶段记录拦截率）

## GitHub Release 流程（建议）

1. push tag `v0.1.0` → CI 产出两件套 artifact
2. Release 正文引用 `Releases.md`（更新说明 + 强制更新字段预留，参考上游做法）
3. Attach 便携包 + 安装包 + 校验和（CI 后续可加 sha256 步骤）
