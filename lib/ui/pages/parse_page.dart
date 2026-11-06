import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/bookmarks.dart';
import '../../core/parse_history.dart';
import '../../core/settings.dart';
import '../../domain/parser.dart';
import '../widgets/file_browser.dart';
import '../theme/motion.dart';
import '../widgets/auth_image.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/platform_logo.dart';
import 'media_preview_page.dart';
import '../../providers.dart';

/// 解析状态。
sealed class ParseUiState {
  const ParseUiState();
}

class ParseIdle extends ParseUiState {
  const ParseIdle();
}

class ParseLoading extends ParseUiState {
  final String input;
  const ParseLoading(this.input);
}

class ParseDone extends ParseUiState {
  final LinkParser parser;
  final ParseResult result;
  final Set<String> selected; // 文件 path / 媒体 url

  /// 未登录（游客）解析：网盘大文件可能被平台限制，界面据此提示。
  final bool guest;
  const ParseDone(this.parser, this.result, this.selected, {this.guest = false});
}

class ParseFailed extends ParseUiState {
  final ParseError error;
  final String? platformId;
  const ParseFailed(this.error, [this.platformId]);
}

/// 解析页（M4 主链路入口）：粘贴 → 解析 → 结果 → 加入下载。
class ParsePage extends ConsumerStatefulWidget {
  const ParsePage({super.key});

  @override
  ConsumerState<ParsePage> createState() => _ParsePageState();
}

class _ParsePageState extends ConsumerState<ParsePage> {
  final _input = TextEditingController();
  /// 提取码（可选）：非空时优先于从文案里自动识别的提取码
  final _passcode = TextEditingController();
  ParseUiState _state = const ParseIdle();

