# 发布与分发 · 闪取 SnapFetch

> 配套：[PRD.md](PRD.md) §12 发布检查清单 ｜ [TECH_PLAN.md](TECH_PLAN.md)
> 本版数字为 2026-11-06 干净构建实测，不是估算。

## 产物清单（v0.2.0 实测）

| 形态 | 文件 | 体积 | 说明 |
| --- | --- | --- | --- |
| **便携版** | `SnapFetch-<版本>-win64-portable.zip` | **34.2 MB** | 解压即用；内含 `使用说明.txt` + WebView2 引导器 + `*.sha256` |
| **安装版** | `SnapFetch-<版本>-setup.exe` | **26.7 MB** | 每用户安装、无需管理员、可卸载；保留用户数据 |
| 原始产物 | `build\windows\x64\runner\Release\` | 79 MB（14 个 DLL） | CI artifact 备用 |

以上为 2026-11-06 本机实测（Inno Setup 7，lzma2/max + SolidCompression）。
setup.exe 的文件属性已写入版本/产品名/发布者（`VersionInfoVersion` 等），
「属性 → 详细信息」不再是空的。

对比：官方 Kotlin/Compose 桌面版便携包约 248 MB（含 JRE + CEF）。
PRD §7 目标「便携版 < 150 MB」大幅达成。

> ⚠️ **别用旧构建目录直接打包。** `flutter build` 只覆盖自己产出的文件，
> 不会删除上一次留下的东西。实测同一目录在清理依赖后不重建，包里仍带着
> `sqlite3.dll`、`tray_manager_plugin.dll`、`window_manager_plugin.dll` 等
> 已删依赖的 DLL，Release 目录 129 MB / 21 个 DLL —— 清掉后 79 MB / 14 个。
> 两个打包脚本已加「产物比 pubspec.lock 旧就中止」的守卫，CI 用 `-Force`
> 跳过（干净 checkout 不存在残留）。

## 本地打包

```powershell
# 便携版（-Build 会先清空 Release 再构建，推荐）
.\tools\portable-package.ps1 -Build

# 安装版（需 Inno Setup 6/7；版本自动从 pubspec 注入）
.\tools\build-installer.ps1            # 已有构建产物
.\tools\build-installer.ps1 -Build     # 顺带重新构建
```

产物与校验和落在 `release\`。

## 版本号（只有一处真源）

`pubspec.yaml` 的 `version:` 是唯一真源，其余全部由它派生：

| 出现位置 | 怎么来 |
| --- | --- |
| exe 版本资源 | Flutter 构建时自动注入 `Runner.rc` |
| 应用内「关于」/侧边栏 | `lib/core/app_info.dart`，**有测试**断言与 pubspec 一致（`test/app_info_test.dart`），忘了同步 CI 直接红 |
| 便携包文件名与使用说明 | `portable-package.ps1` 从 pubspec 读 |
| 安装包版本与文件名 | `build-installer.ps1` 读出后 `/DMyAppVersion=` 传给 ISCC |

## 分发包内容红线

打包脚本会剔除两类东西，缺一即视为发布事故：

1. **运行时数据**：`SnapFetch-data`（加密凭证 / 任务 / 设置 / 收藏 / 历史）、
   `*.WebView2`（Cookies / Login Data / History / LocalStorage）、`downloads`。
2. **平台官方图标** `assets/icons/platforms/*.png`：各平台 logo 是注册商标，
   本机跑 `tools/fetch-platform-icons.ps1` 自取可以，打进公开分发包不行。
   剔除后 `Image.asset` 加载失败会走 `errorBuilder`，自动改用自绘品牌色块，
   界面不留空洞。已实测：zip 内平台图标 0 个、运行时数据 0 项、已删依赖 DLL 0 个。

## WebView2 Runtime

- Win10/11 绝大多数机器已内置（应用内登录依赖）。
- 两个包都随附官方 Evergreen Bootstrapper（`MicrosoftEdgeWebview2Setup.exe`，1.9 MB）。
- 缺失时账号页会提示；用户双击包内引导器安装（**需管理员**，per-machine）。
- 应用在账号页启动时调 `WebViewEnvironment.getAvailableVersion()` 检测并提示。

## 下载目录行为（面向用户，重要）

- **用户设置的目录严格优先**：改到哪存到哪，无任何静默回退/改存。
- **未设置时默认**：优先 `%USERPROFILE%\Downloads`；仅当本机杀软按进程拦截
  本程序写用户目录时，才退回程序目录 `downloads\`。设置页显示当前生效全路径。
- **报「拒绝访问」**：未签名 exe 被火绒/360 等 HIPS 拦截，不是软件缺陷；
  把 `SnapFetch.exe` 加入信任区即可。设置页内置该提示文案。
- 正式分发做代码签名后该现象消失。

## 发布流程（GitHub）

```bash
# 1. 确认全绿
flutter analyze && flutter test
# 2. 打 tag → CI 自动构建 + 建 Release + 挂产物与 sha256
git tag v0.2.0 && git push origin v0.2.0
```

CI（`.github/workflows/build-windows.yml`）：
- `push` 到 `main`/`master`、PR、手动触发 → analyze + test + build + 两件套 artifact
- `push` tag `v*` → 额外跑 release job，用 `CHANGELOG.md` 作为 Release 正文

## 发布前人工验收（PRD §11 / §12）

- [ ] **全新 clone 直接构建**：`git clone` → `flutter pub get` → `flutter analyze`
      → `flutter test` → `flutter build windows --release` 全绿
      （曾因 pubspec 声明了空的 `assets/images/` 导致别人 clone 后 analyze 直接失败）
- [ ] 三家网盘各 1 条真实链接走通：粘贴 → 文件树 → 勾选 → 下载 → 文件真在指定目录
- [ ] 关闭「免转存下载」下一次：自己的网盘里确实出现该文件
- [ ] 账号页夸克卡片显示昵称与容量条
- [ ] 文档截图已更新：`SnapFetch.exe --snapshot=docs/images`
      （应用自己渲染导出，真实字体与主题；不需要屏幕截图权限，
      远程/无桌面环境也能跑。flutter test 的 golden 会把中文渲染成豆腐块，别用）
- [ ] 全新 Win10/Win11 虚拟机：装 setup → 冒烟 → 卸载（数据保留符合预期）
- [ ] 便携版解压到含中文/空格路径正常
- [ ] 无 WebView2 的机器：提示 + 引导器安装后可用
- [ ] Defender + 一款国产杀软下安装/运行表现记录在案（未签名阶段）
- [ ] `AppInfo.repoUrl` 与 README 的 Releases 链接指向真实仓库地址

## 已知事项

1. **未签名**：国产杀软可能静默拦截 `setup.exe`（便携版不受影响）。
   正式分发前购买 OV/EV 代码签名；初期可在 README 说明「被拦截请选允许」。
2. **静默安装**：`SnapFetch-setup.exe /VERYSILENT`（Inno 标准参数）。
3. **卸载保留用户数据**（防误删凭证），彻底清除需手动删目录。
4. **视频/音频在线预览暂无入口**：随抖音/小红书下架失去数据源。
   是否拆掉 `media_kit`（`libmpv-2.dll` 单文件约 29 MB，占当前包体 37%）待定；
   拆掉后 zip 预计降到约 20 MB。
5. **本机无法完整验证 clean-clone 构建**：本地缺 `nuget` CLI，
   `flutter_inappwebview_windows` 拉取 WebView2 SDK 的构建步骤会失败
   （GitHub runner 预装，不受影响）。因此**发布以 CI 绿为准**，不以本地构建为准。
