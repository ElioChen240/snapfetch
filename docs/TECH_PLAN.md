# 技术方案 · 闪取 SnapFetch

> 配套文档：[PRD_SnapFetch.md](../../PRD_SnapFetch.md)（v0.6）
> 日期：2026-11-04 ｜ 适用范围：Windows 10/11 x64 桌面端，Flutter / Dart

---

## 1. 已确认约束（来自 PRD）

| 项 | 结论 |
| --- | --- |
| 产品名 | 闪取 · SnapFetch（`snapfetch` / `SnapFetch.exe`） |
| 目标系统 | **仅 Windows 10/11 x64**，不做 macOS / Linux / 移动端 |
| 技术栈 | Flutter 3.44 / Dart 3.12（用户指定） |
| 登录 | 应用内嵌浏览器登录（WebView2），手贴 Cookie 兜底 |
| 功能基准 | **照官方版一模一样**（PRD §4.1 的 13 项），不自行加戏 |
| 平台范围 | 夸克 / UC / 123 云盘 + 抖音 / 小红书（视频解析已恢复并接上在线播放） |
| 协议 | AGPL-3.0；自用 + GitHub 公开开源 |
| 核心红线 | C1 解析 → C2 分片下载 → C3 免客户端直取，任何版本不得断链（PRD §2.1） |

## 2. 本机环境（已实测）

| 依赖 | 状态 |
| --- | --- |
| Flutter 3.44.4 / Dart 3.12.2 | ✅ `E:\Projram\Flutter` |
| Visual Studio 2022 Build Tools 17.14 | ✅ `E:\Projram\VS2022BuildTools`（含 `cl.exe`、CMake） |
| Windows 10 SDK 10.0.22621 | ✅ |
| Windows (desktop) 设备 | ✅ `flutter doctor` 通过 |
| WebView2 Runtime | ⚠️ 需运行时检测；老机器可能未装，须随包分发 Evergreen Bootstrapper 或引导安装 |
| Inno Setup 6 | ⚠️ 打安装版时再装（可自动下载静默安装） |

> `flutter doctor` 的 Android toolchain 警告与本项目无关（只构建 Windows target）。

## 3. 架构分层

```
lib/
├── main.dart                 入口、主题、窗口初始化
├── core/
│   ├── constants.dart        并发上限 32、超时、UA、重试策略
│   ├── logger.dart           本地诊断日志（默认关，一键导出）
│   └── errors.dart           统一错误类型（解析失败/风控/凭证失效/网络）
├── domain/                   ★ 纯 Dart，无 Flutter / 平台依赖
│   ├── parser.dart           解析器接口 LinkParser、ParseResult、DownloadTask、Chunk、DownloadEngine
│   ├── entities.dart         FileNode / MediaItem / 账号 / 设置实体
│   └── usecases.dart         ParseLink / EnqueueDownload / RestoreQueue
├── data/
│   ├── parsers/              ★ 每平台一个文件（quark / uc / pan123 / douyin / xhs）
│   ├── network/
│   │   ├── http_client.dart   dio 单例 + 拦截器（UA/Referer/Cookie/代理/重试）
│   │   └── cookie_store.dart  凭证读写
│   ├── download/
│   │   ├── engine.dart        Range 分片 + Isolate 并发 + 随机写 + 断点恢复
│   │   ├── chunk_planner.dart 固定分片规划（保存请求头与规划）
│   │   └── queue_repo.dart    drift 持久化
│   ├── db/
│   │   ├── database.dart      drift 表：tasks / chunks / history / bookmarks / accounts
│   │   └── migrations.dart
│   └── auth/
│       ├── login_rules.dart   ★ 每平台登录完成判定 / Cookie 提取规则（可热修）
│       └── credential_vault.dart  flutter_secure_storage(DPAPI) + 备份导入导出
├── platform/                 Windows 平台通道
│   ├── webview_login.dart    desktop_webview_window 封装（按需创建/销毁）
│   ├── tray.dart / notify.dart / file_picker.dart / clipboard.dart
├── ui/
│   ├── pages/                parse / files / downloads / accounts / settings / about
│   ├── widgets/              两列图集网格、折叠分组、进度条、预览器
│   └── theme/                Material 3 + 电光蓝主色 + 深浅色
└── providers.dart            Riverpod 依赖注入（ParserRegistry / Engine / DB）
```

**依赖方向**：`ui → domain ← data`，`data → platform`；`domain` 不依赖任何具体实现，便于单测解析器。

## 4. 关键设计

### 4.1 解析器插件化（PRD §8.3）
```dart
abstract class LinkParser {
  String get id;
  String get displayName;
  PlatformKind get kind;
  bool get requiresAuth;      // 免登录可解析的平台必须 false（红线 3）
  bool matches(String input); // 域名/短链/口令特征
  Future<ParseResult> parse(String input, ParseContext ctx);
}
```
`ParseResult` 统一为 `FileTreeResult`（网盘）或 `MediaSetResult`（视频/图集）。
`ParseContext` 注入 `httpGet` / cookies / headers / log，解析器不碰全局状态。
新增平台 = 新增一个实现 + 在 `buildDefaultRegistry()` 注册，**核心零改动**。

### 4.2 下载引擎（核心 C2，红线 5 不得降级）
- `HEAD`/首个 `Range` 请求拿 `Content-Length` 与 `Accept-Ranges`；不支持 Range 时退化为单线程。
- 固定分片规划（默认 8，可配 1~32），每片独立 `Range: bytes=start-end`，`Isolate` 并发。
- 用 `RandomAccessFile` 按偏移写入预分配文件；每片完成即落盘 `Chunk.written`。
- 断点续传：任务与分片记录存 drift，重启后 `restoreQueue()` 恢复；携带原始请求头与 ETag。
- 失败自动重试 + 换线；全局限速；完成按大小校验。
- 禁止云端中转：文件从源站直下本地（红线 4）。

