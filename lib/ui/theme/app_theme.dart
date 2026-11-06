import 'package:flutter/material.dart';

/// 闪取 SnapFetch 主题 —— **纯 Material 3 原生规范**。
///
/// 设计约束（用户定「去 AI 味，Flutter 那种风格」）：
/// - 只用 [ColorScheme.fromSeed] 生成的 tonal 色板，纯色填充；
/// - **无渐变、无发光、无玻璃拟态、无自定义彩色阴影、无装饰性插画**；
/// - 卡片靠 `surfaceContainerLow` / `outlineVariant` 分层，不靠阴影堆叠；
/// - 圆角/边框/高度/间距全部使用组件默认值，不另造形状；
/// - 语义色（error / tertiary / primary）只用于状态与操作，不作装饰。
///
/// 浅色为默认；深色由同一 seed 生成，保证语义一致。
abstract final class AppTheme {
  /// 品牌 seed：电光蓝（与 logo 一致），但只作为 tonal 色板来源。
  static const Color seed = Color(0xFF2E7BFF);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // 桌面端用紧凑密度（M3 官方 compact，不自定义尺寸）
      visualDensity: VisualDensity.compact,

      // ---- 组件主题：只覆盖必要项，其余全用 M3 默认 ----
      appBarTheme: AppBarTheme(
        centerTitle: false,
        toolbarHeight: 56,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),

      // 卡片：纯色 + 1px 描边，无阴影
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
        margin: const EdgeInsets.only(bottom: 8),
      ),

      // 主按钮 / 次按钮：纯色填充，形状用 M3 默认
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      // 输入框：默认 OutlineInputBorder，无自定义渐变/发光
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: const OutlineInputBorder(),
        isDense: true,
      ),

      // 导航：M3 NavigationRail 默认样式，仅给选中项 tonal 指示
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme:
            IconThemeData(color: scheme.onSecondaryContainer, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),

      // 进度条：M3 默认线性进度（平滑插值由组件自身处理）
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),

      // Chip / SnackBar / Divider 全部默认，仅消除表面着色
      chipTheme: ChipThemeData(
        surfaceTintColor: Colors.transparent,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // 页面过渡统一走 M3 shared axis（见 motion.dart）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: _SharedAxisPageTransitionsBuilder(),
          TargetPlatform.android: _SharedAxisPageTransitionsBuilder(),
          TargetPlatform.iOS: _SharedAxisPageTransitionsBuilder(),
          TargetPlatform.macOS: _SharedAxisPageTransitionsBuilder(),
          TargetPlatform.linux: _SharedAxisPageTransitionsBuilder(),
        },
      ),

      // 水波/高亮使用 M3 默认（不自定义 splashColor / glow）
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// 让所有 Navigator.push 默认具备 shared-axis 过渡。
class _SharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SharedAxisPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(
      parent: animation,
      curve: Easing.standardDecelerate,
      reverseCurve: Easing.standardAccelerate,
    );
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).chain(CurveTween(curve: Easing.emphasizedDecelerate)),
        ),
        child: child,
      ),
    );
  }
}
