import 'package:flutter/material.dart';

import '../../core/platform_brand.dart';

/// 平台图标：优先用官方图标（若本机已取到），否则自绘品牌色块兜底。
///
/// 尺寸自适应文字；可直接放进 ListTile 的 leading（40）或卡片头部（28~34）。
class PlatformLogo extends StatelessWidget {
  final String platformId;
  final double size;

  /// 强制只用自绘徽记（测试与「未取官方图标」场景走这条路径）。
  final bool badgeOnly;

  const PlatformLogo({
    super.key,
    required this.platformId,
    this.size = 40,
    this.badgeOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(platformId);
    final asset = brand.logoAsset;
    if (!badgeOnly && asset != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset(
          asset,
          width: size,
          height: size,
          // 图标缺失/损坏 → 退回自绘徽记，绝不留空洞
          errorBuilder: (_, _, _) =>
              PlatformBadge(platformId: platformId, size: size),
        ),
      );
    }
    return PlatformBadge(platformId: platformId, size: size);
  }
}

/// 自绘徽记：品牌色圆角方块 + 平台首字（不含任何第三方图形）。
class PlatformBadge extends StatelessWidget {
  final String platformId;
  final double size;
  final bool circle;

  const PlatformBadge({
    super.key,
    required this.platformId,
    this.size = 40,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final brand = brandOf(platformId);
    final fontSize = size * (brand.mark.length > 1 ? 0.34 : 0.46);

    return Semantics(
      label: platformId,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: brand.color,
          borderRadius: circle ? null : BorderRadius.circular(size * 0.26),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
        ),
        child: Text(
          brand.mark,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
      ),
    );
  }
}
