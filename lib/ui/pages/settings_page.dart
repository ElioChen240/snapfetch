import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../providers.dart';
import '../widgets/page_scaffold.dart';

/// 设置页（PRD §4.1 第 12 项）：主题、并发数、下载目录、免转存、关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settingsAsync = ref.watch(settingsProvider);

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('设置加载失败: $e')),
      data: (settings) => PageScaffold(
        title: '设置',
        maxContentWidth: 900,
        child: ListView(
        children: [
          // 主题
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('主题模式'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) async {
                await settings.setThemeMode(s.first);
                ref.invalidate(settingsProvider);
              },
            ),
          ),
          const Divider(),

          // 并发数
          ListTile(
            leading: const Icon(Icons.call_split),
            title: const Text('下载分片并发数'),
            subtitle: Slider(
              value: settings.concurrency.toDouble(),
              min: 1,
              max: 32,
              divisions: 31,
              label: '${settings.concurrency}',
              onChanged: (v) async {
                await settings.setConcurrency(v.round());
                if (mounted) setState(() {});
              },
            ),
            trailing: Text('${settings.concurrency}'),
          ),
          const Divider(),

          // 下载目录
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('下载目录'),
            subtitle: Text(
              settings.effectiveDownloadDir,
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _openDir(settings.effectiveDownloadDir),
                  child: const Text('打开'),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: () => _editDir(settings.downloadDir),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('选择文件夹'),
                ),
                // 始终显示「恢复默认」：已是默认时禁用并标注，避免用户找不到
                const SizedBox(width: 4),
                TextButton(
                  onPressed: settings.downloadDir.isEmpty
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await settings.setDownloadDir('');
                          ref.invalidate(settingsProvider);
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('已恢复默认下载目录（程序目录\\downloads）'),
                            ),
                          );
                        },
                  child: Text(settings.downloadDir.isEmpty ? '已是默认' : '恢复默认'),
                ),
              ],
            ),
          ),
          const Divider(),
          // 免转存下载（对齐手机版夸克设置项）
          SwitchListTile(
            secondary: const Icon(Icons.save_alt_outlined),
            title: const Text('免转存下载'),
            subtitle: const Text('夸克：解析出直链后直接下载，不把文件转存到自己的网盘\n'
                '关闭后改为「先转存到我的网盘根目录，再下载」（需已登录）'),
            value: settings.noTransferDownload,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              await settings.setNoTransferDownload(v);
              if (!mounted) return;
              setState(() {});
              messenger.showSnackBar(SnackBar(
                content: Text(v
                    ? '已开启免转存：解析到直链直接下载'
                    : '已关闭免转存：下载前先转存到你的网盘'),
              ));
            },
          ),
          const Divider(),
          // 关于：一行入口 + 对话框，不占页面空间、不堆文字
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            subtitle: Text('${AppInfo.displayVersion} · ${AppInfo.tagline}'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showAbout(context),
          ),
        ],
        ),
      ),
    );
  }

  /// 关于对话框：只保留必要信息（版本 / 协议 / 项目地址）。
  void _showAbout(BuildContext context) {
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Image.asset('assets/icons/snapfetch_compact_48.png', width: 40, height: 40),
        title: const Text('${AppInfo.nameZh} ${AppInfo.nameEn}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 ${AppInfo.version}', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              '${AppInfo.tagline}\n${AppInfo.licenseLine}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                  const ClipboardData(text: AppInfo.repoUrl));
              if (ctx.mounted) Navigator.pop(ctx);
              messenger.showSnackBar(
                  const SnackBar(content: Text('项目地址已复制')));
            },
            icon: const Icon(Icons.link, size: 16),
            label: const Text('复制项目地址'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 在资源管理器中打开当前生效的下载目录。
  Future<void> _openDir(String dir) async {
    if (!Platform.isWindows) return;
    try {
      final d = Directory(dir);
      await d.create(recursive: true);
      await Process.run('explorer.exe', [d.path]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('打开目录失败：$e')));
      }
    }
  }

  /// 调系统文件夹选择对话框（Windows IFileDialog）。
  Future<void> _editDir(String current) async {
    String? picked;
    try {
      picked = await getDirectoryPath(
        initialDirectory: current.isEmpty ? null : current,
        confirmButtonText: '选择此文件夹',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('打开文件夹选择器失败：$e')));
      }
      return;
    }
    if (picked == null) return; // 用户取消

    if (!await Directory(picked).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('所选目录不存在，未保存')));
      }
      return;
    }
    final settings = ref.read(settingsProvider).value;
    if (settings == null) return;
    await settings.setDownloadDir(picked);

    if (!mounted) return;
    if (settings.saveFailed) {
      // ★ 不要 invalidate：重建会从磁盘重新加载，把刚改的值覆盖回旧值
      //   （这正是用户看到「改了没用」的原因）。保持内存态并明确告知。
      setState(() {}); // 刷新界面显示新目录
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('下载目录已生效（本次运行）：$picked\n'
            '但无法写入磁盘，重启后会丢失 —— 请允许本程序访问数据目录'),
        duration: const Duration(seconds: 6),
      ));
    } else {
      ref.invalidate(settingsProvider);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('下载目录已设为：$picked')));
    }
  }
}
