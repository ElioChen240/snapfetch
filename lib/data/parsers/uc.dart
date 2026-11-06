import '../../domain/parser.dart';
import 'common.dart';
import 'quark_signer.dart';

/// UC 网盘解析 —— 与夸克同源（阿里系），接口结构同族、域名不同。
/// 独立实现（不继承 QuarkParser），签名细节同样待真实链接验证。
class UcParser extends LinkParser implements CloudBrowser {
  // 有分享上下文缓存，不能用 const 构造
  UcParser();

  /// 最近一次解析的分享上下文（取直链需要 fid + fidToken + pwd_id + stoken）
  String? _lastShareId;
  String? _lastStoken;

  static const _base = 'https://pc-api.uc.cn/1/clouddrive';
  static const _referer = 'https://drive.uc.cn/';
  static const _commonQuery = {'pr': 'UCBrowser', 'fr': 'pc'};

  @override
  String get id => 'uc';
  @override
  String get displayName => 'UC 网盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => true;

  @override
  bool matches(String input) => input.contains('drive.uc.cn');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    final shareId = _extractShareId(input);
    if (shareId == null) {
      throw const ParseError('不是有效的 UC 分享链接', kind: ParseErrorKind.notFound);
    }
    final passcode = ParseUtils.extractPasscode(input);

