import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// 带鉴权头的网络图片。
///
/// ★ 网盘 / 视频平台的图片直链要求带 Referer / Cookie，Flutter 自带
///   `Image.network` 无法设置请求头（会被 403），所以统一用 dio 拉字节再渲染。
/// ★ 内存 LRU 缓存（24 张），避免滚动时反复请求；失败显示占位图标。
class AuthImage extends StatefulWidget {
  final String url;
  final Map<String, String> headers;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const AuthImage({
    super.key,
    required this.url,
    this.headers = const {},
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
  });

  @override
  State<AuthImage> createState() => _AuthImageState();
}

class _AuthImageState extends State<AuthImage> {
  static final Map<String, Uint8List> _cache = {};
  static const int _maxCache = 24;
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
    validateStatus: (c) => c != null && c < 500,
  ));

  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _bytes = _cache[widget.url];
    if (_bytes == null) _load();
  }

  @override
  void didUpdateWidget(AuthImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = _cache[widget.url];
      _failed = false;
      if (_bytes == null) _load();
    }
  }

  Future<void> _load() async {
    try {
      final resp = await _dio.getUri<List<int>>(
        Uri.parse(widget.url),
        options: Options(headers: widget.headers),
      );
      final data = resp.data;
      if (data == null || data.isEmpty) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      final bytes = Uint8List.fromList(data);
      if (_cache.length >= _maxCache) _cache.remove(_cache.keys.first);
      _cache[widget.url] = bytes;
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget child;
    if (_bytes != null) {
      child = Image.memory(
        _bytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(theme, Icons.broken_image_outlined),
      );
    } else if (_failed) {
      child = _placeholder(theme, Icons.image_not_supported_outlined);
    } else {
      // 加载中：极简占位（不转圈，避免网格里一堆 spinner）
      child = Container(
        width: widget.width,
        height: widget.height,
        color: theme.colorScheme.surfaceContainerHighest,
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }

  Widget _placeholder(ThemeData theme, IconData icon) => Container(
        width: widget.width,
        height: widget.height,
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(icon, size: 24, color: theme.colorScheme.outline),
      );
}
