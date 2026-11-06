import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'dev/snapshot_mode.dart';
import 'providers.dart';
import 'ui/home_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/motion.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 全局初始化（视频/音频预览）。必须在 runApp 前。
  MediaKit.ensureInitialized();

  // ★ 文档截图模式：应用自己把各页渲染成 PNG 后退出。
  //   用真实外壳 + 真实字体，不依赖屏幕捕获（远程/无桌面环境下也能出图）。
  //   用法：SnapFetch.exe --snapshot=docs/images
  final snapshotDir = snapshotDirOf(args);
  if (snapshotDir != null) {
    runSnapshot(snapshotDir);
    return;
  }

  // ★ 窗口尺寸/最小尺寸由 C++ runner 设置（windows/runner/main.cpp + win32_window.cpp）。
  //   不用 window_manager 的 waitUntilReadyToShow：它先隐藏窗口再等回调 show，
  //   回调异常/超时会让主窗口永久隐藏（实测踩坑）。
  runApp(ProviderScope(
    overrides: [startupLinkProvider.overrideWithValue(startupLinkOf(args))],
    child: const SnapFetchApp(),
  ));
}

/// 从命令行参数里取一个分享链接（`SnapFetch.exe "https://pan.quark.cn/s/xxx"`）。
///
/// 让「右键 → 打开方式 → 闪取」和浏览器调用有实际意义；
/// 无链接时返回空串，行为与平时完全一致。
String startupLinkOf(List<String> args) {
  for (final a in args) {
    if (a.startsWith('http://') || a.startsWith('https://')) return a;
  }
  return '';
}

/// 闪取 SnapFetch —— Windows 桌面端根 Widget。
class SnapFetchApp extends ConsumerWidget {
  const SnapFetchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 默认浅色（用户定）；用户可在设置里切「跟随 / 浅 / 深」。
    final mode =
        ref.watch(settingsProvider).valueOrNull?.themeMode ?? ThemeMode.light;
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
      home: const HomeShell(),
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
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 44, color: Colors.orange),
                const SizedBox(height: 12),
                const Text('界面出现异常',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  details.exception.toString(),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => main(const []), // 重新初始化应用（原设计）
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
