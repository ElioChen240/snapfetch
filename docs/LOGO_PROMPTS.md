# Logo 生成提示词 · 闪取 SnapFetch

> 用途：给 AI 生图工具（Midjourney / DALL·E / Stable Diffusion / 即梦 / 通义万相等）直接复制使用。
> 品牌调性：**快、干净、可靠、工具感**；主色 **电光蓝 `#2E7BFF`**，辅色 **亮青 `#22D3EE`**。
> 核心意象：⚡闪电（闪）+ ↓下载箭头 / 链环（取）= 「一闪就把文件取下来」。

---

## 0. 通用设定（每次都带上，放在提示词开头）

```
brand logo for "SnapFetch / 闪取", a Windows desktop download utility,
core concept: lightning bolt + downward download arrow + link chain,
electric blue #2E7BFF with cyan #22D3EE accent,
clean geometric vector, flat minimal, thick rounded strokes,
modern tech but friendly, high contrast, works at 16px favicon size,
centered, pure white background, no text, no mockup, no gradient mesh, no 3D bevel
```

**负面提示词（通用）**
```
no text, no letters, no watermark, no photorealism, no gradient background,
no 3D metallic, no neon glow overload, no clutter, no cartoon mascot,
no cloud shape (avoid confusion with 云析), no animal, no human
```

---

## 方案 A（推荐）｜闪电 × 下载箭头 一体符号

**中文思路**：一个闪电，下半段自然收成一个向下箭头/托盘，表达「闪一下就下载完成」。

**Midjourney v6**
```
minimal vector app icon, a single bold lightning bolt whose lower half
merges into a solid downward arrow landing on a short horizontal tray,
electric blue #2E7BFF to cyan #22D3EE gradient on the bolt only,
rounded corners, perfect symmetry, flat design, white background,
crisp edges, app icon, 1:1 --ar 1:1 --v 6 --style raw --no text, gradient background, 3D
```

**DALL·E / 通用自然语言**
```
Create a flat vector logo icon for a Windows download app called SnapFetch.
Design a single geometric symbol combining a lightning bolt and a download arrow:
the bolt's tail becomes a downward arrow pointing into a short horizontal bar (a tray).
Use electric blue #2E7BFF as the main color with a subtle cyan #22D3EE accent.
Rounded thick strokes, minimal, high contrast, readable at 16x16 px,
centered on a pure white background, no text, no shadow, no 3D.
```

**SDXL**
```
(masterpiece, best quality:1.2), flat vector logo, minimal app icon,
lightning bolt merged with download arrow, electric blue and cyan,
geometric, rounded strokes, white background, centered, crisp, no text
Negative: text, letters, photorealistic, 3d render, bevel, glow, clutter, watermark
```

---

## 方案 B｜链环 + 速度线（强调「链接 → 直取」）

**中文思路**：两个断开的链环被一道闪电瞬间接上/切断，配速度线，突出「解析链接」。

**通用提示词**
```
flat vector logo icon, two interlocking chain links with a bright
lightning bolt crossing diagonally between them, 3 short speed lines trailing,
electric blue #2E7BFF with cyan #22D3EE accent, geometric, thick rounded
uniform strokes, minimal, symmetric, white background, no text, app icon 1:1
```
```
--no text, 3d, photorealism, gradient mesh, watermark, clutter
```

---

## 方案 C｜字母 S 负形（最耐看，适合小尺寸）

**中文思路**：把字母 S 做成闪电/箭头的负形，最简洁，16px 也清楚。

**通用提示词**
```
minimal logo mark, a bold geometric letter "S" formed by a lightning-bolt
cut-out, inside a rounded-square app icon tile, electric blue #2E7BFF tile
with white glyph, subtle cyan #22D3EE corner accent, flat, no gradient,
crisp vector, centered, 1:1, no other text
```

> 注意：C 含字母，若后面要配中文字标「闪取」，建议用 A 或 B 作为主图形，避免双 S 冲突。

---

## 方案 D｜中文标字标组合（用于 README / 关于页横幅）

**通用提示词**
```
clean wordmark design, Chinese characters "闪取" in a modern geometric
sans-serif with slightly angular strokes, followed by "SnapFetch" in
lowercase rounded geometric latin, electric blue #2E7BFF,
a small lightning-bolt dot replacing the dot of the "i" or above "取",
flat vector, generous spacing, white background, no icon, no mockup
```

---

## 配色 / 规范（给设计师或后续加工）

| 用途 | 色值 |
| --- | --- |
| 主色（闪电/图形） | `#2E7BFF` 电光蓝 |
| 辅色（高光/速度线） | `#22D3EE` 亮青 |
| 深底反白 | 图形用纯白 `#FFFFFF` |
| 中性 | `#0F172A`（文字）、`#F8FAFC`（浅底） |
| 禁止 | 紫色/绿色系（与官方「云析」及常见下载工具撞色）、云朵形状 |

**交付规格**
- 主图标：`app_icon.ico`（Windows，含 16/32/48/256px）+ `snapfetch.svg` + `snapfetch_512.png`
- 横幅：字标组合 PNG（透明底）
- 深色模式：反白版本
- 校验：缩到 16×16 仍能一眼认出；灰度打印不糊

---

## 已采用结果（2026-11-04）

用户按**方案 A** 生成并提供了 1024×1024 图（`C:\Users\moche\Downloads\image-1.png`），已落地：

| 处理 | 说明 |
| --- | --- |
| 裁边居中 | 原图留白多，裁到非透明边界 `(341,148)-(684,876)`，规范为 846×846 正方形（图形占 ~86%） |
| 白底 → 透明 | 按「距白色距离」生成 alpha，保留抗锯齿边缘，适配深色模式/任务栏 |
| 多尺寸 ico | `windows/runner/resources/app_icon.ico` 含 16/32/48/64/128/256px |
| 资源族 | `assets/icons/snapfetch.png`(846) / `snapfetch_512.png` / `snapfetch_{16..256}.png` / `snapfetch_white.png`(深色反白) / `snapfetch_onwhite.png`(展示用) |
| 接入应用 | `lib/main.dart` 空壳页展示品牌图；窗口图标由 `app_icon.ico` 生效 |

### 小尺寸专用简化版（2026-11-04 补充）

原 16px 下闪电折角偏糊，另做了一版**简化加粗**图标专供小尺寸：
- 图形占比提高到 88%（原 86%）、`MaxFilter(5)` 膨胀加粗补偿细节丢失
- 纯蓝→青垂直渐变，去掉细碎折角
- 产物：`assets/icons/snapfetch_compact*.png`（含 16/32/48 单独预览）
- **`app_icon.ico` 已改用这一版**（≤48px 清晰，≥64px 同样可接受）

源图仅作位图资产使用；**未生成 SVG**。后续若需任意缩放/换色，建议按 §交付规格 矢量化重绘。

## 生成后怎么用（通用流程）

1. 存为 `assets/icons/snapfetch.png`
2. 转成 `windows/runner/resources/app_icon.ico` 覆盖脚手架默认图标
3. `Runner.rc` 里的产品名 / 公司名 / 版本同步为 `SnapFetch`
4. 应用内「关于」页放字标组合 + 「独立实现 · 非官方」标注（PRD §9）

> 提示词生成的是位图/概念稿；**正式入库前建议矢量化重绘一遍**（SVG），
> 保证小尺寸清晰、可自由换色，也避免 AI 生成物的版权不确定性。
> 当前仓库先用位图交付，SVG 重绘列为后续可选项。