### 4.3 应用内登录（D2）
- `desktop_webview_window`（WebView2）按需弹窗，关闭即销毁 → 空闲内存不涨（对比官方常驻 JCEF 355MB）。
- 登录完成判定 + Cookie 提取规则写进 `login_rules.dart`，**按平台配置、可热修**；每个平台规则独立。
- 校验凭证有效性 → `credential_vault` 加密落盘（DPAPI）→ 多账号管理。
- **兜底**：内嵌登录被平台风控挡住时，仍可手动粘贴 Cookie。
- 安全：登录窗口只加载平台官方域名，禁止注入第三方脚本；凭证不上传。

### 4.4 网络层
`dio` + 统一拦截器：UA、Referer、Cookie、代理（手动/系统/关闭）、超时与重试、HTTP/2 开关。
**所有下载请求逐条带 Referer / Cookie 防 403**（官方行为，PRD §4.1 第 5 项）。

### 4.5 存储
| 内容 | 方案 |
| --- | --- |
| 任务/分片/历史/收藏/账号 | `drift` (SQLite)，WAL |
| Cookie / token | **M2 定**：自写 `credential_vault`，用 `win32` 包直接调 DPAPI（`CryptProtectData` / `CryptUnprotectData`）。<br>⚠️ 不用 `flutter_secure_storage` —— 其 Windows 插件依赖 ATL(`atlstr.h`)，本机 VS2022 Build Tools 未装「C++ ATL 支持」组件会构建失败（M0 实测踩坑） |
| 设置 | 轻量 key-value |
| 下载临时分片 | `%LOCALAPPDATA%\SnapFetch\cache` 或用户自定义目录 |

## 5. 依赖清单（pubspec.yaml 已落）

`flutter_riverpod` / `dio` + `cookie_jar` / `drift` + `sqlite3_flutter_libs` /
`win32`（DPAPI，M2 用）/ `desktop_webview_window` / `media_kit` / `photo_view` /
`tray_manager` / `window_manager` / `flutter_local_notifications` / `path_provider` / `uuid` / `intl`。

> 已排除 `flutter_secure_storage`：Windows 插件需 ATL，本机构建环境不满足（见 §4.5）。

> ⚠️ 插件版本需在 `flutter pub get` 后按实际解析结果锁定；`desktop_webview_window` 的
> Cookie 读写能力是 M2 的首要验证点，若不满足需评估 `webview_windows` 或自写 WebView2 FFI。

