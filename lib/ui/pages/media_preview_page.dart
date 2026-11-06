
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/parser.dart';
import '../widgets/auth_image.dart';

/// 媒体预览页：图片（可缩放）/ 视频（media_kit 播放）/ 音频。
///
/// ★ 所有请求带 Referer / Cookie —— 否则网盘 / 视频平台直链会 403。
/// ★ 图片用 InteractiveViewer 做缩放（photo_view 未必要，减少依赖面）。
/// ★ 视频用 media_kit（已随包，ffmpeg 版），支持拖进度/音量/全屏。
class MediaPreviewPage extends StatefulWidget {
  final MediaItem item;
  final String title;

  const MediaPreviewPage({super.key, required this.item, required this.title});

  @override
  State<MediaPreviewPage> createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage> {
  Player? _player;
  VideoController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.item.kind == MediaKind.video || widget.item.kind == MediaKind.audio) {
      _initPlayer();
    }
  }

  void _initPlayer() {
    try {
      final player = Player();
      final controller = VideoController(player);
      _player = player;
      _controller = controller;
      // media_kit 的 http 源支持自定义头（Referer/Cookie 防 403）
      player.open(
        Media(widget.item.url, httpHeaders: widget.item.headers),
        play: true,
      );
    } catch (e) {
      setState(() => _error = '播放器初始化失败：$e');
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.item.qualityLabel != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(widget.item.qualityLabel!,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    switch (widget.item.kind) {
      case MediaKind.image:
        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: AuthImage(
              url: widget.item.url,
              headers: widget.item.headers,
              fit: BoxFit.contain,
            ),
          ),
        );

      case MediaKind.video:
        if (_error != null) return _errorView(theme, _error!);
        if (_controller == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Video(
                controller: _controller!,
                controls: AdaptiveVideoControls,
              ),
            ),
          ),
        );

      case MediaKind.audio:
        if (_error != null) return _errorView(theme, _error!);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.audiotrack, size: 72, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(widget.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 24),
              if (_controller != null)
                SizedBox(width: 360, child: Video(controller: _controller!)),
            ],
          ),
        );
    }
  }

  Widget _errorView(ThemeData theme, String msg) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
          ],
        ),
      );
}
