# 界面设计规范 · 闪取 SnapFetch

> 版本 v1.0 ｜ 2026-11-06
> 设计原则：**纯 Material 3 原生规范，去 AI 味**

## 1. 设计原则（为什么这样定）

用户明确要求「去 AI 味，Flutter 那种风格」。据此确立三条硬约束：

| 禁止（AI 味） | 采用（M3 / Flutter 原生） |
| --- | --- |
| 渐变按钮、霓虹发光、玻璃拟态 | `ColorScheme.fromSeed` **tonal 色板**，纯色填充 |
| 自定义彩色阴影、装饰性插画、emoji | 组件默认形状与层级，靠 `surfaceContainer*` 分层 |
| 呼吸/脉冲/弹跳/缩放式表演动效 | **M3 motion 规范**：固定 duration + 官方 easing |

配色只有一个 seed：**`#2E7BFF`**（品牌电光蓝，与 logo 一致），由它生成全部
primary / secondary / tertiary / surface / error 语义色 —— 不手写颜色值。

## 2. 色与层级

| 用途 | Token |
| --- | --- |
| 页面背景 | `surface` |
| 卡片 / 分组 | `surfaceContainerLow` + 1px `outlineVariant` 描边（**无阴影**） |
| 输入框填充 | `surfaceContainerHighest` @35% |
| 导航选中指示 | `secondaryContainer` / `onSecondaryContainer` |
| 主操作 | `primary` 纯色填充 |
| 状态：进行中/完成 | `primary` |
| 状态：暂停 | `tertiary` |
| 状态：失败 | `error` |
| 状态：排队/说明 | `outline` |

**浅色为默认**；深色由同一 seed 生成，用户可在设置切「跟随系统 / 浅色 / 深色」。

## 3. 排版与间距

- 全部使用 M3 文本层级（`titleLarge` / `bodyMedium` / `labelSmall`…），不自定义字号。
- 页面留白统一：`24 / 20 / 24 / 16`（见 `PageScaffold`）。
- 内容区最大宽度 **1120px**（设置页 900px），避免超宽屏拉伸。
- 桌面密度：`VisualDensity.compact`。

## 4. 组件规范

| 组件 | 规范 |
| --- | --- |
| 页面骨架 | `PageScaffold(title, subtitle, actions, child)` —— 6 页统一标题区节奏 |
| 空状态 | `EmptyState(icon, title, description, action)` —— 统一图标/文案/淡入 |
| 列表行 | `_HoverRow`：hover 高亮 + 8px 圆角水波，显式提供 Material 祖先 |
| 卡片 | `CardThemeData`：elevation 0、12px 圆角、1px 描边 |
| 按钮 | 主操作用 `FilledButton`，次操作用 `FilledButton.tonal` / `TextButton` |
| 提示 | `SnackBarBehavior.floating` + 8px 圆角，无 elevation |

## 5. 动效规范（7 组）

所有时长/曲线集中在 `lib/ui/theme/motion.dart`，**不写魔法数字**：

| Token | 值 |
| --- | --- |
| `Motion.short` | 150ms |
| `Motion.medium` | 300ms |
| `Motion.long` | 450ms |
| `Motion.stagger` | 30ms（列表错开） |
| 进入 | `Easing.standardDecelerate` / `emphasizedDecelerate` |
| 退出 | `Easing.standardAccelerate` |
| 尺寸/位置 | `Easing.standard` |

| # | 位置 | 实现 |
| --- | --- | --- |
| 1 | 页面切换 | `AnimatedSwitcher` + fade + 6% 上移（M3 shared-axis） |
| 2 | 导航选中 | `AnimatedContainer` 胶囊 + `AnimatedScale` 图标 1.06 |
| 3 | 解析流程 | 按钮内 `CircularProgressIndicator` + 状态区 fade-through |
| 4 | 文件浏览 | 进出目录 fade + 2% 横向位移 |
| 5 | 下载进度 | `TweenAnimationBuilder` 平滑插值 + 状态图标 `AnimatedSwitcher` |
| 6 | 状态反馈 | floating SnackBar、语义色状态图标 |
| 7 | 微交互 | hover 高亮、`InkSparkle` 水波、`Tooltip` |

**降级**：`Motion.reduce = true` 时所有时长归零。
自动跟随系统「减少动态效果」（`MediaQuery.disableAnimations`）。

## 6. 文件结构

```
lib/ui/
├── theme/
│   ├── app_theme.dart      # ThemeData（浅/深）+ 组件主题 + 页面过渡
│   └── motion.dart         # 时长/曲线 token、sharedAxisRoute、staggerItem
├── widgets/
│   ├── file_browser.dart   # 进入式文件浏览（含 _HoverRow）
│   └── page_scaffold.dart  # PageScaffold + EmptyState
└── pages/                  # 6 个页面，全部走 PageScaffold
```

## 7. 后续可做（未实施）

- 拖拽链接/文件到窗口直接解析（需 `desktop_drop` 或平台通道）
- 列表项键盘导航（↑↓ Enter）
- 深色模式实机视觉走查
- 骨架屏替代 spinner（解析/列表加载时）
