import 'dart:ui' show Color;

/// 平台视觉标识（品牌色 + 单字徽记）。
///
/// ★ 刻意**不使用各平台官方 logo 图形**（夸克蓝环、UC 松鼠、123 紫块等是注册商标，
///   本项目是独立非官方实现，随开源分发会构成商标使用风险）。
///   这里只用「品牌色底 + 平台首字」这种通用识别方式，功能上等价（一眼认出平台），
///   法律上不复制他人 logo 图形。
class PlatformBrand {
  final Color color;

  /// 徽记文字：单字或 2 字符以内（渲染在色块中心）。
  final String mark;

  /// 次要色（抖音的双色描边等）；为 null 时不画。
  final Color? accent;

  const PlatformBrand({
    required this.color,
    required this.mark,
    this.accent,
  });
}

const Map<String, PlatformBrand> kPlatformBrands = {
  'quark': PlatformBrand(color: Color(0xFF1C63F7), mark: '夸'),
  'uc': PlatformBrand(color: Color(0xFFE9762B), mark: 'U'),
  'pan123': PlatformBrand(color: Color(0xFF6C4CF1), mark: '123'),
  'douyin': PlatformBrand(
    color: Color(0xFF1B1B1F),
    mark: '抖',
    accent: Color(0xFF25F4EE),
  ),
  'xiaohongshu': PlatformBrand(color: Color(0xFFE8354F), mark: '红'),
};

/// 取品牌（未知平台回落到中性灰，保证 UI 不崩）。
PlatformBrand brandOf(String platformId) =>
    kPlatformBrands[platformId] ??
    const PlatformBrand(color: Color(0xFF7A828E), mark: '?');
