/// 解析结果：统一为「文件树」或「媒体集」两种形态。
/// 对应 PRD §6 / §8.3。
sealed class ParseResult {
  const ParseResult();
}

/// 网盘分享：一棵可递归的文件树。
class FileTreeResult extends ParseResult {
  final String shareTitle;
  final List<FileNode> roots;
  const FileTreeResult({required this.shareTitle, required this.roots});
}

/// 视频 / 图集作品。
class MediaSetResult extends ParseResult {
  final String title;
  final String? author;
  final String? coverUrl;
  final List<MediaItem> items;
  const MediaSetResult({
    required this.title,
    this.author,
    this.coverUrl,
    required this.items,
  });
}

class FileNode {
  final String name;
  final String path;
  final bool isDirectory;
  final int? size; // bytes
  final String? directUrl; // 取链后填充
  /// 子项。分享解析是一次性填满；云盘浏览是进入目录时才异步加载（见 FileBrowser.loadChildren）。
  List<FileNode>? children;
  /// 更新时间（毫秒时间戳，网盘浏览列表用；分享解析可能为空）
  final int? updatedAt;
  FileNode({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.directUrl,
    this.children,
    this.updatedAt,
  });
}

enum MediaKind { video, image, audio }

class MediaItem {
  final String url;
  final MediaKind kind;
  final String? qualityLabel;
  final int? size;
  final Map<String, String> headers; // Referer / Cookie，防 403
  const MediaItem({
    required this.url,
    required this.kind,
    this.qualityLabel,
    this.size,
    this.headers = const {},
  });
}

/// 解析层的 HTTP 响应（domain 不依赖 dio）。
class PHttpResponse {
  final int statusCode;
  final String body;
  final Uri finalUri; // 跟随重定向后的最终地址
  final Map<String, String> headers;
  const PHttpResponse({
    required this.statusCode,
    required this.body,
    required this.finalUri,
    this.headers = const {},
  });
}

/// 解析失败：统一错误分类，供 UI 呈现「该做什么」。
class ParseError implements Exception {
  final String message;
  final ParseErrorKind kind;
  const ParseError(this.message, {this.kind = ParseErrorKind.generic});
  @override
  String toString() => message;
}

enum ParseErrorKind {
  generic, // 其他错误
  notFound, // 链接无效 / 分享不存在
  needPasscode, // 需要提取码或提取码错误
  credentialExpired, // 凭证失效（UI 提示重新登录）
  rateLimited, // 平台风控/限流
}

/// 解析上下文：注入网络客户端与凭证，解析器不自行管理全局状态。
class ParseContext {
  final Map<String, String> cookies;
  final Map<String, String> baseHeaders;
  final Future<PHttpResponse> Function(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) httpGet;
  final Future<PHttpResponse> Function(
    String url, {
    Map<String, dynamic>? jsonBody,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) httpPost;
  final void Function(String message) log;

  /// 用户偏好：免转存下载（对应手机版夸克设置项）。
  ///
  /// true（默认）= 解析出直链后直接下载，不把文件转存进自己的网盘；
  /// false = 先转存到自己账号根目录，再从「我的文件」取直链下载
  ///         （部分文件免转存取不到直链时，这条路能兜住；需已登录）。
  final bool noTransferDownload;

  /// 当前凭证里是否带了 Cookie/token（false = 未登录，UI 可提示游客限制）。
  bool get hasCredential => cookies.isNotEmpty;

  const ParseContext({
    this.cookies = const {},
    this.baseHeaders = const {},
    required this.httpGet,
    required this.httpPost,
    required this.log,
    this.noTransferDownload = true,
  });

  /// 下载请求必须携带的头（Cookie + Referer）。
  ///
  /// ★ 网盘直链是「带签名 + 绑 Cookie」的：**不带 Cookie 直接下载会被 CDN 拒绝**
  ///   （返回 200 但 body 是几百字节的错误 JSON/HTML）。
  ///   实测「243KB 的图片只下到 262B」就是这个原因。
  Map<String, String> get downloadHeaders => {
        if (cookies.isNotEmpty)
          'Cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        ...baseHeaders,
      };
}

/// 平台类型，决定是否需要登录凭证。
enum PlatformKind { netdisk, video }

/// ★ 解析器插件接口（PRD §8.3）：新增平台 = 新增一个实现 + 注册，不动核心。
abstract class LinkParser {
  const LinkParser();
  String get id; // 'quark' / 'douyin' ...
  String get displayName; // '夸克网盘'
  PlatformKind get kind;

