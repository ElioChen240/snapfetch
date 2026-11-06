import 'package:flutter/material.dart';

import '../../core/platform_brand.dart';

/// 平台图标：品牌色圆角方块 + 平台首字。
///
/// 尺寸自适应文字（1 字符大字号、多字符小字号），可直接放进
/// ListTile 的 leading（建议 40）与卡片头部（建议 28）。
class PlatformLogo extends StatelessWidget {
  final String platformId;
  final double size;

  /// 方形（默认）还是圆形。手机版账号卡片是圆角方形。
  final bool circle;

  const PlatformLogo({
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
          borderRadius:
              circle ? null : BorderRadius.circular(size * 0.26),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
        ),
        child: Text(
          brand.mark,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.05,
            // 抖音的黑底配青色描影，做出与官方图标相近的「双色」观感
            shadows: brand.accent == null
                ? null
                : [
                    Shadow(
                      color: brand.accent!.withValues(alpha: 0.9),
                      offset: Offset(-size * 0.02, size * 0.02),
                    ),
                  ],
          ),
        ),
      ),
    );
  }
}