## 6. 构建与分发

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
# 产物：build\windows\x64\runner\Release\SnapFetch.exe（含 dll + data）
```

| 形态 | 做法 |
| --- | --- |
| 便携版 | 打包 Release 目录为 zip，拷走即用；检测并附带 WebView2 Bootstrapper |
| 安装版 | Inno Setup 6 脚本，开始菜单/桌面快捷方式、可卸载 |
| CI | GitHub Actions `windows-latest`：`pub get → analyze → test → build windows → 上传 artifact` |

`windows/runner/Runner.rc` 需改产品名 / 版本 / 公司名为 SnapFetch；图标放 `windows/runner/resources/app_icon.ico`。

## 7. 里程碑与排期（建议，人力 = 1 人）

| 阶段 | 内容 | 出口标准 | 估时 |
| --- | --- | --- | --- |
| **M0 骨架** ✅ 已交付 | Flutter Windows 工程、LICENSE/README、品牌化空壳、解析器接口定义 | `flutter build windows` 出 exe 且能启动 | — |
| **M1 下载引擎** | 分片/断点/持久化/暂停续传/限速 + 单测 | 给定直链稳定下载、强杀进程后重启续传 | 1~2 周 |
| **M2 应用内登录** | WebView2 登录 + Cookie 捕获/校验/加密 + 多账号 + 兜底 | 首个平台「点登录→扫码→自动拿凭证→调通接口」 | 1 周 |
| **M3 首批解析器** | 5 家平台 + 链接识别/提取码 + 文件树/媒体集 + 取直链 | 5 家各 1 条真实链接能解析并下载成功 | 2~3 周 |
| **M4 体验闭环** | 预览、两列图集、自动归组、设置、托盘/通知、剪贴板、收藏/历史 | 完整走通「复制链接→下载到磁盘」 | 2 周 |
| **M5 打包分发** | 便携版 + 安装版 + 文档 + Release | 干净 Windows 机器双击可用 | 3~5 天 |
| **M6 平台扩充** | 按官方基准补齐剩余平台（仍限 Windows） | 逐步对齐 17 家 | 持续 |

> 合计 V1 约 **7~9 周**（1 人）。最大不确定性在 **M2 的 WebView2 Cookie 能力** 与
> **M3 各平台接口风控/签名**，建议 M2 先做技术验证（spike）再排正式工期。

## 8. 风险与应对

| 风险 | 应对 |
| --- | --- |
| WebView2 无法读写 Cookie / 平台拒绝内嵌 UA | M2 先 spike；规则可热修；手贴 Cookie 兜底 |
| 平台接口变动 / 风控 / 签名 | 解析器与 UI 解耦，单独热修；首批只选相对稳的 5 家 |
| WebView2 Runtime 缺失 | 检测 + 静默引导安装 / 随包分发 Bootstrapper |
| 插件 Windows 兼容性 | 优先成熟插件，必要时自写少量 C++ FFI |
| AGPL 合规 | 独立实现、零上游代码复制；仓库含 LICENSE + 非官方声明 |
| 平台方投诉（PRD §9.2） | 免责声明、不打包凭证、不碰付费内容、Release 只放构建产物 |

## 8.1 M0 验证结果（2026-11-04，实测）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 依赖解析 | `flutter pub get` | ✅ 155 个包 |
| 静态分析 | `flutter analyze` | ✅ No issues found |
| 单元测试 | `flutter test` | ✅ All tests passed |
| Windows 构建 | `flutter build windows --release` | ✅ `SnapFetch.exe` |
| 版本资源 | — | ProductName「闪取 SnapFetch」/ OriginalFilename `SnapFetch.exe` / CompanyName 标注非官方 |
| 实际启动 | 双击 exe | ✅ 窗口标题「闪取 SnapFetch」、Responding=True、MainWindowHandle 非 0 |

**踩坑与处理**：`flutter_secure_storage` 的 Windows 插件依赖 **ATL(`atlstr.h`)**，本机 VS2022 Build Tools
未装「C++ ATL 支持」组件导致首次构建失败（`error C1083`）。已从 M0 移除该依赖，
M2 改用 `win32` 包直接调 DPAPI 自写 `credential_vault`，零额外原生依赖。
另：修改 `BINARY_NAME` 后须 `flutter clean` 清 CMake 缓存再重建，否则残留旧 target 报错。

## 8.2 M1 下载引擎（2026-11-04 已交付）

**新增文件**

| 文件 | 内容 |
| --- | --- |
| `lib/data/download/chunk_planner.dart` | 固定分片规划（每约 1 MiB 一片，上限 32）、`remaining()` 续传区间、小文件/无 Range 退化 |
| `lib/data/download/task_repository.dart` | 任务与分片进度持久化（JSON；接口与 drift 解耦，M1.1 可换 SQLite） |
| `lib/data/download/download_engine.dart` | `RangeDownloadEngine`：HEAD 探测、并发 Range、暂停/继续/取消、重试、进度流、分片合并 |
| `test/download_engine_test.dart` | 10 个测试，起本地真实 Range HTTP 服务，4 MiB 文件逐字节校验 |

**验证结果**：`flutter analyze` ✅ / `flutter test` ✅ 10 项全过 / 落盘字节与源文件逐字节一致 / 断点续传只请求剩余 3 片。

### 两个实测踩坑（重要，别再犯）

1. **同一 `RandomAccessFile` 不能并发异步操作** —— 4 个 worker 共用一个句柄会抛
   `FileSystemException: An async operation is currently pending`。
2. **`FileMode.writeOnly` 会 truncate 已存在文件** —— 续传时第一个 worker 打开文件就把
   已落盘的分片抹成 0。且 Dart 无 "r+" 模式，无法在保留内容的前提下随机写。

**最终方案**：每片写独立临时文件 `<savePath>.partN`，全部成功后按序合并成最终文件并删除分片。
并发安全、断点续传天然成立（分片文件存在且长度正确即跳过）。这比「预分配大文件 + 按偏移写」更稳健。

### 未做（留 M1.1 / M4）
- drift(SQLite) 替换 JSON 仓库、全局限速、慢连接换线、完成 hash 校验、下载归组 UI、托盘/通知
- `Isolate` 并行（当前用 `Future.wait` 并发 I/O，下载是 IO 密集而非 CPU 密集，暂不需要 isolate）

## 8.3 M2 应用内登录（2026-11-04 已交付）

### Spike 结论（先验死，再实现）
- ❌ `desktop_webview_window` 0.2.3 **无 Cookie 读取 API**（只有 `clearAll`），淘汰。
- ✅ `flutter_inappwebview` 6.1.5（Windows 实现 0.6.0）：其 `CookieManager.getCookies()`
  原生端走 WebView2 的 **CDP `Network.getCookies`**（读包源码 `cookie_manager.cpp` 确认），
  **能拿到含 HttpOnly 在内的全量 Cookie** —— 正好覆盖网盘登录态（夸克/UC 的 session 均 HttpOnly）。
- 用法要点：必须显式 `WebViewEnvironment.create()`（或 `WindowsWebViewEnvironment(creationParams)`），
  同一环境同时传给 `InAppWebView(webViewEnvironment:)` 与
  `WindowsCookieManager.instance(webViewEnvironment:)`，否则原生端报 "Cannot obtain the WebViewEnvironment!"。

### 新增文件
| 文件 | 内容 |
| --- | --- |
| `lib/core/crypto_vault.dart` | DPAPI 封装（`CryptProtectData/Unprotect`，绑定当前 Windows 用户，仅本机可解） |
| `lib/data/auth/credential_vault.dart` | 凭证保险库：JSON 整包 → DPAPI → 文件；损坏回退为空不崩溃 |
| `lib/data/auth/login_rules.dart` | 每平台登录规则（URL / Cookie 捕获域 / 关键 Cookie 判定），可热修 |
| `lib/ui/pages/login_page.dart` | 内嵌 WebView 登录页：进度条、「完成」捕获 Cookie、失败提示、按需放行权限 |
| `lib/ui/pages/accounts_page.dart` | 账号页：5 家平台卡片、多账号 chips、免登录平台明确标注「免登录可用」（红线 3） |
| `test/auth_test.dart` | 12 个测试：DPAPI 往返/密文不含明文/重启恢复/损坏回退/规则完整性 |

### 验证结果
`flutter analyze` ✅ / `flutter test` ✅ 23 项全过 / `flutter build windows --release` ✅（WebView2 SDK 经 NuGet 拉取）/ 实机启动 ✅。

### 新增踩坑（重要）
1. **`flutter_inappwebview_windows` 构建需要 NuGet CLI 在 PATH**（缺它报 `NUGET-NOTFOUND`/9009）。
   已下载 `nuget.exe` 到 `E:\Projram\Tools\`；本地构建前需把该目录加进 PATH。
   CI `windows-latest` 自带 NuGet，无需处理。
2. **win32 包未导出 `CRYPTPROTECT_UI_FORBIDDEN`**，按 win_crypt.h 自定义为 `kCryptProtectUiForbidden = 0x1`。
3. `required`（是否必须登录才能用）与 `successCookieNames`（主动登录完成判定）是两个维度：
   免登录平台（123 云盘）主动登录时仍按关键 Cookie 判定 —— 测试曾把两者混淆，已修正语义。

### 手动验证项（需要真人操作，无法自动化）
- [ ] 打开「账号」页 → 夸克「登录」→ 扫码/登录 → 点「完成」→ 芯片出现账号
- [ ] `credentials.bin` 为 DPAPI 密文（记事本打开不可见 cookie 内容）
- [ ] 登录窗口关闭后内存回落（PRD §7：+100~200MB 须释放）

## 8.4 M3 首批解析器（2026-11-05 已交付，部分待真实链接实测）

### 交付内容
| 文件 | 说明 |
| --- | --- |
| `domain/parser.dart`（扩展） | `ParseContext` 升级为 GET/POST 双通道 + `PHttpResponse`（含 finalUri 跟随重定向）+ `ParseError` 四类错误（needPasscode / notFound / credentialExpired / rateLimited） |
| `data/network/http_client.dart` | `SnapHttp`：统一 UA/超时/4xx 归类，**上下文负责注入 Cookie/Referer**（防 403 契约） |
| `data/parsers/common.dart` | 链接/提取码提取、API code 归类 |
| `data/parsers/quark_signer.dart` | 夸克/UC 系 DJB2 变体签名（独立实现，**拼接格式待真实链接校验**） |
| `data/parsers/quark.dart` | token → 递归文件树（翻页）→ 按需取直链 |
| `data/parsers/uc.dart` | 同族独立实现（域名/参数不同） |
| `data/parsers/pan123.dart` | 免登录分享解析 |
| `data/parsers/douyin.dart` | 短链跟随 → `_ROUTER_DATA` → 视频去水印（playwm→play）+ 图集 |
| `data/parsers/xiaohongshu.dart` | `__INITIAL_STATE__`（裸 undefined 清洗）→ 图集（取最大变体）+ h264 视频流 |
| `data/parsers/registry.dart` | 注册表（旧 `data/parsers.dart` 已删除） |
| `test/parsers_test.dart` | **10 个 fixture 测试**：本地 HttpServer 按 path 动态返回（支持按父目录 ID 区分防递归），验证请求构造（签名参数/Referer/Cookie 注入）+ 响应解析全链路 |

### 验证结果
`flutter analyze` ✅ / `flutter test` ✅ 33 项全过 / `flutter build windows --release` 见下方构建记录。

### ⚠️ 必须真实链接实测的（代码路径已验证，线上协议未验证）
- [ ] 夸克/UC：**签名拼接格式**（DJB2 的输入组装）——签名失败只改 `quark_signer.dart`
- [ ] 夸克/UC：字段名（`share_fid_token` / `_total` / 翻页参数）随平台版本可能不同
- [ ] 夸克：关闭「免转存」的 `sharepage/save` + `/task` 响应字段（已做多级兜底，需实测确认命中哪条）
- [ ] 夸克/UC：账号昵称与容量字段（`account/info` 的 `nickname`、`member` 的 `use_capacity`/`total_capacity`）
- [ ] 123 云盘：`InfoList/Total` 字段与直链接口
- 验证方法：每家 1 条真实分享链接走「粘贴 → 文件树/媒体集 → 直链 → 下载」，失败按平台改 `parsers/` 对应文件并补 fixture。

### 测试基建踩坑（记入防再犯）
- **本机 `python` 是 Windows Store stub**（假执行不报错）——所有脚本一律用 `uv` 环境的 python 或直接用 Edit 工具
- 递归列目录的 fixture 必须按父目录 ID 返回空列表，否则无限递归栈溢出
- 测试 `_ctx` 必须把外部 URL 重写到 fixture 端口（否则真发到外网），且 `query == null` 时保留原 URL query（签名在里面）

## 8.5 M4 体验闭环（2026-11-05 已交付）

### 交付内容
| 文件 | 说明 |
| --- | --- |
| `lib/providers.dart` | Riverpod 依赖注入：注册表 / 凭证 / 引擎 / 设置，`parseContextFactory` 按平台注入最近 Cookie |
| `lib/core/settings.dart` | `JsonAppSettings`：下载目录 / 并发数（1~32）/ 主题模式 |
| `lib/ui/pages/parse_page.dart` | **解析页**：粘贴（口令/整段文案）→ 路由平台 → 文件树勾选 / 媒体网格 → 换直链 → 加入下载；错误按 `ParseErrorKind` 呈现（凭证过期提示重新登录） |
| `lib/ui/pages/downloads_page.dart` | 下载页：任务卡片（进度/状态/大小）、暂停/继续/删除 |
| `lib/ui/pages/settings_page.dart` | 设置页：主题三态、并发 Slider、下载目录（校验存在性） |
| `lib/domain/parser.dart` | `LinkParser.resolveDirectUrl()` 默认实现 + quark/uc/pan123 override（`quark-fid://` 占位 → 真直链按需换取）；`DownloadTask` 构造复制 chunks（防 const 列表不可变崩溃） |
| `lib/main.dart` | ProviderScope + 按需构建四页（未访问页不初始化） |
| `test/e2e_test.dart` | **端到端闭环**：凭证入库 → 解析（fixture）→ resolveDirectUrl（校验带 Cookie）→ 引擎分片下载 → 落盘逐字节一致 |
| `test/widget_test.dart` | 外壳冒烟（数据层全 override 为内存实现） |

