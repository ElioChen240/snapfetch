import '../../domain/parser.dart';
import 'common.dart';

/// 123 云盘解析（免登录分享可解析；接口为公开协议行为，独立实现）。
class Pan123Parser extends LinkParser {
  // 有会话字段（_lastShareKey/_lastPasscode），不能用 const 构造
  Pan123Parser();

  static const _base = 'https://www.123pan.com/api';
  static const _referer = 'https://www.123pan.com/';

  @override
  String get id => 'pan123';
  @override
  String get displayName => '123 云盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => false; // 免登录分享（PRD 红线 3）

  @override
  bool matches(String input) =>
      input.contains('123pan.com') ||
      input.contains('123684.com') ||
      input.contains('123865.com') ||
      input.contains('123912.com');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    final shareKey = _extractKey(input);
    if (shareKey == null) {
      throw const ParseError('不是有效的 123 云盘分享链接', kind: ParseErrorKind.notFound);
    }
    final passcode = ParseUtils.extractPasscode(input);
    _lastShareKey = shareKey; // 供 resolveDirectUrl 换链时使用
    _lastPasscode = passcode;

    // 1. 分享信息（标题 + 根文件）
    final info = await _info(ctx, shareKey, passcode);
    final title = (info['ShareTitle'] ?? info['ShareName'] ?? shareKey) as String;

    // 2. 递归列目录
    final files = await _listAll(ctx, shareKey, passcode,
        pdirFileId: info['RootDirID']?.toString() ?? '0', pathPrefix: '');

    return FileTreeResult(shareTitle: title, roots: files);
  }

  /// `pan123-file://<FileId>` → 123 下载接口换真直链（待实测接口细节）
  @override
  Future<String> resolveDirectUrl(ParseContext ctx, FileNode node) async {
    final url = node.directUrl;
    if (url == null) throw ParseError('123 云盘: 文件无直链信息');
    if (url.startsWith('http')) return url;
    const prefix = 'pan123-file://';
    if (!url.startsWith(prefix)) {
      throw ParseError('123 云盘: 无法识别的直链占位: $url');
    }
    final fileId = url.substring(prefix.length);
    final res = await ctx.httpPost(
      '$_base/share/download/info',
      jsonBody: {
        'ShareKey': _lastShareKey,
        'SharePwd': _lastPasscode ?? '',
        'FileId': fileId,
      },
      headers: {...ParseUtils.jsonHeaders(referer: _referer), 'Platform': 'web'},
    );
    final map =
        ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
    final data = (map['data'] ?? const {}) as Map;
    final dl = (data['DownloadUrl'] ?? data['download_url']) as String?;
    if (dl == null || dl.isEmpty) {
      throw ParseError('123 云盘: 未取得直链', kind: ParseErrorKind.generic);
    }
    return dl;
  }

  // resolveDirectUrl 所需的会话信息（parse 时记录）
  String? _lastShareKey;
  String? _lastPasscode;

  String? _extractKey(String input) {
    final m = RegExp(r'123pan\.com/s/([0-9a-zA-Z-]+)').firstMatch(input) ??
        RegExp(r'123684\.com/s/([0-9a-zA-Z-]+)').firstMatch(input) ??
        RegExp(r'123865\.com/s/([0-9a-zA-Z-]+)').firstMatch(input);
    return m?.group(1);
  }

  Future<Map<String, dynamic>> _info(
    ParseContext ctx,
    String shareKey,
    String? passcode,
  ) async {
    final res = await ctx.httpPost(
      '$_base/share/info',
      jsonBody: {'ShareKey': shareKey, 'PassCode': passcode ?? ''},
      headers: {...ParseUtils.jsonHeaders(referer: _referer), 'Platform': 'web'},
    );
    final map =
        ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
    final data = (map['data'] ?? const {}) as Map;
    if ((data['ShareKey'] ?? data['share_key']) == null) {
      throw ParseError('123 云盘: 分享不存在', kind: ParseErrorKind.notFound);
    }
    return data.cast<String, dynamic>();
  }

  Future<List<FileNode>> _listAll(
    ParseContext ctx,
    String shareKey,
    String? passcode, {
    required String pdirFileId,
    required String pathPrefix,
  }) async {
    final out = <FileNode>[];
    var page = 1;
    while (true) {
      final res = await ctx.httpGet(
        '$_base/share/list',
        query: {
          'limit': '100',
          'next': '$page',
          'orderBy': 'file_name',
          'orderDirection': 'asc',
          'shareKey': shareKey,
          'SharePwd': passcode ?? '',
          'parentFileId': pdirFileId,
          'Page': '$page',
        },
        headers: {...ParseUtils.jsonHeaders(referer: _referer), 'Platform': 'web'},
      );
      final map =
          ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
      final data = (map['data'] ?? const {}) as Map;
      final list = (data['InfoList'] ?? data['fileList'] ?? const []) as List;
      if (list.isEmpty) break;
      for (final raw in list) {
        final item = raw.cast<String, dynamic>();
        final name = (item['FileName'] ?? item['filename'] ?? '') as String;
        final isDir = ((item['dir'] ?? item['Size'] ?? 0) is bool)
            ? (item['dir'] as bool)
            : ((item['PdirID'] ?? 0) != 0);
        final fileId = (item['FileId'] ?? item['fileId'] ?? item['PdirID'])?.toString();
        final path = pathPrefix.isEmpty ? name : '$pathPrefix/$name';
        if (isDir && fileId != null) {
          final children = await _listAll(ctx, shareKey, passcode,
              pdirFileId: fileId, pathPrefix: path);
          out.add(FileNode(
              name: name, path: path, isDirectory: true, children: children));
        } else {
          out.add(FileNode(
            name: name,
            path: path,
            isDirectory: false,
            size: (item['Size'] as num?)?.toInt(),
            directUrl: 'pan123-file://$fileId',
          ));
        }
      }
      final total = ((data['Total'] ?? 0) as num).toInt();
      if (out.length >= total) break;
      page++;
      if (page > 100) break; // 防御性上限
    }
    return out;
  }
}
