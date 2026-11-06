import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'providers.dart';
import 'ui/pages/accounts_page.dart';
import 'ui/pages/downloads_page.dart';
import 'ui/pages/parse_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/motion.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 全局初始化（视频/音频预览）。必须在 runApp 前。
  MediaKit.ensureInitialized();
  // ★ 窗口尺寸/最小尺寸由 C++ runner 设置（windows/runner/main.cpp + win32_window.cpp）。
  //   不用 window_manager 的 waitUntilReadyToShow：它先隐藏窗口再等回调 show，
  //   回调异常/超时会让主窗口永久隐藏（实测踩坑）。
  runApp(const ProviderScope(child: SnapFetchApp()));
}

/// 闪取 SnapFetch —— Windows 桌面端入口。
class SnapFetchApp extends ConsumerWidget {
  const SnapFetchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 默认浅色（用户定）；用户可在设置里切「跟随 / 浅 / 深」。
    final mode = ref.watch(settingsProvider).valueOrNull?.themeMode ?? ThemeMode.light;
    // 尊重系统「减少动态效果」：所有动效时长归零（PRD §7）
    Motion.reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return MaterialApp(
      title: '闪取 SnapFetch',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      // release 模式的默认 ErrorWidget 是一整块灰 —— 换成可见的错误页，
      // 任何构建异常都不再是「神秘灰屏」（崩溃可恢复，PRD §7）
      builder: (context, child) {
        ErrorWidget.builder = (details) => _ErrorScreen(details: details);
        return child ?? const SizedBox.shrink();
      },
      home: const _HomeShell(),
    );
  }
}

/// 构建异常的可见错误页（替代 release 的默认灰屏）。
class _ErrorScreen extends StatelessWidget {
  final FlutterErrorDetails details;
  const _ErrorScreen({required this.details});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF6F7FA),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 44, color: Colors.orange),
              const SizedBox(height: 12),
              const Text('界面出现异常',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                details.exception.toString(),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => main(), // 重新初始化应用
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeShell extends ConsumerStatefulWidget {
  const _HomeShell();

  @override
  ConsumerState<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<_HomeShell> {
  @override
  Widget build(BuildContext context) {
    // 导航索引放在 provider 里：页面内部（如解析失败「去账号页」）也能跳转
    final index = ref.watch(navIndexProvider);
    void select(int i) => ref.read(navIndexProvider.notifier).state = i;
    return Scaffold(
      // ★ 桌面式布局：不用 AppBar（窗口标题栏已显示产品名，再叠一层大标题
      //   会挤占纵向空间、显得像手机 APP）。改为左侧固定宽度侧边栏 + 内容区。
      body: Row(
        children: [
          _Sidebar(index: index, onSelect: select),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                // 数据目录降级提示（被安全软件拦截时）—— 必须让用户看见
                ValueListenableBuilder<bool>(
                  valueListenable: appDirFallback,
                  builder: (_, fallback, _) => fallback
                      ? _DataDirWarning(onRetry: () {
                          appDirFallback.value = false;
                          ref.invalidate(appDirProvider);
                        })
                      : const SizedBox.shrink(),
                ),
                // 组 1：页面切换用 M3 shared-axis（淡入 + 轻微上移），替代硬切。
                // 按需构建：未访问的页不初始化（下载页 Timer、账号页 WebView2 环境）。
                Expanded(
                  child: AnimatedSwitcher(
                    duration: Motion.d(Motion.medium),
                    switchInCurve: Motion.emphasized,
                    switchOutCurve: Motion.accelerate,
                    transitionBuilder: (child, animation) {
                      final fade = CurvedAnimation(
                        parent: animation,
                        curve: Motion.decelerate,
                        reverseCurve: Motion.accelerate,
                      );
                      return FadeTransition(
                        opacity: fade,
                        child: SlideTransition(
                          position: animation.drive(
                            Tween<Offset>(
                              begin: const Offset(0, 0.06),
                              end: Offset.zero,
                            ).chain(CurveTween(curve: Motion.emphasized)),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(index),
                      child: switch (index) {
                        0 => const ParsePage(), // 解析 → 下载主链路
                        1 => const DownloadsPage(), // 任务管理
                        2 => const AccountsPage(), // 应用内登录
                        _ => const SettingsPage(), // 设置
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 左侧导航（桌面软件形态：品牌区 + 紧凑列表 + 底部版本）。
class _Sidebar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const _Sidebar({required this.index, required this.onSelect});

  static const _tabs = [
    (icon: Icons.link, label: '解析'),
    (icon: Icons.download, label: '下载'),
    (icon: Icons.account_circle_outlined, label: '账号'),
    (icon: Icons.settings_outlined, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 188,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌区
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Image.asset('assets/icons/snapfetch_compact_32.png',
                    width: 26, height: 26),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('闪取',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text('SnapFetch',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
          // 导航项
          for (var i = 0; i < _tabs.length; i++)
            _NavItem(
              icon: _tabs[i].icon,
              label: _tabs[i].label,
              selected: index == i,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'v0.1.0 · 独立非官方',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 组 2：选中态 tonal 指示用 M3 secondaryContainer（纯色，无发光）
    final bg = selected ? scheme.secondaryContainer : Colors.transparent;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28), // M3 导航指示器全圆角
          onTap: onTap,
          child: AnimatedContainer(
            duration: Motion.d(Motion.short),
            curve: Motion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(28)),
            child: Row(
              children: [
                // 组 7：图标选中微缩放（M3 规范范围内，无弹跳）
                AnimatedScale(
                  scale: selected ? 1.06 : 1.0,
                  duration: Motion.d(Motion.short),
                  curve: Motion.standard,
                  child: Icon(icon, size: 20, color: fg),
                ),
                const SizedBox(width: 12),
                Text(label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 数据目录被拦截的警告条。
class _DataDirWarning extends StatelessWidget {
  final VoidCallback onRetry;
  const _DataDirWarning({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '数据目录不可写（通常是安全软件拦截了本程序）：登录状态与下载任务不会保存。'
              '请在火绒/Defender 中允许 SnapFetch.exe，或把它加入信任区后点「重试」。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