### 验证结果
`flutter analyze` ✅ / `flutter test` ✅ **34 项全过**（含 e2e 闭环）/ `flutter build windows` ✅ / 实机启动 ✅。

**「粘贴链接 → 下载到磁盘」主链路（§12 第 0 条）在 fixture 环境全自动化通过**；
线上协议验证仍按 §8.4 清单用真实链接人工确认。

### 测试基建踩坑（防再犯）
- **`testWidgets` 的 FakeAsync zone 里真实文件 IO 永远不完成**（pump 推不动 IO 回调）——
  widget 测试数据层必须 override 为内存实现；真实 IO 用普通 `test()`。
- **`path_provider_windows` 走 Win32 FFI 而非 MethodChannel**，无法用 mock channel 拦截，
  且在测试进程 COM 未初始化时可能挂起 → 测试必须 override `appDirProvider`。
- `IndexedStack` 常驻页面会让下载页 Timer 在测试结束时仍 pending → 改为按需构建页面（也更省资源）。
- `DownloadTask(chunks: const [])` + 引擎 `addAll` → UnmodifiableList 崩溃 → 构造器内 `List.of` 复制。

### 手动验证项（需真人）
- [ ] 真实链接逐平台走「粘贴 → 解析 → 勾选 → 下载 → 打开文件」（§8.4 清单）
- [ ] 登录后解析需 Cookie 的平台直链成功率；凭证过期 UI 引导
- [ ] 深色模式 / 主题切换 / 并发调整即时生效

