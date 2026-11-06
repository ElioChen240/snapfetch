import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import '../../domain/parser.dart';
import '../../providers.dart';
import '../theme/motion.dart';
import '../widgets/page_scaffold.dart';

/// 下载页（PRD §4.1 第 11 项）：任务列表、进度、暂停/继续/删除。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  final List<DownloadTask> _tasks = [];
  StreamSubscription<DownloadTask>? _sub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _listen();
  }

  Future<void> _load() async {
    final engine = await ref.read(downloadEngineProvider.future);
    final tasks = await engine.restoreQueue();
    if (!mounted) return;
    setState(() {
      _tasks
        ..clear()
        ..addAll(tasks);
    });
  }

  void _listen() {
    // 每次引擎 emit 就更新对应任务；再叠加低频刷新兜底（速度估算用）
    ref.listenManual(downloadEngineProvider, (_, _) {
      _sub?.cancel();
      () async {
        final engine = await ref.read(downloadEngineProvider.future);
        _sub = engine.progressStream.listen((t) {
          if (!mounted) return;
          final i = _tasks.indexWhere((x) => x.id == t.id);
          setState(() {
            if (i == -1) {
              _tasks.insert(0, t);
            } else {
              _tasks[i] = t;
            }
          });
        });
      }();
    }, fireImmediately: true);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _pause(DownloadTask t) async {
    final engine = await ref.read(downloadEngineProvider.future);
    await engine.pause(t.id);
  }

  Future<void> _resume(DownloadTask t) async {
    final engine = await ref.read(downloadEngineProvider.future);
    await engine.resume(t.id);
  }

  Future<void> _delete(DownloadTask t) async {
    final engine = await ref.read(downloadEngineProvider.future);
    await engine.cancel(t.id, deleteFile: false);
    setState(() => _tasks.removeWhere((x) => x.id == t.id));
  }

  /// 在资源管理器中定位文件（用户不知道下到哪了 —— 实测反馈）。
  ///
  /// ★ 实测 `explorer.exe /select,<中文路径>` 窗口其实已创建但停留在后台，
  ///   用户以为「点了没反应」。用 `ShellExecuteW(SW_SHOWNORMAL)` 强制显示窗口；
  ///   另外多数用户只想要「打开目录」，直接打开所在目录更直观可靠。
  Future<void> _openInExplorer(DownloadTask t) async {
    if (!Platform.isWindows) return;
    try {
      final file = File(t.savePath);
      final dir = file.parent;
      await dir.create(recursive: true);
      // 打开所在目录（不依赖 /select 的中文路径解析）
      final result = await Process.run(
        'rundll32.exe',
        ['url.dll,FileProtocolHandler', dir.path],
      );
      if (result.exitCode != 0) {
        // 兜底：直接 explorer
        await Process.run('explorer.exe', [dir.path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('打开失败：$e\n路径：${t.savePath}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '下载',
      subtitle: _tasks.isEmpty ? null : '${_tasks.length} 个任务',
      child: _tasks.isEmpty
          ? const EmptyState(
              icon: Icons.download_outlined,
              title: '暂无下载任务',
              description: '去「解析」页粘贴分享链接，勾选文件后开始下载',
            )
          : ListView.builder(
              itemCount: _tasks.length,
              itemBuilder: (_, i) {
                final t = _tasks[i];
                return _TaskCard(
                  task: t,
                  onPause: () => _pause(t),
                  onResume: () => _resume(t),
                  onDelete: () => _delete(t),
                  onOpenFolder: () => _openInExplorer(t),
                );
              },
            ),
    );
  }

}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;

  const _TaskCard({
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    required this.onOpenFolder,
  });

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }

  /// 状态视觉全部取自 theme 语义色（不硬编码 orange/green/grey）。
  (IconData, Color, String) _statusVisual(ThemeData theme) {
    final s = theme.colorScheme;
    switch (task.status) {
      case TaskStatus.running:
        return (Icons.downloading, s.primary, '下载中');
      case TaskStatus.paused:
        return (Icons.pause_circle_outline, s.tertiary, '已暂停');
      case TaskStatus.completed:
        return (Icons.check_circle, s.primary, '已完成');
      case TaskStatus.failed:
        return (Icons.error_outline, s.error, '失败');
      case TaskStatus.queued:
        return (Icons.schedule, s.outline, '排队中');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = _statusVisual(theme);
    final name = task.savePath.split(Platform.pathSeparator).last;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            // 组 5：状态图标切换淡入（M3，无弹性打勾）
            AnimatedSwitcher(
              duration: Motion.d(Motion.short),
              child: Icon(icon, key: ValueKey(task.status), size: 20, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium)),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.labelSmall),
          ]),
          const SizedBox(height: 8),
          // 组 5：进度平滑插值（M3 原生 TweenAnimationBuilder，无数字滚动/弹跳）
          TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0,
              end: task.status == TaskStatus.completed ? 1.0 : task.progress,
            ),
            duration: Motion.d(Motion.short),
            curve: Motion.standard,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          // ★ 显示完整保存路径：用户改了下载目录后被回退到别处时，
          //   界面必须明确告诉用户文件到底在哪（实测「E:\下载 是空的」）
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Tooltip(
              message: task.savePath,
              child: Text(
                task.savePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          // ★ 失败时显示具体原因（用户实测只看到「失败」无从判断）
          if (task.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                task.errorMessage!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 6),
          Row(children: [
            Text('${_fmtBytes(task.downloadedBytes)} / ${_fmtBytes(task.totalBytes)}',
                style: theme.textTheme.bodySmall),
            const Spacer(),
            if (task.status == TaskStatus.running)
              IconButton(tooltip: '暂停', onPressed: onPause, icon: const Icon(Icons.pause))
            else if (task.status == TaskStatus.paused ||
                task.status == TaskStatus.failed)
              IconButton(tooltip: '继续', onPressed: onResume, icon: const Icon(Icons.play_arrow)),
            // 完成任务给「打开所在文件夹」——用户不知道下到哪是本轮实测反馈
            if (task.status == TaskStatus.completed)
              IconButton(
                  tooltip: '打开所在文件夹',
                  onPressed: onOpenFolder,
                  icon: const Icon(Icons.folder_open)),
            IconButton(tooltip: '删除任务', onPressed: onDelete, icon: const Icon(Icons.delete_outline)),
          ]),
        ]),
      ),
    );
  }
}
