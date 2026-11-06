import 'package:flutter/material.dart';

import '../../domain/parser.dart';
import '../theme/motion.dart';


/// 进入式文件浏览（对齐官方手机版行为，PRD §4.1）。
///
/// ★ 一次只显示**当前目录的直接子项**：点文件夹进入下一层，
///   顶部面包屑可跳回任意上级，「返回上一级」回退。
///   此前把整棵树一次性平铺展开（145 个文件），既不像官方也不便浏览。
/// ★ 选中状态跨目录保持（selected 由上层持有），可在多个目录分别勾选后统一下载。
class FileBrowser extends StatefulWidget {
  final List<FileNode> roots;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final void Function(List<String> keys, bool select) onSelectMany;

  /// 懒加载：进入目录时才请求子项（云盘浏览用）。
  /// 为空表示树已完整（分享解析）。
  final Future<List<FileNode>> Function(FileNode dir)? loadChildren;

  /// 空目录提示文案（云盘/分享略有差异）
  final String emptyHint;

  const FileBrowser({
    super.key,
    required this.roots,
    required this.selected,
    required this.onToggle,
    required this.onSelectMany,
    this.loadChildren,
    this.emptyHint = '此文件夹为空',
  });

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  /// 路径栈：每层是「该层要显示的子项」
  final List<List<FileNode>> _stack = [];
  final List<String> _names = [];
  bool _loading = false;
  String? _error;

  List<FileNode> get _children => _stack.isEmpty ? widget.roots : _stack.last;

  Future<void> _enter(FileNode dir) async {
    var kids = dir.children;

    // 懒加载：目录还没展开过 → 请求
    if ((kids == null || kids.isEmpty) && widget.loadChildren != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        kids = await widget.loadChildren!(dir);
        dir.children = kids; // 缓存，返回再进不重复请求
      } catch (e) {
        setState(() {
          _loading = false;
          _error = '打开文件夹失败：$e';
        });
        return;
      }
      setState(() => _loading = false);
    }

    if (kids == null || kids.isEmpty) {
      setState(() => _error = '此文件夹为空');
      return;
    }
    setState(() {
      _stack.add(kids!);
      _names.add(dir.name);
    });
  }

  void _back() {
    if (_stack.isEmpty) return;
    setState(() {
      _stack.removeLast();
      _names.removeLast();
    });
  }

  void _goTo(int depth) {
    // depth = -1 表示根
    setState(() {
      _stack.removeRange(depth + 1, _stack.length);
      _names.removeRange(depth + 1, _names.length);
    });
  }

  /// 某节点下（含自身）所有文件 path
  static List<String> _filesUnder(FileNode node) {
    final out = <String>[];
    void walk(FileNode n) {
      if (n.isDirectory) {
        for (final c in n.children ?? const <FileNode>[]) {
          walk(c);
        }
      } else {
        out.add(n.path);
      }
    }

    walk(node);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 文件夹在前，其余保持网盘原始顺序
    final all = _children;
    final children = <FileNode>[
      ...all.where((n) => n.isDirectory),
      ...all.where((n) => !n.isDirectory),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 面包屑 + 返回上一级
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              if (_stack.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  tooltip: '返回上一级',
                  onPressed: _back,
                  visualDensity: VisualDensity.compact,
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      InkWell(
                        onTap: _stack.isEmpty ? null : () => _goTo(-1),
                        child: Text('全部',
                            style: _crumbStyle(theme, _stack.isEmpty)),
                      ),
                      for (var i = 0; i < _names.length; i++) ...[
                        Icon(Icons.chevron_right,
                            size: 14, color: theme.colorScheme.outline),
                        InkWell(
                          onTap: i == _names.length - 1 ? null : () => _goTo(i),
                          child: Text(_names[i],
                              style:
                                  _crumbStyle(theme, i == _names.length - 1)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Text('${all.length} 项',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(_error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        // 组 4：进/出目录时列表做 M3 fade + 轻位移（无横向滑屏、无弹性）
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.d(Motion.short),
            switchInCurve: Motion.decelerate,
            switchOutCurve: Motion.accelerate,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: CurvedAnimation(parent: animation, curve: Motion.decelerate),
              child: SlideTransition(
                position: animation.drive(
                  Tween<Offset>(
                    begin: const Offset(0.02, 0),
                    end: Offset.zero,
                  ).chain(CurveTween(curve: Motion.decelerate)),
                ),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(_names.join('/') + (_loading ? '#l' : '')),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : children.isEmpty
                      ? Center(child: Text(widget.emptyHint))
                      : ListView.builder(
                          itemCount: children.length,
                          itemExtent: 46,
                          itemBuilder: (_, i) => _row(children[i], theme),
                        ),
            ),
          ),
        ),
      ],
    );
  }

  TextStyle? _crumbStyle(ThemeData t, bool current) =>
      t.textTheme.bodySmall?.copyWith(
        color: current ? t.colorScheme.onSurface : t.colorScheme.primary,
        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
      );

  Widget _row(FileNode node, ThemeData theme) {
    if (node.isDirectory) {
      final kids = node.children ?? const <FileNode>[];
      final files = _filesUnder(node);
      final allSel = files.isNotEmpty && files.every(widget.selected.contains);
      final someSel = files.any(widget.selected.contains);
      return _HoverRow(
        onTap: () => _enter(node),
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(
            children: [
              // 勾选框：整目录选择（不影响进入）
              SizedBox(
                width: 40,
                child: Checkbox(
                  value: allSel ? true : (someSel ? null : false),
                  tristate: true,
                  onChanged: files.isEmpty
                      ? null
                      : (_) => widget.onSelectMany(files, !allSel),
                ),
              ),
              Icon(Icons.folder_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(node.name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
              ),
              Text('${kids.length} 项',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 18, color: theme.colorScheme.outline),
            ],
          ),
        ),
      );
    }
    return _HoverRow(
      onTap: () => widget.onToggle(node.path),
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Checkbox(
                value: widget.selected.contains(node.path),
                onChanged: (_) => widget.onToggle(node.path),
              ),
            ),
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(node.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium),
            ),
            Text(formatBytes(node.size),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}


/// 桌面端列表行：hover 高亮 + 圆角水波（M3 规范，无自定义颜色）。
///
/// ★ ListView 的 itemExtent=46 会裁剪 InkWell 水波，且无 Material 祖先时
///   hover 不生效 —— 这里显式提供 Material + InkWell。
class _HoverRow extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;

  const _HoverRow({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: child,
        ),
      ),
    );
  }
}

/// 字节数 → 可读大小。
String formatBytes(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
}