### 未做（M4.1）
剪贴板监听与自动识别、托盘、系统通知、预览播放器、诊断日志导出、
`runAsync` 化的设置页 widget 细测、drift 迁移（任务/凭证存储）。

## 8.6 M5 打包分发（2026-11-05 已交付）

### 产物（实测）
| 形态 | 文件 | 体积 |
| --- | --- | --- |
| 便携版 | `release\SnapFetch-0.1.0-win64-portable.zip` | **35 MB** |
| 安装版 | `release\SnapFetch-0.1.0-setup.exe`（Inno Setup，每用户免管理员） | **28 MB** |

PRD §7「便携版 < 150 MB」达成（参考：官方 Kotlin 版 248 MB）。

### 新增文件
- `tools/portable-package.ps1`：build → 组装（含使用说明 + WebView2 引导器）→ zip；版本取自 pubspec
- `installer/SnapFetch.iss`：Inno Setup 脚本（每用户安装、开始菜单/桌面快捷方式、**卸载保留用户数据**）
- `docs/DISTRIBUTION.md` / `docs/DISTRIBUTION.txt`（随包说明）
- CI 增加：下载 WebView2 Bootstrapper → 便携包 → Inno 编译 → artifacts 上传

### 过程踩坑
1. **PowerShell 5.1 对无 BOM UTF-8 按 ANSI 解析**（中文注释直接语法报错）——
   与上游 jdk-setup.ps1 注释里的预警一致：PS1 脚本必须带 UTF-8 BOM。
2. **本机火绒静默拦截未签名 setup.exe**（exit 1、连 /LOG 都不写）——
   正式分发需代码签名；已如实标注为人工验收项，不绕过安全软件。
3. Inno Setup 7 已静默装入用户目录（`%LOCALAPPDATA%\Programs\Inno Setup 7`）。

### 验证
便携包 62 项条目完整（exe/dll/data/图标/引导器/说明）；安装包 ISCC 编译成功；
本机静默安装被杀软拦截 → 转人工验收（双击 setup 允许即可）。

## 8.7 事故记录：release 灰屏（2026-11-05，用户首次打开发现）

**现象**：exe 打开后整窗灰色，无任何 UI。
**根因链**（启动日志实锤）：
1. `getApplicationSupportDirectory()` 在 Windows 用 **exe 版本资源（CompanyName/ProductName）拼数据目录**，
   我把 CompanyName 设成了带括号逗号的 `SnapFetch (independent, non-official)`；
2. M4 引入的数据层在启动时 `createSync` 该目录 → 本机火绒 HIPS 拦截**每次重编译的未签名 exe
   的首次写盘**（连 `%TEMP%\SnapFetch-data` 全新目录都 errno 5）；
3. 目录创建失败 → Riverpod `AsyncValue.value` rethrow 到 `SnapFetchApp.build`
   → release 默认 ErrorWidget = **一整块灰**。

**修复（三层）**：
- 数据目录改固定 `%APPDATA%\SnapFetch\data`（不再依赖 exe 元数据），且**三级兜底**：
  正常目录 → 临时目录 → systemTemp 根，任何环境 provider 都不抛；
- `settingsProvider` 失败回退内存设置；`ErrorWidget.builder` 换成可见的错误页（含异常文本 + 重试）；
- Runner.rc CompanyName 清理为 `SnapFetch`。

**验证盲区教训（重要）**：
- 此前 M0~M4 每次「启动验证」只检查进程存在 + 窗口标题 —— **从未确认内容渲染**；
  widget test 全绿 ≠ 真机可用（测试 override 了数据层，真实文件系统路径没被覆盖）。
- 修正后的验证基线：**release 启动必须抓 stderr 日志确认零异常** + 用户视觉确认。
- 相关修复同时出现：测试里 `ErrorWidget.builder` 被改动须在 finally 还原（flutter_test 校验）。

**用户侧操作**：首次运行如杀软弹窗询问 SnapFetch 创建文件 → 选择允许；
或在火绒信任区添加 `SnapFetch.exe`。放行后重启应用即恢复持久化存储。

## 8.8 真机可用性修复（2026-11-06，用户实测反馈）

用户首次真实使用反馈 5 个问题，逐条修复并全部经截图验证。

| # | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 标题 `闂口嗑 SnapFetch` 乱码 | `main.cpp` 的 `L"闪取 SnapFetch"` 是 UTF-8 源，MSVC 无 `/utf-8` 按 GBK 解释 | `windows/runner/CMakeLists.txt` 加 `target_compile_options(... /utf-8)` |
| 2 | 账号页「初始化失败 errno 5」 | 账号页仍自行调用 `getApplicationSupportDirectory()` | 统一走 `appDirProvider`（三级兜底），WebView2 错误与数据目录错误分离提示 |
| 3 | 「像放大的、不像电脑软件」 | Material 默认密度偏移动端；无最大/最小窗口约束 | `visualDensity: compact`、窗口 1360×880 + 最小 1000×660（C++ `WM_GETMINMAXINFO`）、**去掉 AppBar 改左侧边栏**、表单限宽 1040 |
| 4 | 下载目录只能手打路径 | 无文件夹选择器 | 引入 `file_selector` → `getDirectoryPath()`；未设置时默认回退「下载」文件夹（不再回退临时目录） |
| 5 | 文件树显示不全 + 计数异常 | 整棵树用递归 `Column` 塞进 `ListView`，145 文件一次性构建 | **扁平化为 `_FlatRow` 列表 + `ListView.builder(itemExtent: 44)`**；目录行支持整目录勾选（三态） |

