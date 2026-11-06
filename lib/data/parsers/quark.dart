import '../../domain/parser.dart';
import 'common.dart';
import 'quark_signer.dart';

/// 夸克网盘解析（分享 token 免登录可取；**取直链需要登录 Cookie**）。
///
/// 接口结构为公开协议事实（社区广泛记录），实现独立编写。
/// ⚠️ 字段名/签名拼接可能随平台改版变化：只改本文件，改完跑 fixture 测试 + 真实链接验证。
class QuarkParser extends LinkParser implements CloudBrowser {
  // 有会话缓存字段（分享取链需要 shareId/stoken），不能用 const 构造
  QuarkParser();

  /// 最近一次解析的分享上下文（取直链时必需：fids_token + pwd_id + stoken）
  String? _lastShareId;
  String? _lastStoken;

  static const _base = 'https://drive-pc.quark.cn/1/clouddrive';
  static const _referer = 'https://pan.quark.cn/';
  static const _commonQuery = {'pr': 'ucpro', 'fr': 'pc'};

  /// 下载端点（官方 DOWNLOAD_URL；个人文件与分享取链共用）
  static const _downloadUrl =
      '$_base/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2';

  @override
  String get id => 'quark';
  @override
  String get displayName => '夸克网盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => true;

  @override
  bool matches(String input) =>
      input.contains('pan.quark.cn') || input.contains('quark.cn/s/');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    final shareId = _extractShareId(input);
    if (shareId == null) {
      throw const ParseError('不是有效的夸克分享链接', kind: ParseErrorKind.notFound);
    }
    final passcode = ParseUtils.extractPasscode(input);

    // 1. 分享 token（带提取码，免登录可取）
    final stoken = await _getStoken(ctx, shareId, passcode);
    // 缓存：后续 resolveDirectUrl 需要 shareId + stoken 一起提交
    _lastShareId = shareId;
    _lastStoken = stoken;

    // 2. 递归列出分享文件树
    final files = await _listAll(ctx, shareId, stoken, pdirFid: '0', pathPrefix: '');

    return FileTreeResult(shareTitle: shareId, roots: files);
  }

  /// 分享文件取直链（免转存，登录态）。
  ///
  /// 官方 `getShareDownloadLinkWithoutSave`：POST `DOWNLOAD_URL`，body 同时带
  /// `fids`（文件 fid）、`fids_token`（share_fid_token）、`pwd_id`（分享短码）、
  /// `stoken`（分享凭证）与两个空占位 `speedup_session` / `token`。
  /// 响应 `data` 是**数组**，取 `data[0].download_url`。
  Future<String> getDownloadUrl(
    ParseContext ctx, {
    required String fid,
    required String fidToken,
  }) async {
    final shareId = _lastShareId;
    final stoken = _lastStoken;
    if (shareId == null || stoken == null) {
      throw const ParseError('夸克: 缺少分享上下文，请重新解析链接',
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

  /// `quark-fid://<fid>|<fidToken>` → 换真直链
  @override
  Future<String> resolveDirectUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url == null) throw ParseError('夸克: 文件无直链信息');
    if (url.startsWith('http')) return url;
    const prefix = 'quark-fid://';
    if (!url.startsWith(prefix)) {
      throw ParseError('夸克: 无法识别的直链占位: $url');
    }
    final parts = url.substring(prefix.length).split('|');
    final fid = parts.isNotEmpty ? parts[0] : '';
    final fidToken = parts.length > 1 ? parts[1] : '';
    return getDownloadUrl(ctx, fid: fid, fidToken: fidToken);
  }

  String? _extractShareId(String input) {
    final m = RegExp(r'pan\.quark\.cn/s/([0-9a-zA-Z]+)').firstMatch(input);
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
      throw ParseError('夸克: 未取得分享 token', kind: ParseErrorKind.notFound);
    }
    return stoken;
  }

  /// 递归列出分享内全部文件（含子目录与翻页）。
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
      final uri = Uri.parse('$_base/share/sharepage/detail').replace(
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
            // 占位：fid|fidToken —— 分享取链两者都要（官方 fids + fids_token）
            directUrl: 'quark-fid://$realFid|$fidToken',
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

  // ========== CloudBrowser：浏览自己账号里的文件（对齐官方「网盘」页） ==========

  /// 列出某目录下的文件（`/1/clouddrive/file/sort`，pdir_fid=0 为根）。
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
        'Origin': 'https://pan.quark.cn',
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
          path: fid, // 云盘内用 fid 作为唯一标识
          isDirectory: isDir,
          size: (item['size'] as num?)?.toInt(),
          updatedAt: (item['updated_at'] as num?)?.toInt(),
          directUrl: isDir ? null : 'quark-cloud-fid://$fid',
        ));
      }
      final total = ((data['_total'] ?? 0) as num).toInt();
      if (list.isEmpty || out.length >= total) break;
      page++;
      if (page > 100) break; // 防御上限
    }
    return out;
  }

  /// 统一下载请求：POST `DOWNLOAD_URL`，响应 `data` 为数组。
  ///
  /// ★ 官方实现：`data` 是**数组**（`data[0].download_url`），不是 `data.list`
  ///   （此前误按对象解析 → 永远取不到直链，表现为「已加入下载 0 个，失败 1 个」）。
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
        'Origin': 'https://pan.quark.cn',
      },
    );
    final map = ParseUtils.expectOk(
        ParseUtils.json(res.body, platform: displayName), displayName);
    final data = map['data'];
    final list = data is List ? data : const [];
    if (list.isEmpty) {
      throw ParseError('夸克: 未返回下载链接（登录态可能已失效）',
          kind: ParseErrorKind.credentialExpired);
    }
    final item = (list.first as Map);
    final dl = (item['download_url'] ?? item['downloadUrl']) as String?;
    if (dl == null || dl.isEmpty) {
      throw ParseError('夸克: 直链为空（可能触发风控或文件受限）',
          kind: ParseErrorKind.credentialExpired);
    }
    return dl;
  }

  /// 自己文件的下载直链（个人文件只需 fids，官方 getDownloadLink）。
  @override
  Future<String> getMyFileDownloadUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url != null && url.startsWith('http')) return url;
    const prefix = 'quark-cloud-fid://';
    final fid = (url != null && url.startsWith(prefix))
        ? url.substring(prefix.length)
        : node.path;

    return _requestDownloadUrl(ctx, body: {
      'fids': [fid],
    });
  }

  /// 账号昵称（https://pan.quark.cn/account/info）。
  @override
  Future<String?> fetchNickname(ParseContext ctx) async {
    try {
      final res = await ctx.httpGet(
        'https://pan.quark.cn/account/info',
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

  /// 容量（/1/clouddrive/member：use_capacity / total_capacity）。
  @override
  Future<({int used, int total})?> fetchQuota(ParseContext ctx) async {
    try {
      final res = await ctx.httpGet(
        '$_base/member?pr=ucpro&fr=pc&fetch_subscribe=true&_ch=home',
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
}
