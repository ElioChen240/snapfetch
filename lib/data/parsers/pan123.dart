import 'dart:convert';
import 'dart:math';

import '../../domain/parser.dart';
import 'common.dart';

/// 123 云盘解析（对齐官方 Pan123Api / Pan123Constants）。
///
/// 关键事实（官方源码）：
/// - 分享列表：`GET https://yun.123pan.cn/b/api/share/get`，**免登录**，UA 用 `Dart/3.12`
///   响应 `data.InfoList[]`，字段 `FileId / FileName / Size / Type(1=文件夹) / ParentFileId /
///   S3KeyFlag / Etag / StorageNode / UpdateAt / DownloadUrl`，`data.Next` 为翻页游标（"-1" 结束）
/// - 分享取链 / 个人盘列表：需要 **Bearer token**（不是 Cookie）+ 签名头
///   `auth-key` / `auth-value`（crc32 变体，见 [_makeSign]）
/// - token 存在浏览器 localStorage 的 `authorToken`，登录页负责抓取后塞进
///   [ParseContext.cookies] 的 `__pan123_token`
class Pan123Parser extends LinkParser implements CloudBrowser {
  Pan123Parser();

  static const _apiBase = 'https://yun.123pan.cn';
  static const _downloadBase = 'https://www.123865.com';
  static const _referer = 'https://yun.123pan.cn/';
  static const _dartUa = 'Dart/3.12 (dart:io)';
  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';

  /// 签名常量（官方 Pan123Constants）
  static const _signTable = 'adefghlmyijnopkqrstubcvwsz';
  static const _signOffsetSeconds = 57600; // +16h

  /// token 在 cookies 里的键名
  static const tokenKey = '__pan123_token';

  String? _lastShareKey;

  @override
  String get id => 'pan123';
  @override
  String get displayName => '123 云盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => false; // 分享列表免登录；取链需 token
  @override

  @override
  bool matches(String input) =>
      input.contains('123pan.com') ||
      input.contains('123684.com') ||
      input.contains('123865.com') ||
      input.contains('123912.com') ||
      input.contains('123pan.cn');

  // ==================== 分享解析（免登录）====================

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    final shareKey = _extractKey(input);
    if (shareKey == null) {
      throw const ParseError('不是有效的 123 云盘分享链接', kind: ParseErrorKind.notFound);
    }
    final pwd = ParseUtils.extractPasscode(input);
    _lastShareKey = shareKey;