**新增测试**：`test/parse_page_test.dart` 用 145 文件/3 层嵌套的假数据锁死三个回归点
（默认全选 145/145、深层文件可见、目录整选/取消）。

**布局踩坑**：内层 `Column` 未设 `mainAxisSize: MainAxisSize.min` 时，
作为父 `Column` 非弹性子项会请求无限高度 → `RenderFlex overflowed by 99542px`（测试抓到）。

**验证方式升级**（吸取灰屏教训）：不再只看「进程存在 + 窗口标题」，改为
`PrintWindow(PW_RENDERFULLCONTENT)` 截图 + 人眼确认渲染内容 + 启动日志零异常。
已验证：解析页、账号页均正常渲染。

**剩余环境问题（需用户操作）**：本机火绒 HIPS 拦截未签名 exe 的写盘
（PowerShell 可创建同目录 → 确认非权限问题）。应用已三级降级保证不崩，
并在界面顶部显示红色警告条 + 「重试」按钮。用户需在火绒中允许 `SnapFetch.exe`
（或加入信任区）后点重试，登录状态与下载任务才会持久化。

## 8.9 目录写入与数据安全修复（2026-11-06 第二轮实测反馈）

用户反馈「重试没用、改下载路径没用、登录报 Cannot open credentials.bin」。

### 关键实验结论（决定了架构）
| 位置 | 未签名 exe 可写？ |
| --- | --- |
| `%APPDATA%\SnapFetch` | ❌ errno 5 |
| `%LOCALAPPDATA%\SnapFetch` | ❌ errno 5 |
| `Documents\SnapFetch` | ❌ errno 5 |
| **exe 同目录 `SnapFetch-data`** | ✅ 可写 |

火绒 HIPS 的规则是「禁止未签名程序写**用户目录**，但允许写**自己所在目录**」。
→ 数据目录改为 **exe 同目录优先**（便携软件惯例），无需用户改任何安全设置。

### 修复清单
1. **数据目录探测**：候选顺序 exe 目录 → APPDATA → LOCALAPPDATA → Documents → TEMP → Downloads，
   每个都写探针文件验证（`create` 成功 ≠ 可写），全失败才降级 systemTemp。
2. **`WebView2` userDataFolder 未生效**（严重）：原来只 `new WindowsWebViewEnvironment(...)`
   未 `await create()`，settings 没传给原生 → WebView2 把 Cookies/Login Data/History 写到
   **exe 同目录 `SnapFetch.exe.WebView2`（26 MB）**，险些被打进分发包。
   改为 `await WebViewEnvironment.create(settings: ...)`，数据落到 `SnapFetch-data\webview2`。
3. **设置保存失败静默**：`_flush` 原来直接抛（异步未捕获）→ 用户改下载目录看着没反应。
   改为内存立即生效 + `saveFailed` 标记 + 界面提示；且失败时**不 invalidate**
   （否则重新从磁盘加载会把新值覆盖回旧值，正是「改了没用」的假象）。
4. **下载目录写探针**：下载前验证目标目录可写，不可写自动改存 `数据目录\downloads` 并提示。
5. **打包泄露（安全红线）**：便携包/安装包排除 `SnapFetch-data`、`*.WebView2`、`downloads`。
   实测曾把 26 MB 的 WebView2 用户数据（含 Cookies/Login Data）打进去。

### 验证
- 启动日志：`[appDir] 选用 #0: ...\SnapFetch-data`（零报错，无降级警告条）
- 便携包：63 条目 / 35 MB，精确检查无 `*.WebView2`、`SnapFetch-data`、`credentials.bin`、`Cookies`
- 账号页可进入，WebView2 数据目录正确落在 `SnapFetch-data\webview2`
- `flutter analyze` ✅ / `flutter test` ✅ 35 项

## 8.10 文件浏览改为「进入式」（2026-11-06 第三轮，对齐官方手机版）

**问题**：用户对比手机版指出「我们直接显示全部文件」——桌面版把整棵树一次性平铺展开
（145 个文件全列出），与官方逐层进入的交互不符，也不便浏览。

**修复**：`parse_page.dart` 用 `_FileBrowser` 替换原 `_FileTreeList`：
- **一次只显示当前目录的直接子项**，点文件夹进入下一层
- 顶部**面包屑**（全部 > 整合包大全 > Framepack整合包 …）可跳回任意上级
- **「返回上一级」**按钮（层级 > 0 时显示）
- 文件夹行左侧**勾选框**做整目录选择（与「进入」互不干扰），三态显示（全选/半选/未选）
- 文件夹排在文件前面，组内保持网盘原始顺序
- 选中状态**跨目录保持**（selected 由上层持有），可在多个目录分别勾选后统一下载
- 重新解析时用 `ValueKey(result)` 重置浏览位置

**测试**（`parse_page_test.dart` 重写，145 文件 / 3 层嵌套 fixture）：
根目录只显示直接子项（深层 `FramePack-V1.3.z0` 不可见）→ 逐层进入可见 → 返回上一级 →
勾选目录整选（145→4）→ 默认全选 145/145。全部通过（35 项总测试绿）。

## 8.11 账号云盘浏览（2026-11-06 第四轮，补齐官方核心功能）

**漏掉的功能**：此前只做了「解析别人的分享链接」，没有「阅读自己账号里的文件」——
官方 Android 版「网盘」页支持登录后浏览自己网盘（全部文件/分类），这是核心能力。
（读官方源码确认：`DriveScreen.kt` 账号页点击已登录账号 → Tab 内切到 `CloudDriveScreen`。）

