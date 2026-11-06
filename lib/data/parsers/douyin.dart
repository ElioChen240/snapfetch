import 'dart:convert';

import '../../domain/parser.dart';
import 'common.dart';

/// 抖音解析（免登录直出直链 + 图集，PRD §5 第 3 项）。
///
/// 流程：口令/短链 → 跟随重定向拿作品 ID → 请求分享页 → 抽取页面内
/// `_ROUTER_DATA` JSON → 视频/图集直链。数据结构为页面公开携带的内容。
class DouyinParser extends LinkParser {
  const DouyinParser();

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36';

  @override
  String get id => 'douyin';
  @override
  String get displayName => '抖音';
  @override
  PlatformKind get kind => PlatformKind.video;
  @override
  bool get requiresAuth => false; // 免登录直出（红线 3）

  @override
  bool matches(String input) =>
      input.contains('douyin.com') || input.contains('iesdouyin.com');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    var url = ParseUtils.firstUrl(input);
    if (url == null) {
      throw const ParseError('未在输入中找到抖音链接', kind: ParseErrorKind.notFound);
    }

    // 1. 跟随短链 → 最终地址（含作品 ID）
    final first = await ctx.httpGet(url, headers: {'User-Agent': _ua});
    var finalUrl = first.finalUri.toString();
    var awemeId = _extractId(finalUrl);

    // 2. 若短链给的是 /share/video/{id} 形式，直接用路径里的 id
    awemeId ??= RegExp(r'(?:video|note|slides)/(\d+)').firstMatch(finalUrl)?.group(1);
    if (awemeId == null) {
      throw const ParseError('抖音: 未从链接中解析出作品 ID',
          kind: ParseErrorKind.notFound);
    }

    // 3. 拉分享页数据
    final page = await ctx.httpGet(
      'https://www.iesdouyin.com/share/video/$awemeId',
      headers: {'User-Agent': _ua, 'Referer': 'https://www.douyin.com/'},
    );
    final routerData = _extractRouterData(page.body);
    if (routerData == null) {
      throw ParseError('抖音: 页面数据不可用（平台改版或风控）',
          kind: ParseErrorKind.rateLimited);
    }

    final item = _findItem(routerData, awemeId);
    if (item == null) {
      throw const ParseError('抖音: 未找到作品数据', kind: ParseErrorKind.notFound);
    }
    return _toMediaSet(item);
  }

  String? _extractId(String url) =>
      RegExp(r'(?:video|note|slides)/(\d+)').firstMatch(url)?.group(1);

  /// 从 HTML 中抽取 `_ROUTER_DATA = {...};` 的 JSON。
  Map<String, dynamic>? _extractRouterData(String html) {
    final m = RegExp(r'window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*</script>',
            dotAll: true)
        .firstMatch(html);
    if (m == null) return null;
    try {
      return (jsonDecode(m.group(1)!) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _findItem(Map<String, dynamic> router, String id) {
    final loader = (router['loaderData'] ?? const {}) as Map;
    for (final v in loader.values) {
      final map = (v as Map?)?.cast<String, dynamic>();
      final res = map?['videoInfoRes'] as Map?;
      final items = (res?['item_list'] ?? res?['items'] ?? const []) as List;
      for (final raw in items) {
        final item = (raw as Map).cast<String, dynamic>();
        if ((item['aweme_id'] ?? id) != null) return item;
      }
    }
    return null;
  }

  MediaSetResult _toMediaSet(Map<String, dynamic> item) {
    final author = ((item['author'] ?? const {}) as Map)['nickname'] as String?;
    final desc = (item['desc'] ?? '') as String;

    // 视频
    final video = item['video'] as Map?;
    String? videoUrl;
    if (video != null) {
      final playAddr = video['play_addr'] as Map?;
      final urls = (playAddr?['url_list'] ?? const []) as List;
      if (urls.isNotEmpty) videoUrl = (urls.first as String).replaceFirst('playwm', 'play');
    }

    // 图集（slides）
    final images = <MediaItem>[];
    final imageList = (item['images'] ?? const []) as List;
    for (final raw in imageList) {
      final img = (raw as Map).cast<String, dynamic>();
      final urlList = (img['url_list'] ?? const []) as List;
      if (urlList.isNotEmpty) {
        images.add(MediaItem(
          url: urlList.first as String,
          kind: MediaKind.image,
          headers: {'Referer': 'https://www.douyin.com/', 'User-Agent': _ua},
        ));
      }
    }

    final items = <MediaItem>[
      if (videoUrl != null)
        MediaItem(
          url: videoUrl,
          kind: MediaKind.video,
          qualityLabel: '原画（无水印）',
          headers: {'Referer': 'https://www.douyin.com/', 'User-Agent': _ua},
        ),
      ...images,
    ];
    if (items.isEmpty) {
      throw const ParseError('抖音: 未取得可下载资源', kind: ParseErrorKind.generic);
    }
    return MediaSetResult(title: desc, author: author, items: items);
  }
}
