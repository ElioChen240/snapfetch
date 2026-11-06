import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/settings.dart';
import '../../domain/parser.dart';
import '../../providers.dart';
import '../widgets/file_browser.dart';
import '../widgets/page_scaffold.dart';

/// 账号云盘浏览页（对齐官方「网盘」页：登录后点击账号 → 浏览自己账号里的文件）。
///
/// - 进入目录时才请求子项（懒加载，`listMyFiles(parentId)`）
/// - 选中后「下载所选」→ `getMyFileDownloadUrl` 换直链 → 引擎下载
/// - 顶部显示昵称与容量（拿不到就不显示）
class CloudDrivePage extends ConsumerStatefulWidget {
  final String platformId;
  final String platformName;
  final String accountLabel;

  const CloudDrivePage({
    super.key,
    required this.platformId,
    required this.platformName,
    required this.accountLabel,
  });

  @override
  ConsumerState<CloudDrivePage> createState() => _CloudDrivePageState();
}

class _CloudDrivePageState extends ConsumerState<CloudDrivePage> {
  CloudBrowser? _browser;
  ParseContext? _ctx;
  List<FileNode> _roots = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;
  String? _nickname;
  String? _quotaText;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final registry = ref.read(registryProvider);
      final parser = registry.all
          .where((p) => p.id == widget.platformId)
          .firstOrNull;
      if (parser is! CloudBrowser) {
        setState(() {
          _loading = false;
          _error = '${widget.platformName} 暂不支持浏览账号文件';
        });
        return;
      }
      // 显式收窄类型：await 之后类型提升不可靠
      final CloudBrowser browser = parser as CloudBrowser;

      final ctxFactory = ref.read(parseContextFactoryProvider);
      final ctx = await ctxFactory(widget.platformId);
      final roots = await browser.listMyFiles(ctx);

      // 昵称/容量是锦上添花，失败不影响浏览
      final nick = await browser.fetchNickname(ctx);
      final quota = await browser.fetchQuota(ctx);

      if (!mounted) return;
      setState(() {
        _browser = browser;
        _ctx = ctx;
        _roots = roots;
        _nickname = nick;
        _quotaText = quota == null
            ? null
            : '${formatBytes(quota.used)} / ${formatBytes(quota.total)}';
        // 默认全选根目录文件（与分享解析一致）
        _selected
          ..clear()
          ..addAll(roots.where((n) => !n.isDirectory).map((n) => n.path));
        _loading = false;
      });
    } on ParseError catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载失败：$e';
        });
      }
    }
  }

  Future<List<FileNode>> _loadChildren(FileNode dir) async {
    final browser = _browser;
    final ctx = _ctx;
    if (browser == null || ctx == null) return const [];
    return browser.listMyFiles(ctx, parentId: dir.path);
  }

  Future<void> _downloadSelected() async {
    final browser = _browser;
    final ctx = _ctx;
    if (browser == null || ctx == null || _selected.isEmpty) return;

    final engine = await ref.read(downloadEngineProvider.future);
    final settings = await ref.read(settingsProvider.future);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    // 收集选中项（可能分布在已加载的各层：这里只处理当前已知节点）
    final files = <FileNode>[];
    void walk(List<FileNode> nodes) {
      for (final n in nodes) {
        if (n.isDirectory) {
          if (n.children != null) walk(n.children!);
        } else if (_selected.contains(n.path)) {
          files.add(n);
        }
      }
    }

    walk(_roots);

    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      try {
        final url = await browser.getMyFileDownloadUrl(ctx, f);
        // ★ 必须带 downloadHeaders（Cookie + Referer），否则 CDN 返回错误页
        await _enqueue(engine, settings, url, f.name, ctx.downloadHeaders);
        ok++;
      } catch (e) {
        errors.add('${f.name}: ${e is ParseError ? e.message : e}');
      }
    }
    // ★ 失败必须给出原因（否则只看到「失败 1 个」，无法判断是 Cookie 失效还是接口结构变了）
    messenger.showSnackBar(SnackBar(
      content: Text(errors.isEmpty
          ? '已加入下载 $ok 个\n保存位置：${settings.effectiveDownloadDir}'
          : '已加入下载 $ok 个，失败 ${errors.length} 个\n${errors.take(2).join('\n')}'),
      duration: const Duration(seconds: 10),
    ));
  }

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
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await engine.enqueue(DownloadTask(
      id: const Uuid().v4(),
      url: url,
      savePath: '$dir${Platform.pathSeparator}$safe',
      headers: headers, // Cookie + Referer：缺了 CDN 会返回错误页
      totalBytes: 0,
      chunks: const [],
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 用全局骨架替代独立 AppBar：与其它页保持同一标题区节奏
    return Scaffold(
      body: PageScaffold(
        title: widget.platformName,
        subtitle: [
          ?_nickname,
          ?_quotaText,
          widget.accountLabel,
        ].where((e) => e.isNotEmpty).join(' · '),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回账号列表',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _selected.isEmpty ? null : _downloadSelected,
            icon: const Icon(Icons.download, size: 18),
            label: Text('下载所选 (${_selected.length})'),
          ),
          const SizedBox(width: 8),
        ],
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(
                    icon: Icons.error_outline,
                    title: '加载失败',
                    description: _error,
                    action: FilledButton.tonal(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _error = null;
                        });
                        _init();
                      },
                      child: const Text('重试'),
                    ),
                  )
                : FileBrowser(
                    roots: _roots,
                    selected: _selected,
                    onToggle: (key) => setState(() {
                      if (_selected.contains(key)) {
                        _selected.remove(key);
                      } else {
                        _selected.add(key);
                      }
                    }),
                    onSelectMany: (keys, select) => setState(() {
                      if (select) {
                        _selected.addAll(keys);
                      } else {
                        _selected.removeAll(keys);
                      }
                    }),
                    loadChildren: _loadChildren,
                    emptyHint: '这个文件夹是空的',
                  ),
      ),
    );
  }
}