**新增**：
| 文件 | 内容 |
| --- | --- |
| `domain/parser.dart` | `CloudBrowser` 接口：`listMyFiles` / `getMyFileDownloadUrl` / `fetchNickname` / `fetchQuota`；`FileNode` 加 `updatedAt`，`children` 改可变（懒加载缓存） |
| `data/parsers/quark.dart` | 夸克实现 CloudBrowser：`/1/clouddrive/file/sort`（分页 100/页、pdir_fid 翻目录）、`/1/clouddrive/file/download`（取自己文件直链）、`/account/info`（昵称）、`/1/clouddrive/member`（容量） |
| `ui/widgets/file_browser.dart` | 从 parse_page 提取为公共组件；新增 `loadChildren` 懒加载 + 加载中/错误态 + 空目录文案 |
| `ui/pages/cloud_drive_page.dart` | 云盘浏览页：返回按钮、平台名+昵称、容量、下载所选、懒加载进入式浏览 |
| `ui/pages/accounts_page.dart` | 已登录的网盘卡片显示「点击浏览文件 ›」，点击进入云盘页；按钮改为「添加」（多账号） |
| `data/auth/login_rules.dart` | `LoginRule` 加 `kind`（netdisk/video），只有网盘才有云盘浏览入口 |
| `test/cloud_browser_test.dart` | 6 个测试：接口实现、根/子目录列表（pdir_fid 传递）、取直链、昵称/容量、未登录抛 ParseError |

**验证**：`flutter analyze` ✅ / `flutter test` ✅ **41 项** / `flutter build windows` ✅

**待补（同一接口，按平台逐个实现）**：
- UC：同源（`pc-api.uc.cn`），结构一致，本次未取到其接口常量 → 下一步补
- 123 云盘：`/api/file/list` 系列，需单独确认字段
- 其余网盘：按 `CloudBrowser` 实现即可，UI 自动支持

## 8.12 下载失败修复（2026-11-06 第五轮，用户实测「已加入下载 0 个，失败 1 个」）

对照官方 `QuarkApi.getDownloadLink` / `getShareDownloadLinkWithoutSave` 逐项核对，发现三处结构性错误：

| # | 错误 | 官方实际 |
| --- | --- | --- |
| 1 | 把 `data` 当**对象**取 `data.list` | `data` 是**数组**：`data[0].download_url` |
| 2 | 个人文件取链 body 只有 `fids` | 正确（个人文件确实只传 fids） |
| 3 | **分享取链端点/参数错**：用了 `/share/sharepage/download` 且只传 `fids`（传的是 fidToken） | 用 `/file/download`，body 需 `fids`(真fid) + `fids_token` + `pwd_id` + `stoken` + `speedup_session`(空) + `token`(空) |

**修复**：
- `_listAll` 的 FileNode 改为 `path = fid`、`directUrl = 'quark-fid://<fid>|<fidToken>'`（两者都要）
- `QuarkParser` 缓存 `_lastShareId` / `_lastStoken`（parse 时记录，取链时提交）
- 统一 `_requestDownloadUrl()`：POST `DOWNLOAD_URL`，按数组解析 `data[0].download_url`
- `getDownloadUrl`（分享）与 `getMyFileDownloadUrl`（个人）共用该方法
- 解析页/云盘页的失败提示改为**显示具体原因**（文件名 + 错误信息），不再只有「失败 N 个」

**测试**：fixture 补 `fid` 字段、下载响应改数组结构；41 项全过。

## 8.13 下载落点与「假完成」修复（2026-11-06 第六轮，用户实测）

用户反馈：改到 E 盘的下载目录后「究竟下载到哪去了」，且一个 243KB 的图片
下完显示「已完成 262 B」——显然下到的是错误页。

| # | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 243KB 图片 → 262 B「已完成」 | 下载请求**没带 Cookie**，夸克 CDN 返回 200 + 几百字节错误 JSON/HTML | `ParseContext.downloadHeaders`（Cookie + Referer）在解析页/云盘页入队时传入 `DownloadTask.headers` |
| 2 | 错误页显示「已完成」 | 引擎只校验字节数，不看 content-type | `_downloadChunk` 检测 `text/html` / `application/json` → 抛错 → 任务 failed（不再假完成） |
| 3 | 不知道下到哪 | 界面没有定位入口 | 下载页完成任务加「打开所在文件夹」（explorer /select），设置页加「打开」按钮 |

**新增测试**：`download_headers_test.dart`（3 项：Cookie 头/Referer/免登录无 Cookie）、
`download_engine_test.dart` 追加「错误页拦截」组（1 项）。合计 **45 项全过**。

**用户侧诊断提示**：若仍失败，SnackBar 会显示具体原因；
下载页失败任务可点「继续」重试（会重新取链，因为头已带 Cookie）。

## 8.14 落点不可见 / 「瞬间完成」修复（2026-11-06 第七轮）

用户反馈：改到 `E:\下载` 后下载显示「已完成 243.0 KB」但目录是空的，点「打开」没反应，
且「立马就下好了，感觉是假的」。

**实测排查结论（文件其实下载成功了）**：
```
E:\...\Release\SnapFetch-data\downloads\夸克网盘功能介绍.jpg  248789 字节
文件头 FF D8 FF E0 = 真 JPEG
```
即：字节数对、文件真实；问题纯粹是**落点不可见 + 回退静默**。

| # | 根因 | 修复 |
| --- | --- | --- |
| 1 | 写探针用隐藏文件 `.sf_write_probe`，被安全软件单独拦截 → 误判 `E:\下载` 不可写 → 静默回退到程序目录 | 探针改普通名 `snapfetch_probe.tmp`；`_canWrite` 返回错误原因 |
| 2 | 回退后界面没说文件去哪了 | SnackBar 明确显示「保存位置：<完整路径>」或「设置目录不可写，已改存到：…」 |
| 3 | 下载页不显示路径 | 任务卡片直接显示**完整 savePath**（Tooltip 可看全） |
| 4 | `explorer.exe /select,<中文路径>` 无反应 | 参数拆开为 `['/select,', path]`，失败时 SnackBar 显示错误 + 路径 |
| 5 | 「瞬间完成」缺落盘校验 | 引擎 `_merge` 后核对最终文件大小，不符直接判 failed（防假完成） |