  /// 是否需要登录凭证。免登录可解析的平台必须为 false（PRD §2.1 红线 3）。
  bool get requiresAuth;

  /// 平台识别：域名 / 短链 / 口令特征。
  bool matches(String input);

  /// 解析入口。
  Future<ParseResult> parse(String input, ParseContext ctx);

  /// 把解析结果里的文件换成可直接下载的 HTTP 直链（下载前按需调用）。
  ///
  /// 约定：`FileNode.directUrl` 若已是 http(s) 直链则原样返回；
  /// 若是平台占位（如 `quark-fid://xxx`）则调平台接口换取真直链。
  /// 抛 [ParseError]（credentialExpired 时 UI 应引导重新登录）。
  Future<String> resolveDirectUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url == null || url.isEmpty) {
      throw ParseError('$displayName 无法取得该文件的直链');
    }
    if (url.startsWith('http')) return url;
    throw ParseError('$displayName 暂不支持按需取链');
  }
}

/// 账号云盘浏览能力（PRD §4.1「多平台登录」配套 / 对齐官方「网盘」页）。
///
/// 与 [LinkParser]（解析别人分享的链接）不同：这里是**浏览自己账号里的文件**。
/// 只有需要登录的网盘平台才实现它（视频平台不需要）。
abstract class CloudBrowser {
  /// 列出某目录下的文件；[parentId] 为空表示根目录。
  Future<List<FileNode>> listMyFiles(ParseContext ctx, {String? parentId});

  /// 取自己文件的下载直链。
  Future<String> getMyFileDownloadUrl(ParseContext ctx, FileNode node);

  /// 账号昵称（账号卡片副标题显示）。
  Future<String?> fetchNickname(ParseContext ctx);

  /// 容量（已用 / 总量，字节）；拿不到返回 null。
  Future<({int used, int total})?> fetchQuota(ParseContext ctx);
}

/// 解析器注册表：启动时注册，按输入路由。
class ParserRegistry {
  final List<LinkParser> _parsers = [];

  void register(LinkParser parser) => _parsers.add(parser);

  List<LinkParser> get all => List.unmodifiable(_parsers);

  LinkParser? route(String input) {
    for (final p in _parsers) {
      if (p.matches(input)) return p;
    }
    return null;
  }
}

/// 下载任务状态（PRD §6.4）。
enum TaskStatus { queued, running, paused, completed, failed }

class DownloadTask {
  final String id;
  final String url;
  final String savePath;
  final Map<String, String> headers;
  int totalBytes; // HEAD 探测后回写，故非 final
  int downloadedBytes;
  TaskStatus status;
  /// 最近一次失败原因（UI 展示，不持久化也可）
  String? errorMessage;
  final List<Chunk> chunks;

  DownloadTask({
    required this.id,
    required this.url,
    required this.savePath,
    this.headers = const {},
    required this.totalBytes,
    this.downloadedBytes = 0,
    this.status = TaskStatus.queued,
    List<Chunk> chunks = const [],
  }) : chunks = List<Chunk>.of(chunks);

  double get progress => totalBytes == 0 ? 0 : downloadedBytes / totalBytes;
}

/// 分片记录：断点续传的依据（固定分片规划，PRD §2.1 红线 5）。
class Chunk {
  final int index;
  final int start;
  final int end;
  int written;
  Chunk({required this.index, required this.start, required this.end, this.written = 0});
}

/// 下载引擎抽象：Range 分片并发 + 断点续传 + 暂停/继续/持久化。
/// M1 落地具体实现（dio + Isolate + 文件随机写）。
abstract class DownloadEngine {
  Future<void> enqueue(DownloadTask task);
  Future<void> pause(String taskId);
  Future<void> resume(String taskId);
  Future<void> cancel(String taskId, {bool deleteFile = false});
  Stream<DownloadTask> get progressStream;
  Future<List<DownloadTask>> restoreQueue();
}