  @override
  void initState() {
    super.initState();
    // 命令行带链接启动（右键「打开方式」/ 浏览器调用）：回填并直接解析。
    // startupLinkProvider 默认空串，正常双击启动时行为完全不变。
    final link = ref.read(startupLinkProvider);
    if (link.isNotEmpty) {
      _input.text = link;
      // 等首帧再解析：此时 Provider 与输入控制器都已就绪
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _parse();
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    var input = _input.text.trim();
    if (input.isEmpty) return;
    // 独立提取码输入框优先：把它拼进待解析文本尾部，各解析器沿用同一套识别逻辑
    final manual = _passcode.text.trim();
    if (manual.isNotEmpty && !RegExp(r'提取码|密码|pwd=', caseSensitive: false).hasMatch(input)) {
      input = '$input 提取码: $manual';
    }
    final registry = ref.read(registryProvider);
    final url = _firstUrl(input) ?? input;
    final parser = registry.route(url);
    if (parser == null) {
      setState(() => _state = const ParseFailed(
          ParseError('未能识别链接所属平台（支持：夸克 / UC / 123 云盘 / 抖音 / 小红书）')));
      return;
    }
    setState(() => _state = ParseLoading(input));
    try {
      final ctxFactory = ref.read(parseContextFactoryProvider);
      final ctx = await ctxFactory(parser.id);
      final result = await parser.parse(input, ctx);
      final sel = <String>{};
      _walkFiles(result, (node) {
        if (!node.isDirectory) sel.add(node.path);
      });
      if (result is MediaSetResult) {
        for (final m in result.items) {
          sel.add(m.url);
        }
      }
      if (!mounted) return;
      setState(() => _state =
          ParseDone(parser, result, sel, guest: !ctx.hasCredential));
      _recordHistory(
        url: input,
        parser: parser,
        ok: true,
        summary: _summaryOf(result),
      );
    } on ParseError catch (e) {
      if (!mounted) return;
      setState(() => _state = ParseFailed(e, parser.id));
      _recordHistory(url: input, parser: parser, ok: false, summary: e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _state = ParseFailed(ParseError('解析失败: $e'), parser.id));
      _recordHistory(url: input, parser: parser, ok: false, summary: '$e');
    }
  }

  /// 记一条解析历史（失败也记，方便回看「刚才那个链接为什么不行」）。
  Future<void> _recordHistory({
    required String url,
    required LinkParser parser,
    required bool ok,
    required String summary,
  }) async {
    try {
      final registry = ref.read(registryProvider);
      final repo = await ref.read(historyRepoProvider.future);
      await repo.record(ParseHistoryEntry(
        id: const Uuid().v4(),
        url: url,
        passcode: _passcode.text.trim(),
        platformId: parser.id,
        platformName: registry.route(_firstUrl(url) ?? url)?.displayName ?? '',
        summary: summary,
        ok: ok,
        at: DateTime.now(),
      ));
      if (mounted) ref.read(historyTickProvider.notifier).state++;
    } catch (e) {
      debugPrint('[history] 记录失败（不影响使用）: $e');
    }
  }

  /// 结果概要：'3 个文件 · 1.2 GB' / '6 张图片 · 2 个视频'
  String _summaryOf(ParseResult r) {
    if (r is MediaSetResult) {
      final img = r.items.where((m) => m.kind == MediaKind.image).length;
      final vid = r.items.where((m) => m.kind == MediaKind.video).length;
      final aud = r.items.where((m) => m.kind == MediaKind.audio).length;
      return [
        if (img > 0) '$img 张图片',
        if (vid > 0) '$vid 个视频',
        if (aud > 0) '$aud 个音频',
      ].join(' · ');
    }
    if (r is FileTreeResult) {
      var n = 0;
      var bytes = 0;
      _walkFiles(r, (node) {
        if (node.isDirectory) return;
        n++;
        bytes += node.size ?? 0;
      });
      return bytes > 0 ? '$n 个文件 · $_humanBytes(bytes)' : '$n 个文件';
    }
    return '';
  }

  static String _humanBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  String? _firstUrl(String input) {
    final m = RegExp(r'https?://[^\s，。,；;）)】\]]+').firstMatch(input);
    return m?.group(0);
  }

  void _walkFiles(ParseResult r, void Function(FileNode) fn) {
    if (r is FileTreeResult) {
      void walk(List<FileNode> nodes) {
        for (final n in nodes) {
          fn(n);
          if (n.children != null) walk(n.children!);
        }
      }
      walk(r.roots);
    }
  }

  Future<void> _downloadSelected() async {
    final s = _state;
    if (s is! ParseDone) return;
    final engine = await ref.read(downloadEngineProvider.future);
    final settings = await ref.read(settingsProvider.future);
    final ctxFactory = ref.read(parseContextFactoryProvider);
    final ctx = await ctxFactory(s.parser.id);
    if (!mounted) return; // await 之后不再使用 context，先取 messenger 前 guard
    final messenger = ScaffoldMessenger.of(context);
    var queued = 0;
    final errors = <String>[];

    if (s.result is FileTreeResult) {
      // 网盘：对勾选文件逐个换直链
      final files = <FileNode>[];
      _walkFiles(s.result, (n) {
        if (!n.isDirectory && s.selected.contains(n.path)) files.add(n);
      });
      for (final node in files) {
        try {
          final url = await s.parser.resolveDirectUrl(ctx, node);
          // ★ 必须带 downloadHeaders（Cookie + Referer），否则 CDN 返回错误页
          await _enqueue(engine, settings, url, node.name, ctx.downloadHeaders);
          queued++;
        } catch (e) {
          // ★ 必须给出原因（否则只看到「失败 N 个」，无从判断是 Cookie 还是接口问题）
          errors.add('${node.name}: ${e is ParseError ? e.message : e}');
        }
      }
    } else if (s.result is MediaSetResult) {
      final media = s.result as MediaSetResult;
      for (final item in media.items) {
        if (!s.selected.contains(item.url)) continue;
        final name = _mediaName(media.title, item, s.selected);
        try {
          await _enqueue(engine, settings, item.url, name, item.headers);
          queued++;
        } catch (e) {
          errors.add('$name: ${e is ParseError ? e.message : e}');
        }
      }
    }

    final usedDir = _actualDirUsed;
    _actualDirUsed = null;
    messenger.showSnackBar(SnackBar(
      content: Text(errors.isEmpty
          ? '已加入下载 $queued 个\n保存位置：$usedDir'
          : '已加入下载 $queued 个，失败 ${errors.length} 个\n${errors.take(2).join('\n')}'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: '去下载页',
        onPressed: () => ref.read(navIndexProvider.notifier).state = 1,
      ),
    ));
  }

  /// 从剪贴板读取并填入输入框（Flutter 自带 Clipboard，无需平台层）。
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      }
      return;
    }
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  String? _actualDirUsed;

  Future<void> _enqueue(DownloadEngine engine, AppSettings settings, String url,
      String name, Map<String, String> headers) async {
    // ★ 严格使用用户设置的目录，绝不静默改存到别处（用户实测反馈）。
    //   可写性由引擎实际写文件时校验，失败会报具体错误。
    final dir = settings.effectiveDownloadDir;
    try {
      await Directory(dir).create(recursive: true);
    } catch (e) {
      throw ParseError('无法创建下载目录「$dir」：$e');
    }
    _actualDirUsed = dir;

    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await engine.enqueue(DownloadTask(
      id: const Uuid().v4(),
      url: url,
      savePath: '$dir${Platform.pathSeparator}$safe',
      headers: headers,
      totalBytes: 0, // 引擎 HEAD 探测
      chunks: const [],
    ));
  }


  /// 收藏当前输入（链接 + 提取码 + 平台名）。
  Future<void> _addBookmark() async {
    final url = _input.text.trim();
    if (url.isEmpty) return;
    final registry = ref.read(registryProvider);
    final parser = registry.route(_firstUrl(url) ?? url);
    final repo = await ref.read(bookmarkRepoProvider.future);
    await repo.add(Bookmark(
      id: const Uuid().v4(),
      url: url,
      passcode: _passcode.text.trim(),
      platformName: parser?.displayName ?? '',
      createdAt: DateTime.now(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已收藏${parser == null ? '' : '（${parser.displayName}）'}')),
    );
  }

  /// 收藏夹：点击条目回填输入框，或删除。
  Future<void> _showBookmarks() async {
    final repo = await ref.read(bookmarkRepoProvider.future);
    if (!mounted) return;
    final list = await repo.all();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('收藏夹'),
          content: SizedBox(
            width: 520,
            child: list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有收藏的链接'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final b = list[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.bookmark_outline, size: 18),
                        title: Text(b.url,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (b.platformName.isNotEmpty) b.platformName,
                            if (b.passcode.isNotEmpty) '提取码 ${b.passcode}',
                          ].join(' · '),
                        ),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await repo.remove(b.id);
                            final next = await repo.all();
                            setLocal(() {
                              list
                                ..clear()
                                ..addAll(next);
                            });
                          },
                        ),
                        onTap: () {
                          _input.text = b.url;
                          _passcode.text = b.passcode;
                          Navigator.pop(ctx);
                          _parse();
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  /// 解析历史：自动记录的解析记录，点击回填并重新解析。
  Future<void> _showHistory() async {
    final repo = await ref.read(historyRepoProvider.future);
    if (!mounted) return;
    var list = await repo.all();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('解析历史'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: list.isEmpty
                ? const Center(child: Text('还没有解析记录'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final h = list[i];
                      return ListTile(
                        dense: true,
                        leading: h.platformId.isEmpty
                            ? const Icon(Icons.history, size: 18)
                            : PlatformLogo(platformId: h.platformId, size: 28),
                        title: Text(h.url,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            _relTime(h.at),
                            if (h.passcode.isNotEmpty) '提取码 ${h.passcode}',
                            if (h.summary.isNotEmpty) h.summary,
                          ].join(' · '),
                          style: TextStyle(
                            color: h.ok
                                ? null
                                : Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: '删除此条',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await repo.remove(h.id);
                            final next = await repo.all();
                            setLocal(() => list = next);
                            ref.read(historyTickProvider.notifier).state++;
                          },
                        ),
                        onTap: () {
                          _input.text = h.url;
                          _passcode.text = h.passcode;
                          Navigator.pop(ctx);
                          _parse();
                        },
                      );
                    },
                  ),
          ),
          actions: [
            if (list.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await repo.clear();
                  setLocal(() => list = []);
                  ref.read(historyTickProvider.notifier).state++;
                },
                child: const Text('清空'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  /// 相对时间：刚刚 / 5 分钟前 / 3 小时前 / 昨天 / 2026-11-01
  static String _relTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天';
    if (d.inDays < 7) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  String _mediaName(String title, MediaItem item, Set<String> all) {    final ext = item.kind == MediaKind.video
        ? '.mp4'
        : item.kind == MediaKind.audio
            ? '.mp3'
            : '.jpg';
    final base = title.trim().isEmpty ? 'media' : title.trim();
    final dup = all.toList().indexOf(item.url);
    final suffix = dup > 0 ? '_$dup' : '';
    return '$base$suffix$ext';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageScaffold(
      title: '解析',
      subtitle: null,      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 表单区限宽：桌面端输入框拉满整个屏幕会很难看
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              // ★ 必须 min：内层 Column 作为父 Column 的非弹性子项时，
              //   默认 max 会请求无限高度 → RenderFlex overflow（实测 99542px）
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 3,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: '例子：https://pan.quark.cn/s/xxxx（整段分享文案也可以）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    prefixIcon: const Icon(Icons.link, size: 18),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste, size: 18),
                      tooltip: '从剪贴板粘贴',
                      onPressed: _pasteFromClipboard,
                    ),
                  ),
                  onSubmitted: (_) => _parse(),
                ),
                const SizedBox(height: 8),
                // 提取码（可选）：链接里没带 / 自动识别失败时手动补
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _passcode,
                    maxLength: 4,
                    style: theme.textTheme.bodyMedium,
                    decoration: const InputDecoration(
                      hintText: '提取码（可选）',
                      border: OutlineInputBorder(),
                      isDense: true,
                      counterText: '',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      prefixIcon: Icon(Icons.password, size: 18),
                    ),
                    onSubmitted: (_) => _parse(),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    // 组 3：loading 用 M3 内置进度指示器（无自定义脉冲/呼吸）
                    FilledButton.icon(
                      onPressed: _state is ParseLoading ? null : _parse,
                      icon: _state is ParseLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt, size: 18),
                      label: Text(_state is ParseLoading ? '解析中' : '解析'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        _input.clear();
                        _passcode.clear();
                        setState(() => _state = const ParseIdle());
                      },
                      child: const Text('清空'),
                    ),
                    const Spacer(),
                    // 收藏当前链接（对应手机版右上角书签）
                    // 用 ListenableBuilder 跟随输入实时启用/禁用
                    ListenableBuilder(
                      listenable: _input,
                      builder: (context, _) => IconButton(
                        tooltip: '收藏此链接',
                        icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                        onPressed:
                            _input.text.trim().isEmpty ? null : _addBookmark,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _showBookmarks,
                      icon: const Icon(Icons.bookmarks_outlined, size: 18),
                      label: const Text('收藏夹'),
                    ),
                    const SizedBox(width: 4),
                    // 解析历史：自动记录，点击可复用（按钮上带条数）
                    _HistoryButton(onTap: _showHistory),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // 组 3：解析状态切换用 M3 fade-through（无缩放/弹性）
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.d(Motion.medium),
              switchInCurve: Motion.emphasized,
              switchOutCurve: Motion.accelerate,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Motion.decelerate,
                  reverseCurve: Motion.accelerate,
                ),
                child: child,
              ),
              child: KeyedSubtree(
                key: ValueKey(_state.runtimeType),
                child: _buildBody(theme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final s = _state;
    switch (s) {
      case ParseIdle():
        return const EmptyState(
          icon: Icons.link,
          title: '粘贴分享链接，直接高速下载',
          description: '支持夸克 / UC / 123 云盘，以及抖音 / 小红书 · 自动识别提取码',
        );
      case ParseLoading():
        return const Center(child: CircularProgressIndicator());
      case ParseFailed f:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(f.error.message, textAlign: TextAlign.center),
              if (f.error.kind == ParseErrorKind.credentialExpired && f.platformId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.tonal(
                    onPressed: () =>
                        ref.read(navIndexProvider.notifier).state = 2,
                    child: const Text('去账号页重新登录'),
                  ),
                ),
            ],
          ),
        );
      case ParseDone d:
        return _ResultView(
          state: d,
          onToggle: (key) => setState(() {
            if (d.selected.contains(key)) {
              d.selected.remove(key);
            } else {
              d.selected.add(key);
            }
          }),
          onSelectAll: (all) => setState(() {
            d.selected
              ..clear()
              ..addAll(all);
          }),
          onSelectMany: (keys, select) => setState(() {
            if (select) {
              d.selected.addAll(keys);
            } else {
              d.selected.removeAll(keys);
            }
          }),
          onDownload: _downloadSelected,
        );
    }
  }
}

