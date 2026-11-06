import 'dart:ui' show Color;

/// 平台视觉标识：官方图标（可选）+ 自绘徽记（兜底）。
///
/// ★ 关于官方图标
///   各平台 logo 是**注册商标**，本仓库不提交其图片文件
///   （`assets/icons/platforms/*.png` 已在 .gitignore 内）。
///   需要「手机版那种真实图标」时，在自己机器上跑一次
///   `powershell -File tools/fetch-platform-icons.ps1`
///   —— 它从各平台官网取图标；没取到（或没跑）就自动用下面
///   自绘的「品牌色块 + 首字」兜底，功能与识别度等价，界面也不会崩。
class PlatformBrand {
  final Color color;

  /// 徽记文字：单字或 2~3 字符（渲染在色块中心）。
  final String mark;

  /// 官方图标资源路径；null 或加载失败时用 [mark] 色块兜底。
  final String? logoAsset;

  const PlatformBrand({
    required this.color,
    required this.mark,
    this.logoAsset,
  });
}

const Map<String, PlatformBrand> kPlatformBrands = {
  'quark': PlatformBrand(
    color: Color(0xFF1C63F7),
    mark: '夸',
    logoAsset: 'assets/icons/platforms/quark.png',
  ),
  'uc': PlatformBrand(
    color: Color(0xFF2B2B2F),
    mark: 'U',
    logoAsset: 'assets/icons/platforms/uc.png',
  ),
  'pan123': PlatformBrand(
    color: Color(0xFF4E7BF2),
    mark: '123',
    logoAsset: 'assets/icons/platforms/pan123.png',
  ),
  // 视频平台：官网没有可直接取的品牌图标，用自绘色块（黑底 + 青色描影
  // 是抖音图标的观感，红色是小红书的品牌色），不涉及任何商标图形。
  'douyin': PlatformBrand(color: Color(0xFF1B1B1F), mark: '抖'),
  'xiaohongshu': PlatformBrand(color: Color(0xFFE8354F), mark: '红'),
};

/// 取品牌（未知平台回落到中性灰，保证 UI 不崩）。
PlatformBrand brandOf(String platformId) =>
    kPlatformBrands[platformId] ??
    const PlatformBrand(color: Color(0xFF7A828E), mark: '?');