    final stoken = await _getStoken(ctx, shareId, passcode);
    _lastShareId = shareId;
    _lastStoken = stoken;
    final files = await _listAll(ctx, shareId, stoken, pdirFid: '0', pathPrefix: '');
    return FileTreeResult(shareTitle: shareId, roots: files);
  }

  /// 下载端点（官方 UCConstants.DOWNLOAD_URL：`/1/clouddrive/file/download`，
  /// 注意带 `entry=ft`，与夸克的 `/file/download` 参数不同）。
  static const _downloadUrl =
      '$_base/file/download?entry=ft&fr=pc&pr=UCBrowser';

  /// 分享取链：官方与夸克同构（fids + fids_token + pwd_id + stoken）。
  Future<String> getDownloadUrl(
    ParseContext ctx, {
    required String fid,
    required String fidToken,
  }) async {
    final shareId = _lastShareId;
    final stoken = _lastStoken;
    if (shareId == null || stoken == null) {
      throw const ParseError('UC: 缺少分享上下文，请重新解析链接',
          kind: ParseErrorKind.credentialExpired);
    }
    return _requestDownloadUrl(ctx, body: {
      'fids': [fid],
      'fids_token': [fidToken],
      'pwd_id': shareId,
      'stoken': stoken,
      'speedup_session': '',
      'token': '',
    });
  }

  /// 统一下载请求：POST `_downloadUrl`，响应 `data` 为数组。
  Future<String> _requestDownloadUrl(
    ParseContext ctx, {
    required Map<String, dynamic> body,
  }) async {
    final res = await ctx.httpPost(
      _downloadUrl,
      jsonBody: body,
      headers: {
        ...ParseUtils.jsonHeaders(referer: _referer),
        'Content-Type': 'application/json',
        'Origin': 'https://drive.uc.cn',
      },
    );
    final map = ParseUtils.expectOk(
        ParseUtils.json(res.body, platform: displayName), displayName);
    final data = map['data'];
    final list = data is List ? data : const [];
    if (list.isEmpty) {
      throw ParseError('UC: 未返回下载链接（登录态可能已失效）',
          kind: ParseErrorKind.credentialExpired);
    }
    final dl = ((list.first as Map)['download_url']) as String?;
    if (dl == null || dl.isEmpty) {
      throw ParseError('UC: 直链为空（可能触发风控）',
          kind: ParseErrorKind.credentialExpired);
    }
    return dl;
  }

  // ========== CloudBrowser：浏览自己账号里的文件 ==========

  @override
  Future<List<FileNode>> listMyFiles(ParseContext ctx, {String? parentId}) async {
    final out = <FileNode>[];
    var page = 1;
    while (true) {
      final uri = Uri.parse('$_base/file/sort').replace(queryParameters: {
        ..._commonQuery,
        'pdir_fid': parentId ?? '0',
        '_page': '$page',
        '_size': '100',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,updated_at:desc',
        'fetch_all_file': '1',
        'fetch_risk_file_name': '1',
      });
      final res = await ctx.httpGet(uri.toString(), headers: {
        ...ParseUtils.jsonHeaders(referer: _referer),
        'Origin': 'https://drive.uc.cn',
      });
      final map = ParseUtils.expectOk(
          ParseUtils.json(res.body, platform: displayName), displayName);
      final data = (map['data'] ?? const {}) as Map;
      final list = (data['list'] ?? const []) as List;
      for (final raw in list) {
        final item = raw.cast<String, dynamic>();
        final name = (item['file_name'] ?? '') as String;
        final isDir = (item['dir'] ?? false) as bool;
        final fid = (item['fid'] ?? '') as String;
        out.add(FileNode(
          name: name,
          path: fid,
          isDirectory: isDir,
          size: (item['size'] as num?)?.toInt(),
          updatedAt: (item['updated_at'] as num?)?.toInt(),
          directUrl: isDir ? null : 'uc-cloud-fid://$fid',
        ));
      }
      final total = ((data['_total'] ?? 0) as num).toInt();
      if (list.isEmpty || out.length >= total) break;
      page++;
      if (page > 100) break;
    }
    return out;
  }

  @override
  Future<String> getMyFileDownloadUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url != null && url.startsWith('http')) return url;
    const prefix = 'uc-cloud-fid://';
    final fid = (url != null && url.startsWith(prefix))
        ? url.substring(prefix.length)
        : node.path;
    return _requestDownloadUrl(ctx, body: {
      'fids': [fid],
    });
  }

  @override
  Future<String?> fetchNickname(ParseContext ctx) async {
    try {
      final res = await ctx.httpGet(
        'https://drive.uc.cn/account/info',
        headers: {'Referer': _referer},
      );
      final json = ParseUtils.json(res.body, platform: displayName) as Map;
      if (json['success'] != true) return null;
      final nick = ((json['data'] ?? const {}) as Map)['nickname'] as String?;
      return (nick == null || nick.isEmpty) ? null : nick;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<({int used, int total})?> fetchQuota(ParseContext ctx) async {
    try {
      final res = await ctx.httpGet(
        '$_base/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home',
        headers: ParseUtils.jsonHeaders(referer: _referer),
      );
      final map = ParseUtils.json(res.body, platform: displayName) as Map;
      final data = (map['data'] ?? const {}) as Map;
      final used = (data['use_capacity'] as num?)?.toInt() ?? 0;
      final total = (data['total_capacity'] as num?)?.toInt() ?? 0;
      if (total <= 0) return null;
      return (used: used, total: total);
    } catch (_) {
      return null;
    }
  }

  /// `uc-fid://<share_fid_token>` → 平台下载接口换真直链
  @override
  Future<String> resolveDirectUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url == null) throw ParseError('UC: 文件无直链信息');
    if (url.startsWith('http')) return url;
    const prefix = 'uc-fid://';
    if (!url.startsWith(prefix)) {
      throw ParseError('UC: 无法识别的直链占位: $url');
    }
    // 占位格式：uc-fid://<fid>|<fidToken>
    final parts = url.substring(prefix.length).split('|');
    return getDownloadUrl(
      ctx,
      fid: parts.isNotEmpty ? parts[0] : '',
      fidToken: parts.length > 1 ? parts[1] : '',
    );
  }

  String? _extractShareId(String input) {
    final m = RegExp(r'drive\.uc\.cn/s/([0-9a-zA-Z]+)').firstMatch(input);
    return m?.group(1);
  }

  Future<String> _getStoken(
    ParseContext ctx,
    String shareId,
    String? passcode,
  ) async {
    final res = await _signedPost(ctx, '$_base/share/sharepage/token',
        jsonBody: {'pwd_id': shareId, 'passcode': passcode ?? ''},
        timestampSec: DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final map =
        ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
    final stoken = ((map['data'] ?? const {}) as Map)['stoken'] as String?;
    if (stoken == null || stoken.isEmpty) {
      throw ParseError('UC: 未取得分享 token', kind: ParseErrorKind.notFound);
    }
    return stoken;
  }

  Future<List<FileNode>> _listAll(
    ParseContext ctx,
    String shareId,
    String stoken, {
    required String pdirFid,
    required String pathPrefix,
  }) async {
    final out = <FileNode>[];
    var page = 1;
    while (true) {
      final uri = Uri.parse('$_base/share/sharepage/v2/detail').replace(
        queryParameters: {
          ..._commonQuery,
          'pwd_id': shareId,
          'stoken': stoken,
          'pdir_fid': pdirFid,
          '_page': '$page',
          '_size': '50',
          '_fetch_banner': '0',
          '_fetch_share': '0',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,updated_at:desc',
        },
      );
      final res = await ctx.httpGet(uri.toString(),
          headers: ParseUtils.jsonHeaders(referer: _referer));
      final map =
          ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
      final data = (map['data'] ?? const {}) as Map;
      final list = (data['list'] ?? const []) as List;
      for (final raw in list) {
        final item = raw.cast<String, dynamic>();
        final name = (item['file_name'] ?? '') as String;
        final isDir = (item['dir'] ?? false) as bool;
        final realFid = (item['fid'] ?? '') as String;
        final fidToken = (item['share_fid_token'] ?? '') as String;
        final path = pathPrefix.isEmpty ? name : '$pathPrefix/$name';
        if (isDir) {
          final children = await _listAll(ctx, shareId, stoken,
              pdirFid: realFid, pathPrefix: path);
          out.add(FileNode(
              name: name, path: path, isDirectory: true, children: children));
        } else {
          out.add(FileNode(
            name: name,
            path: path,
            isDirectory: false,
            size: (item['size'] as num?)?.toInt(),
            // 占位：fid|fidToken（取链两者都要）
            directUrl: 'uc-fid://$realFid|$fidToken',
          ));
        }
      }
      final total = ((data['_total'] ?? 0) as num).toInt();
      if (list.isEmpty || out.length >= total) break;
      page++;
    }
    return out;
  }

  Future<PHttpResponse> _signedPost(
    ParseContext ctx,
    String url, {
    Map<String, dynamic>? jsonBody,
    required int timestampSec,
  }) {
    final signed = QuarkSigner.signParams(Uri.parse(url),
        jsonBody: jsonBody, timestampSec: timestampSec);
    final full = Uri.parse(url)
        .replace(queryParameters: {..._commonQuery, ...signed})
        .toString();
    return ctx.httpPost(
      full,
      jsonBody: jsonBody,
      headers: {
        ...ParseUtils.jsonHeaders(referer: _referer),
        'Content-Type': 'application/json',
      },
    );
  }
}
