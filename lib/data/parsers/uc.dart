import '../../domain/parser.dart';
import 'common.dart';
import 'quark_signer.dart';

/// UC 网盘解析 —— 与夸克同源（阿里系），接口结构同族、域名不同。
/// 独立实现（不继承 QuarkParser），签名细节同样待真实链接验证。
class UcParser extends LinkParser {
  const UcParser();

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
    final files = await _listAll(ctx, shareId, stoken, pdirFid: '0', pathPrefix: '');
    return FileTreeResult(shareTitle: shareId, roots: files);
  }

  Future<String> getDownloadUrl(
    ParseContext ctx, {
    required String shareFidToken,
    required int timestampSec,
  }) async {
    final res = await _signedPost(ctx, '$_base/share/sharepage/download',
        jsonBody: {
          'fids': [shareFidToken],
        },
        timestampSec: timestampSec);
    final map =
        ParseUtils.expectOk(ParseUtils.json(res.body, platform: displayName), displayName);
    final url = ((map['data'] ?? const {}) as Map)['download_url'] as String?;
    if (url == null || url.isEmpty) {
      throw ParseError('UC: 未取得直链（可能需要登录或Cookie失效）',
          kind: ParseErrorKind.credentialExpired);
    }
    return url;
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
    return getDownloadUrl(ctx,
        shareFidToken: url.substring(prefix.length),
        timestampSec: DateTime.now().millisecondsSinceEpoch ~/ 1000);
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
        final fid = (item['share_fid_token'] ?? item['fid'] ?? '') as String;
        final path = pathPrefix.isEmpty ? name : '$pathPrefix/$name';
        if (isDir) {
          final children = await _listAll(ctx, shareId, stoken,
              pdirFid: (item['fid'] ?? '') as String, pathPrefix: path);
          out.add(FileNode(
              name: name, path: path, isDirectory: true, children: children));
        } else {
          out.add(FileNode(
            name: name,
            path: path,
            isDirectory: false,
            size: (item['size'] as num?)?.toInt(),
            directUrl: 'uc-fid://$fid',
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
