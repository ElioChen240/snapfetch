import 'dart:convert';

import '../../domain/parser.dart';
import 'common.dart';

/// 小红书解析（免登录可取图集/视频直链，部分内容需 Cookie）。
///
/// 流程：链接（含 xhslink 短链）→ 跟随重定向 → /explore/{noteId} 页面 →
/// 抽取 `window.__INITIAL_STATE__` JSON → 图集/视频直链。
class XiaohongshuParser extends LinkParser {
  const XiaohongshuParser();

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36';
  static const _referer = 'https://www.xiaohongshu.com/';

  @override
  String get id => 'xiaohongshu';
  @override
  String get displayName => '小红书';
  @override
  PlatformKind get kind => PlatformKind.video;
  @override
  bool get requiresAuth => false;

  @override
  bool matches(String input) =>
      input.contains('xiaohongshu.com') || input.contains('xhslink.com');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    var url = ParseUtils.firstUrl(input);
    if (url == null) {
      throw const ParseError('未在输入中找到小红书链接', kind: ParseErrorKind.notFound);
    }

    // 1. 跟随短链/口令 → 最终页（带捕获的 Cookie 以提高可得性）
    final page = await ctx.httpGet(url, headers: {
      'User-Agent': _ua,
      'Referer': _referer,
      'Accept': 'text/html,application/xhtml+xml',
    });
    final noteId = _extractNoteId(page.finalUri.toString()) ??
        _extractNoteId(page.body);
    if (noteId == null) {
      throw const ParseError('小红书: 未解析出笔记 ID', kind: ParseErrorKind.notFound);
    }

    // 2. 页面内嵌状态 JSON
    final state = _extractState(page.body);
    if (state == null) {
      throw ParseError('小红书: 页面数据不可用（可能需登录 Cookie 或平台改版）',
          kind: ParseErrorKind.credentialExpired);
    }
    final note = _findNote(state, noteId);
    if (note == null) {
      throw const ParseError('小红书: 未找到笔记数据', kind: ParseErrorKind.notFound);
    }
    return _toMediaSet(note);
  }

  String? _extractNoteId(String s) {
    final m = RegExp(r'(?:explore|discovery/item)/([0-9a-f]{24})').firstMatch(s) ??
        RegExp(r'"noteId"\s*:\s*"([0-9a-f]{24})"').firstMatch(s);
    return m?.group(1);
  }

  /// 抽取 `__INITIAL_STATE__`：注意页面用 JS 对象字面量，含裸 `undefined`，
  /// JSON.parse 前需替换为 null（社区通行做法）。
  Map<String, dynamic>? _extractState(String html) {
    final m = RegExp(r'window\.__INITIAL_STATE__\s*=\s*(\{.*?\})\s*</script>',
            dotAll: true)
        .firstMatch(html);
    if (m == null) return null;
    try {
      final cleaned = m.group(1)!.replaceAll('undefined', 'null');
      return (jsonDecode(cleaned) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _findNote(Map<String, dynamic> state, String noteId) {
    final noteMap = (state['note'] ?? const {}) as Map;
    final detail = (noteMap['noteDetailMap'] ?? noteMap['noteDetailMapV2'] ?? const {})
        as Map;
    final entry = detail[noteId] as Map?;
    final note = entry?['note'] as Map?;
    return note?.cast<String, dynamic>();
  }

  MediaSetResult _toMediaSet(Map<String, dynamic> note) {
    final title = (note['title'] ?? note['displayTitle'] ?? '小红书笔记') as String;
    final author =
        ((note['user'] ?? const {}) as Map)['nickname'] as String?;
    final items = <MediaItem>[];

    // 图集
    final imageList = (note['imageList'] ?? const []) as List;
    for (final raw in imageList) {
      final img = (raw as Map).cast<String, dynamic>();
      String? url;
      final infoList = (img['infoList'] ?? const []) as List;
      // 取最大尺寸的变体
      for (final v in infoList.reversed) {
        final vi = (v as Map).cast<String, dynamic>();
        final u = vi['url'] as String?;
        if (u != null && u.isNotEmpty) {
          url = u;
          break;
        }
      }
      url ??= (img['urlDefault'] ?? img['url'] ?? '') as String;
      if (url.isNotEmpty) {
        items.add(MediaItem(
          url: url,
          kind: MediaKind.image,
          headers: {'Referer': _referer, 'User-Agent': _ua},
        ));
      }
    }

    // 视频
    final video = note['video'] as Map?;
    if (video != null) {
      final media = video['media'] as Map?;
      final stream = media?['stream'] as Map?;
      // h264 优先（兼容性最好）
      for (final kind in ['h264', 'h265', 'av1']) {
        final list = (stream?[kind] ?? const []) as List;
        if (list.isEmpty) continue;
        final first = (list.first as Map).cast<String, dynamic>();
        final master = first['masterUrl'] as String?;
        if (master != null && master.isNotEmpty) {
          items.add(MediaItem(
            url: master,
            kind: MediaKind.video,
            qualityLabel: kind,
            headers: {'Referer': _referer, 'User-Agent': _ua},
          ));
          break;
        }
      }
    }

    if (items.isEmpty) {
      throw const ParseError('小红书: 未取得可下载资源（图集/视频均为空）',
          kind: ParseErrorKind.generic);
    }
    return MediaSetResult(title: title, author: author, items: items);
  }
}
