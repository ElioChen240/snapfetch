import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 页面统一骨架：统一内边距 + 标题区 + 内容区。
///
/// 目的：让 6 个页面有一致的视觉节奏（此前只有解析页有标题，其余裸内容）。
/// 样式全部取 M3 默认文本层级，不加自定义字号/字重。
class PageScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  /// 内容区最大宽度（桌面端超宽屏防过度拉伸）；null 表示不限
  final double? maxContentWidth;
  final EdgeInsetsGeometry padding;

  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
    this.maxContentWidth = 1120,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 16),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题区（统一节奏：标题 + 可选说明 + 右侧操作）
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );

    return maxContentWidth == null
        ? content
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth!),
              child: content,
            ),
          );
  }
}

/// 统一空状态（图标 + 主文案 + 可选说明），带 M3 fade-in。
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Motion.d(Motion.medium),
        curve: Motion.decelerate,
        builder: (context, v, child) => Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * Motion.slideOffset),
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(title,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(description!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
