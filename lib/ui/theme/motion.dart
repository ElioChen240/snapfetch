import 'package:flutter/material.dart';

/// M3 motion 规范统一入口。
///
/// ★ 全应用只用这里的 duration / curve，不写魔法数字、不加表演性动效
///   （无弹跳/呼吸/脉冲/发光）——「去 AI 味」的核心约束。
/// ★ 曲线取自 Flutter 官方 [Easing]（Material 3 specification），
///   不是自定义 Cubic。
abstract final class Motion {
  // ---- 时长 token（M3：short/medium/long）----
  static const Duration short = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration long = Duration(milliseconds: 450);

  /// stagger 列表项错开间隔
  static const Duration stagger = Duration(milliseconds: 30);

  // ---- 曲线 token ----
  /// 进入/出现（减速）
  static const Curve decelerate = Easing.standardDecelerate;
  /// 强调性进入（页面过渡、关键结果）
  static const Curve emphasized = Easing.emphasizedDecelerate;
  /// 标准（尺寸/位置变化）
  static const Curve standard = Easing.standard;
  /// 退出
  static const Curve accelerate = Easing.standardAccelerate;

  // ---- 位移距离 ----
  static const double slideOffset = 16.0;

  /// 减少动态效果时把所有时长压到 0（系统「减少动画」/软件渲染降级）。
  static bool reduce = false;

  static Duration d(Duration v) => reduce ? Duration.zero : v;
}

/// M3 shared-axis 页面过渡（替代默认硬切 / 平台推挤）。
///
/// 用法：`Navigator.push(sharedAxisRoute(builder: (_) => Page()))`
Route<T> sharedAxisRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: Motion.d(Motion.medium),
    reverseTransitionDuration: Motion.d(Motion.medium),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(
        parent: animation,
        curve: Motion.decelerate,
        reverseCurve: Motion.accelerate,
      );
      final slide = animation.drive(
        Tween<Offset>(
          begin: const Offset(0, Motion.slideOffset / 100),
          end: Offset.zero,
        ).chain(CurveTween(curve: Motion.emphasized)),
      );
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

/// 列表项 stagger 淡入上移（M3：fade + slide，无缩放、无弹性）。
Widget staggerItem({
  required int index,
  required Animation<double> animation,
  required Widget child,
}) {
  if (Motion.reduce) return child;
  final start = (index * Motion.stagger.inMilliseconds) /
      Motion.medium.inMilliseconds;
  final end = (start + 0.6).clamp(0.0, 1.0);
  final curved = CurvedAnimation(
    parent: animation,
    curve: Interval(start.clamp(0.0, 1.0), end, curve: Motion.decelerate),
  );
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: curved.drive(
        Tween<Offset>(
          begin: const Offset(0, Motion.slideOffset / 40),
          end: Offset.zero,
        ),
      ),
      child: child,
    ),
  );
}