    final files = await _listShare(
      ctx,
      shareKey: shareKey,
      pwd: pwd,
      parentId: '0',
      prefix: '',
    );
    return FileTreeResult(shareTitle: shareKey, roots: files);
  }

  String? _extractKey(String input) {
    for (final p in [
      RegExp(r'123pan\.com/s/([0-9a-zA-Z-]+)'),
      RegExp(r'123684\.com/s/([0-9a-zA-Z-]+)'),
      RegExp(r'123865\.com/s/([0-9a-zA-Z-]+)'),
      RegExp(r'123912\.com/s/([0-9a-zA-Z-]+)'),
      RegExp(r'123pan\.cn/s/([0-9a-zA-Z-]+)'),
    ]) {
      final m = p.firstMatch(input);
      if (m != null) return m.group(1);
    }
    return null;
  }

  Future<List<FileNode>> _listShare(
    ParseContext ctx, {
    required String shareKey,
    String? pwd,
    required String parentId,
    required String prefix,
  }) async {
    final out = <FileNode>[];
    var next = '';
    var page = 1;
    while (true) {
      final uri = Uri.parse('$_apiBase/b/api/share/get').replace(queryParameters: {
        'limit': '100',
        'next': next,
        'orderBy': 'file_name',
        'orderDirection': 'asc',
        'shareKey': shareKey,
        'ParentFileId': parentId,
        'Page': '$page',
        if (pwd != null && pwd.isNotEmpty) 'SharePwd': pwd,
      });
      final res = await ctx.httpGet(uri.toString(), headers: {
        'User-Agent': _dartUa,
        'Accept': 'application/json, text/plain, */*',
      });
      final map = ParseUtils.expectOk(
          ParseUtils.json(res.body, platform: displayName), displayName);
      final data = (map['data'] ?? const {}) as Map;

      if (data['Expired'] == true) {
        throw ParseError('123 云盘: 分享已过期或提取码错误',
            kind: ParseErrorKind.notFound);
      }
      final list = (data['InfoList'] ?? const []) as List;
      for (final raw in list) {
        final item = raw.cast<String, dynamic>();
        final name = (item['FileName'] ?? '') as String;
        final fid = (item['FileId']?.toString()) ?? '';
        final isDir = (item['Type'] as num?)?.toInt() == 1;
        final path = prefix.isEmpty ? name : '$prefix/$name';
        if (isDir) {
          final children = await _listShare(
            ctx,
            shareKey: shareKey,
            pwd: pwd,
            parentId: fid,
            prefix: path,
          );
          out.add(FileNode(
              name: name, path: path, isDirectory: true, children: children));
        } else {
          // 取链需要 S3KeyFlag/Etag/Size —— 编码进占位串
          final s3 = item['S3KeyFlag']?.toString() ?? '';
          final etag = item['Etag']?.toString() ?? '';
          final size = (item['Size'] as num?)?.toInt() ?? 0;
          out.add(FileNode(
            name: name,
            path: path,
            isDirectory: false,
            size: size,
            directUrl: 'pan123-share://$fid|$s3|$etag|$size',
          ));
        }
      }
      final n = data['Next']?.toString();
      if (list.isEmpty || n == null || n == '-1') break;
      next = n;
      page++;
      if (page > 200) break;
    }
    return out;
  }

  /// 分享文件取直链（POST /b/api/share/download/info，需 token + 签名）。
  @override
  Future<String> resolveDirectUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url == null) throw ParseError('123 云盘: 文件无直链信息');
    if (url.startsWith('http')) return url;
    const prefix = 'pan123-share://';
    if (!url.startsWith(prefix)) {
      throw ParseError('123 云盘: 无法识别的直链占位: $url');
    }
    final parts = url.substring(prefix.length).split('|');
    if (parts.length < 4) throw ParseError('123 云盘: 直链信息不完整');
    final fid = parts[0];
    final s3 = parts[1];
    final etag = parts[2];
    final size = int.tryParse(parts[3]) ?? 0;
    final token = ctx.cookies[tokenKey];
    if (token == null || token.isEmpty) {
      throw ParseError('123 云盘: 需要登录后才能取下载直链',
          kind: ParseErrorKind.credentialExpired);
    }
    final shareKey = _lastShareKey;
    if (shareKey == null) {
      throw const ParseError('123 云盘: 缺少分享上下文，请重新解析',
          kind: ParseErrorKind.credentialExpired);
    }

    final body = {
      'ShareKey': shareKey,
      'FileID': fid,
      'S3KeyFlag': s3,
      'Size': size,
      'Etag': etag,
    };
    final res = await _postAuth(
      ctx,
      '$_downloadBase/b/api/share/download/info',
      '/b/api/share/download/info',
      body,
      token,
      platform: 'android',
      appVersion: '39',
    );
    final map = ParseUtils.expectOk(
        ParseUtils.json(res.body, platform: displayName), displayName);
    final data = (map['data'] ?? const {}) as Map;
    final raw = (data['DownloadURL'] ?? '') as String;
    if (raw.isEmpty) {
      throw ParseError('123 云盘: 未返回下载链接（可能需要登录或分享失效）',
          kind: ParseErrorKind.credentialExpired);
    }
    return _decodeDownloadUrl(raw);
  }

  // ==================== 个人盘浏览（需 token）====================

  @override
  Future<List<FileNode>> listMyFiles(ParseContext ctx, {String? parentId}) async {
    final token = ctx.cookies[tokenKey];
    if (token == null || token.isEmpty) {
      throw ParseError('123 云盘: 需要登录后才能浏览文件',
          kind: ParseErrorKind.credentialExpired);
    }
    final out = <FileNode>[];
    var next = '0';
    var page = 1;
    while (true) {
      final uri = Uri.parse('$_apiBase/b/api/file/list/new').replace(
        queryParameters: {
          'driveId': '0',
          'limit': '100',
          'next': next,
          'orderBy': 'update_time',
          'orderDirection': 'desc',
          'parentFileId': parentId ?? '0',
          'trashed': 'false',
          'SearchData': '',
          'Page': '1',
          'OnlyLookAbnormalFile': '0',
          'event': 'homeListFile',
          'operateType': '1',
          'inDirectSpace': 'false',
        },
      );
      final res = await _getAuth(
        ctx,
        uri.toString(),
        '/b/api/file/list/new',
        token,
      );
      final map = ParseUtils.expectOk(
          ParseUtils.json(res.body, platform: displayName), displayName);
      final data = (map['data'] ?? const {}) as Map;
      final list = (data['InfoList'] ?? const []) as List;
      for (final raw in list) {
        final item = raw.cast<String, dynamic>();
        final name = (item['FileName'] ?? '') as String;
        final fid = (item['FileId']?.toString()) ?? '';
        final isDir = (item['Type'] as num?)?.toInt() == 1;
        final size = (item['Size'] as num?)?.toInt() ?? 0;
        final s3 = item['S3KeyFlag']?.toString() ?? '';
        final etag = item['Etag']?.toString() ?? '';
        out.add(FileNode(
          name: name,
          path: fid,
          isDirectory: isDir,
          size: size,
          directUrl: isDir ? null : 'pan123-mine://$fid|$s3|$etag|$size',
        ));
      }
      final n = data['Next']?.toString();
      if (list.isEmpty || n == null || n == '-1') break;
      next = n;
      page++;
      if (page > 200) break;
    }
    return out;
  }

  @override
  Future<String> getMyFileDownloadUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url != null && url.startsWith('http')) return url;
    final token = ctx.cookies[tokenKey];
    if (token == null || token.isEmpty) {
      throw ParseError('123 云盘: 需要登录后才能取下载直链',
          kind: ParseErrorKind.credentialExpired);
    }
    const prefix = 'pan123-mine://';
    final raw = (url != null && url.startsWith(prefix))
        ? url.substring(prefix.length)
        : '${node.path}|||';
    final parts = raw.split('|');
    final fid = parts[0];
    final s3 = parts.length > 1 ? parts[1] : '';
    final etag = parts.length > 2 ? parts[2] : '';
    final size = int.tryParse(parts.length > 3 ? parts[3] : '') ?? 0;

    final res = await _postAuth(
      ctx,
      '$_apiBase/api/file/download_info',
      '/api/file/download_info',
      {'FileID': fid, 'S3KeyFlag': s3, 'Size': size, 'Etag': etag},
      token,
      platform: 'web',
      appVersion: '3',
    );
    final map = ParseUtils.expectOk(
        ParseUtils.json(res.body, platform: displayName), displayName);
    final data = (map['data'] ?? const {}) as Map;
    final dl = (data['DownloadUrl'] ?? data['DownloadURL'] ?? '') as String;
    if (dl.isEmpty) {
      throw ParseError('123 云盘: 未返回下载链接', kind: ParseErrorKind.credentialExpired);
    }
    return _decodeDownloadUrl(dl);
  }

  @override
  Future<String?> fetchNickname(ParseContext ctx) async {
    final token = ctx.cookies[tokenKey];
    if (token == null || token.isEmpty) return null;
    try {
      final res = await _getAuth(ctx, '$_apiBase/b/api/user/info', '/b/api/user/info', token);
      final map = ParseUtils.json(res.body, platform: displayName) as Map;
      final data = (map['data'] ?? const {}) as Map;
      final nick = (data['Nickname'] ?? data['nickname'] ?? '') as String;
      return nick.isEmpty ? null : nick;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<({int used, int total})?> fetchQuota(ParseContext ctx) async {
    final token = ctx.cookies[tokenKey];
    if (token == null || token.isEmpty) return null;
    try {
      final res = await _getAuth(ctx, '$_apiBase/b/api/user/info', '/b/api/user/info', token);
      final map = ParseUtils.json(res.body, platform: displayName) as Map;
      final data = (map['data'] ?? const {}) as Map;
      final used = (data['UsedSpace'] as num?)?.toInt() ?? 0;
      final total = (data['SpacePermanent'] as num?)?.toInt() ??
          (data['Space'] as num?)?.toInt() ??
          0;
      if (total <= 0) return null;
      return (used: used, total: total);
    } catch (_) {
      return null;
    }
  }

  // ==================== 签名与请求 ====================

  /// CRC32（IEEE，与 Java CRC32 一致）的小写 hex。
  static String _crc32Hex(String s) {
    var crc = 0xFFFFFFFF;
    for (final b in utf8.encode(s)) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
      }
    }
    return ((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF).toRadixString(16);
  }

  /// 官方 makeSign：auth-key = crc32(替换后的 UTC 时间)，auth-value = ts-random-crc32(拼接串)。
  static ({String key, String value}) _makeSign(String path) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final utc = DateTime.fromMillisecondsSinceEpoch(
      (ts + _signOffsetSeconds) * 1000,
      isUtc: true,
    );
    String two(int v) => v.toString().padLeft(2, '0');
    final minute = '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}${two(utc.hour)}${two(utc.minute)}';
    final substituted =
        minute.split('').map((c) => _signTable[int.parse(c)]).join();
    final authKey = _crc32Hex(substituted);
    final random = Random().nextInt(10000000);
    final data = '$ts|$random|$path|web|3|$authKey';
    return (key: authKey, value: '$ts-$random-${_crc32Hex(data)}');
  }

  Map<String, String> _authHeaders(String path, String token,
      {String platform = 'web', String appVersion = '3'}) {
    final sign = _makeSign(path);
    return {
      'platform': platform,
      'app-version': appVersion,
      'authorization': 'Bearer $token',
      'auth-key': sign.key,
      'auth-value': sign.value,
      'User-Agent': _webUa,
      'Accept': 'application/json, text/plain, */*',
      'Referer': _referer,
    };
  }

  Future<PHttpResponse> _getAuth(
    ParseContext ctx,
    String url,
    String path,
    String token,
  ) {
    return ctx.httpGet(url, headers: _authHeaders(path, token));
  }

  Future<PHttpResponse> _postAuth(
    ParseContext ctx,
    String url,
    String path,
    Map<String, dynamic> body,
    String token, {
    String platform = 'web',
    String appVersion = '3',
  }) {
    return ctx.httpPost(
      url,
      jsonBody: body,
      headers: {
        ..._authHeaders(path, token, platform: platform, appVersion: appVersion),
        'Content-Type': 'application/json',
      },
    );
  }

  /// 官方 decodeDownloadUrl：`download-v2?params=<base64>` 要解码成真实 CDN 直链。
  static String _decodeDownloadUrl(String raw) {
    try {
      final uri = Uri.tryParse(raw);
      if (uri == null) return raw;
      if (!raw.contains('download-v2')) return raw;
      final params = uri.queryParameters['params'];
      if (params == null || params.isEmpty) return raw;
      final decoded = utf8.decode(base64Url.decode(params));
      // 解码结果是 JSON 或直接 URL
      final trimmed = decoded.trim();
      if (trimmed.startsWith('{"')) {
        final map = jsonDecode(trimmed) as Map;
        final u = (map['url'] ?? map['download_url'] ?? '') as String;
        return u.isEmpty ? raw : u;
      }
      if (trimmed.startsWith('http')) return trimmed;
      return raw;
    } catch (_) {
      return raw;
    }
  }
}