class _ResultView extends StatelessWidget {  final ParseDone state;
  final ValueChanged<String> onToggle;
  final ValueChanged<List<String>> onSelectAll;
  final void Function(List<String> keys, bool select) onSelectMany;
  final VoidCallback onDownload;

  const _ResultView({
    required this.state,
    required this.onToggle,
    required this.onSelectAll,
    required this.onSelectMany,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = state.result;

    // 汇总所有可选 key
    final allKeys = <String>[];
    if (result is FileTreeResult) {
      void walk(List<FileNode> nodes) {
        for (final n in nodes) {
          if (!n.isDirectory) allKeys.add(n.path);
          if (n.children != null) walk(n.children!);
        }
      }
      walk(result.roots);
    } else if (result is MediaSetResult) {
      for (final m in result.items) {
        allKeys.add(m.url);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 未登录（游客）提示：小文件可直接下，大文件受平台限制
        if (state.guest && state.parser.kind == PlatformKind.netdisk)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: theme.colorScheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '未登录解析：约 50MB 以内的小文件通常可直接下载（平台限制，以实际为准）；'
                    '大文件取不到直链时，请到账号页登录后再解析。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
          ),
        // 紧凑操作条（桌面端不用大 Chip，节省纵向空间）
        Row(
          children: [
            // 平台徽标（品牌色块 + 首字，非官方 logo）
            PlatformLogo(platformId: state.parser.id, size: 22),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(state.parser.displayName,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
            const SizedBox(width: 10),
            Text('${state.selected.length} / ${allKeys.length} 已选',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const Spacer(),
            TextButton(
              onPressed: () => onSelectAll(
                  state.selected.length == allKeys.length ? const [] : allKeys),
              child: Text(state.selected.length == allKeys.length ? '全不选' : '全选'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: state.selected.isEmpty ? null : onDownload,
              icon: const Icon(Icons.download, size: 18),
              label: Text('下载所选 (${state.selected.length})'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Divider(height: 1),
        Expanded(
          child: result is FileTreeResult
              ? FileBrowser(
                  // 重新解析时重置浏览位置
                  key: ValueKey(state.result),
                  roots: result.roots,
                  selected: state.selected,
                  onToggle: onToggle,
                  onSelectMany: onSelectMany,
                )
              : _MediaGrid(
                  media: result as MediaSetResult,
                  selected: state.selected,
                  onToggle: onToggle,
                ),
        ),
      ],
    );
  }
}

class _MediaGrid extends StatelessWidget {
  final MediaSetResult media;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  const _MediaGrid({
    required this.media,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: media.items.length,
      itemBuilder: (_, i) {
        final item = media.items[i];
        final key = item.url;
        final sel = selected.contains(key);
        final isImage = item.kind == MediaKind.image;
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // 点缩略图 → 预览；勾选用左上角复选框（避免和预览冲突）
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MediaPreviewPage(
                  item: item,
                  title: media.title.isEmpty ? '预览' : media.title,
                ),
              ),
            ),
            child: Column(children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  // ★ 真实缩略图（带 Referer/Cookie，否则 403）
                  if (isImage)
                    AuthImage(url: item.url, headers: item.headers, fit: BoxFit.cover)
                  else
                    Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Icon(Icons.play_circle_outline,
                          size: 40, color: theme.colorScheme.primary),
                    ),
                  // ★ 选中态：只做轻着色 + 右上角小勾。
                  //   以前在正中间画一个大对勾，会把视频卡片底下的「播放」图标
                  //   整个盖掉 —— 默认全选时满屏都是对勾，看不出点卡片能在线播。
                  if (sel)
                    Container(
                      color: theme.colorScheme.primary.withValues(alpha: 0.18),
                    ),
                  if (sel)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.check_circle,
                            size: 20, color: theme.colorScheme.onPrimary),
                      ),
                    ),
                  // 左上角勾选（独立于预览点击）
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Material(
                      color: Colors.transparent,
                      child: Checkbox(
                        value: sel,
                        onChanged: (_) => onToggle(key),
                        fillColor: WidgetStatePropertyAll(
                          sel ? theme.colorScheme.primary : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  item.qualityLabel ??
                      (isImage ? '图片' : '视频'),
                  style: theme.textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// 「历史」按钮：显示记录条数（跟随 historyCountProvider）。
class _HistoryButton extends ConsumerWidget {
  final VoidCallback onTap;

  const _HistoryButton({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final n = ref.watch(historyCountProvider).value ?? 0;
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.history, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('历史'),
          if (n > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$n',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
            ),
          ],
        ],
      ),
    );
  }
}