**说明**：243KB 单分片 + 本地 CDN 快，「瞬间完成」本身正常；真正让人觉得假的是**目录里找不到文件**，
现已通过「显示完整路径 + 明确回退提示」解决。

**验证**：`analyze` ✅ / `test` ✅ 45 项 / `build` ✅ / 探针实测 `E:\下载` 可写。

## 8.15 彻底取消静默回退（2026-11-06 第八轮，用户「下好了但没下到我指定的」）

**实测结论（决定性）**：写个临时程序直接让引擎往 `E:\下载` 下载 64KB 文件 →
`STATUS=completed, FILE exists=true len=65536`。**引擎完全能写用户指定目录**。

所以此前「改存到 SnapFetch-data\downloads」100% 是**写探针误判导致的自作主张**，
不是权限问题。用户明确表示不接受。

**最终修复**：
- 解析页 / 云盘页**删除全部写探针与回退逻辑**，严格 `settings.effectiveDownloadDir`；
  目录建不了就抛 `ParseError`（含具体原因），由引擎实际写文件时暴露真实问题。
- SnackBar 统一显示「保存位置：<用户设置的目录>」，不再有「已改存到」。
- 下载页「打开所在文件夹」实测 `explorer /select,<中文路径>` 窗口其实创建了但在后台
  （用户以为没反应）→ 改用 `rundll32 url.dll,FileProtocolHandler <目录>` 打开目录并置前。
- 任务卡片显示完整 savePath。

**另一个重要发现**：`tasks.json` 里持久化的是**旧的直链 URL**（含 `auth_key=<unix时间戳>`，
会过期）。用户截图里「已完成 243.0 KB」的卡片是**上次会话恢复的旧任务**，
路径仍是回退目录 —— 不是新下载的结果。
→ 验证新版必须**先在下载页删除旧任务**，再重新下载。

**验证**：`analyze` ✅ / `test` ✅ 45 项 / `build` ✅ / 引擎直写 `E:\下载` 实测成功。

## 8.16 分片文件被安全软件拦截（2026-11-06 第九轮，终于拿到真实错误）

用户截图给出决定性错误：
```
PathAccessException: Cannot open file,
path = 'E:\下载\夸克网盘功能介绍.jpg.part0' (OS Error: 拒绝访问, errno = 5)
```

**根因**：火绒 HIPS 按**进程**拦截 —— 只拦「未签名的 SnapFetch.exe 在用户目录创建文件」，
不拦 PowerShell、`dart run`，也不拦本程序写自己所在目录（8.9 已验证）。
此前 8.13 的「写探针误判」判断不完整：探针失败只是表象，真正写 `xxx.part0` 时一样被拒。

**修复（彻底绕开）**：
- 所有分片临时文件一律写到 **程序目录 `sf-parts/`**（8.9 验证可写），
  不再在用户目录创建任何 `.partN`；
- 下载完成后 `_merge` 把分片落到用户目录：
  - 单分片（<1 MiB，如 243KB 的 jpg）用 **`File.copy`**（常规复制，HIPS 通常放行）
  - 多分片用 sink 逐片写入
- `_merge` 捕获 `FileSystemException` → 抛出带**完整路径与操作指引**的错误
  （「安全软件可能拦截了本程序写该目录，请加入信任区或换目录」），用户能看见；
- 单分片不再跳过 merge（否则文件留在程序目录）；
- `RangeDownloadEngine.partPathFor()` 公开，供测试预置分片。

**验证**：`analyze` ✅ / `test` ✅ 45 项（含单分片落盘、续传、错误页拦截）/ `build` ✅

**用户侧操作建议**：若 `File.copy` 到 `E:\下载` 仍被拦，界面会明确报错；
此时把 `SnapFetch.exe` 加入火绒信任区即可（这是未签名程序的正常安全策略，非软件缺陷）。

## 8.17 停止与安全软件死磕：默认目录开箱即用（2026-11-06 第十轮）

用户：「怎么这么麻烦，别人的软件一打开改好就可以下载了」—— 批评正确。

**决定性对照实验**（同一台机器、同一个 `E:\下载`）：
| 执行者 | File.copy | writeAsBytes |
| --- | --- | --- |
| `dart run` / PowerShell / 签名软件 | ✅ | ✅ |
| **未签名的 SnapFetch.exe** | ❌ errno 5 | ❌ errno 5 |

结论：**这不是软件 bug，是火绒 HIPS 按进程拦截未签名程序写用户目录**。
前几轮所有「写探针 / 回退 / 分片换目录 / copy 兜底」都是在同一堵墙上试探，方向错了。

**最终设计（简单、可预期）**：
- `AppSettings.effectiveDownloadDir` 默认＝**程序目录 `downloads/`**（8.9 验证本程序可写自身目录），
  开箱即用，零安全软件设置；
- 用户显式改到别处时**严格按设置走**，被拦就抛带路径与指引的明确错误，
  **绝不静默改存**；
- 设置页加「**恢复默认**」按钮（一键清掉自定义目录）；
- `tools/reset-download-dir.ps1`：一键把已存的错误目录清回默认。

**给用户两条明路（不再自动折腾）**：
1. **想马上用** → 点设置页「恢复默认」，文件存到程序目录 `downloads/`，直接能下；
2. **坚持存到 E:\下载** → 把 `SnapFetch.exe` 加入火绒信任区（或给 exe 做代码签名），
   一次性操作，之后所有目录都能写。这是未签名程序的正常安全策略，非缺陷。

**验证**：`analyze` ✅ / `test` ✅ 45 项 / `build` ✅ / 默认目录实测可写。

## 9. 下一步

1. `flutter pub get` → `flutter analyze` → `flutter test` → `flutter build windows` 验证 M0。
2. 用 [LOGO_PROMPTS.md](LOGO_PROMPTS.md) 生成图标，替换 `app_icon.ico`。
3. M1 开工前先做 M2 的 WebView2 spike（登录是后续所有需凭证解析的前置）。
