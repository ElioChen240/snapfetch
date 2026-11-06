import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/data/parsers/common.dart';
import 'package:snapfetch/data/parsers/pan123.dart';
import 'package:snapfetch/data/parsers/quark.dart';
import 'package:snapfetch/data/parsers/registry.dart';
import 'package:snapfetch/data/parsers/uc.dart';
import 'package:snapfetch/domain/parser.dart';

/// 本地 fixture 服务器：按路径返回预置响应，并记录收到的请求（验证头/参数构造）。
class _FixtureServer {
  late HttpServer _server;
  late String base;
  final Map<String, _Fixture Function(HttpRequest req)> routes;
  final List<HttpRequest> seen = [];
  final List<String> seenBodies = [];

  _FixtureServer(Map<String, _Fixture> staticRoutes)
      : routes = staticRoutes.map((k, v) => MapEntry(k, (_) => v));

  _FixtureServer.dynamic(this.routes);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${_server.address.host}:${_server.port}';
    _server.listen((req) async {
      seen.add(req);
      // POST 请求体先读出来（断言「取链时提交了哪些 fid」靠它，不能只看 URL）
      if (req.method == 'POST') {
        seenBodies.add(await utf8.decoder.bind(req).join());
      }
      final f = routes[_matchKey(req.uri.path, req.method)]?.call(req);
      if (f == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.add(utf8.encode(f.body));
      await req.response.close();
    });
  }

  String _matchKey(String path, String method) => '$method $path';

  /// 把任意外部 URL 重写到 fixture 端口（保留 path/query）。
  Uri mapUrl(String url) {
    final u = Uri.parse(url);
    return u.replace(scheme: 'http', host: _server.address.host, port: _server.port);
  }

  Future<void> stop() => _server.close(force: true);
}

/// 一条固定响应（网盘接口全是 JSON，故不再保留 mime/redirect 分支 ——
/// 那两个变体只被已下架的抖音/小红书 fixture 用过）。
class _Fixture {
  final String body;
  const _Fixture(this.body);
}

/// 用 fixture 服务器组装 ParseContext（走真实 HTTP，而非 mock 函数）。
ParseContext _ctx(_FixtureServer s,
    {Map<String, String> cookies = const {}, bool noTransferDownload = true}) {
  Future<PHttpResponse> run(RequestOptions opts) async {
    final c = HttpClient();
    final req = await c.openUrl(opts.method, Uri.parse(opts.path));
    opts.headers.forEach((k, v) => req.headers.set(k, v));
    // 与 SnapHttp.context 契约一致：上下文负责注入 Cookie
    if (cookies.isNotEmpty && req.headers.value('cookie') == null) {
      req.headers.set('Cookie',
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    if (opts.data != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(opts.data)));
    }
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final hdrs = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) hdrs[name.toLowerCase()] = values.first;
    });
    return PHttpResponse(
      statusCode: resp.statusCode,
      body: body,
      finalUri:
          resp.redirects.isNotEmpty ? resp.redirects.last.location : req.uri,
      headers: hdrs,
    );
  }

  return ParseContext(
    cookies: cookies,
    baseHeaders: const {},
    httpGet: (url, {headers, query}) async {
      // 重写到 fixture；未显式给 query 时保留原 URL 的 query（签名参数在里面）
      final mapped = s.mapUrl(url);
      final u = query == null
          ? mapped
          : mapped.replace(queryParameters: query);
      return run(RequestOptions(path: u.toString(), method: 'GET', headers: headers ?? {}));
    },
    httpPost: (url, {jsonBody, headers, query}) async {
      final mapped = s.mapUrl(url);
      final u = query == null ? mapped : mapped.replace(queryParameters: query);
      return run(RequestOptions(
          path: u.toString(), method: 'POST', data: jsonBody, headers: headers ?? {}));
    },
    log: (_) {},
    noTransferDownload: noTransferDownload,
  );
}

void main() {
  group('链接识别与提取（ParseUtils）', () {
    final registry = buildDefaultRegistry();

    test('3 家网盘注册且路由正确', () {
      expect(registry.all.length, 3);
      expect(registry.route('https://pan.quark.cn/s/abc123#/提取码 abcd')!.id, 'quark');
      expect(registry.route('https://drive.uc.cn/s/pqrs')!.id, 'uc');
      expect(registry.route('https://www.123pan.com/s/kEf9-abc.html')!.id, 'pan123');
      expect(registry.route('https://example.com/nothing'), isNull);
    });

    test('已下架的视频平台不再路由（避免用户以为还能解析）', () {
      expect(registry.route('7.5 复制打开抖音 https://v.douyin.com/iAbcD/'), isNull);
      expect(
          registry.route(
              'https://www.xiaohongshu.com/explore/0123456789abcdef01234567'),
          isNull);
    });

    test('提取码识别（中文文案/参数/锚点）', () {
      expect(ParseUtils.extractPasscode('链接 https://x.com/s/a 提取码：7g2k'), '7g2k');
      expect(ParseUtils.extractPasscode('https://x.com/s/a?pwd=9z8y'), '9z8y');
      expect(ParseUtils.extractPasscode('https://pan.quark.cn/s/abc123#/b1Z2'), 'b1Z2');
      expect(ParseUtils.extractPasscode('没有提取码'), isNull);
    });
  });

  group('123 云盘解析器', () {
    late _FixtureServer s;
    setUp(() async {
      // 官方端点：GET /b/api/share/get（免登录，UA=Dart）
      s = _FixtureServer.dynamic({
        'GET /b/api/share/get': (req) {
          final inSub = (req.uri.queryParameters['ParentFileId'] ?? '0') != '0';
          return _Fixture(jsonEncode({
            'code': 0,
            'data': {
              'Expired': false,
              'Next': '-1',
              'InfoList': inSub
                  ? []
                  : [
                      {
                        'FileName': '目录A',
                        'FileId': 201,
                        'Type': 1,
                        'ParentFileId': 0,
                      },
                      {
                        'FileName': '文件1.zip',
                        'FileId': 202,
                        'Type': 0,
                        'Size': 1024,
                        'S3KeyFlag': 'S3K',
                        'Etag': 'ETAG1',
                      },
                    ]
            }
          }));
        },
      });
      await s.start();
    });
    tearDown(() => s.stop());

    test('免登录解析：文件树与取链占位', () async {
      final result = await Pan123Parser()
          .parse('https://www.123pan.com/s/kEf9-abc.html 提取码: abcd', _ctx(s));
      final tree = result as FileTreeResult;
      expect(tree.roots.length, 2);
      expect(tree.roots[0].isDirectory, isTrue);
      expect(tree.roots[1].name, '文件1.zip');
      expect(tree.roots[1].size, 1024);
      // 取链占位：fid|s3KeyFlag|etag|size
      expect(tree.roots[1].directUrl, 'pan123-share://202|S3K|ETAG1|1024');
    });
  });

  group('夸克 / UC 解析器（签名+流程，fixture 驱动）', () {
    late _FixtureServer s;
    // 分享详情响应（夸克 /detail、UC /v2/detail 共用同一结构）
    _Fixture detailFixture(HttpRequest req) {
      final inSub = req.uri.queryParameters['pdir_fid'] != '0';
      return _Fixture(jsonEncode({
        'code': 0,
        'data': {
          '_total': inSub ? 0 : 2,
          'list': inSub
              ? []
              : [
                  {
                    'file_name': '电影.mp4',
                    'dir': false,
                    'fid': 'FILE-FID-1',
                    'share_fid_token': 'FID1',
                    'size': 999
                  },
                  {'file_name': '字幕', 'dir': true, 'fid': 'DIR1'},
                ]
        }
      }));
    }

    setUp(() async {
      s = _FixtureServer.dynamic({
        'POST /1/clouddrive/share/sharepage/token': (_) => _Fixture(jsonEncode({
              'code': 0,
              'data': {'stoken': 'STOKEN-X'}
            })),
        'GET /1/clouddrive/share/sharepage/detail': detailFixture,
        // ★ UC 官方端点是 /share/sharepage/v2/detail（带 v2），夸克无 v2
        'GET /1/clouddrive/share/sharepage/v2/detail': detailFixture,
        // 关闭「免转存下载」时走的转存链路
        'POST /1/clouddrive/share/sharepage/save': (_) => _Fixture(jsonEncode({
              'code': 0,
              'data': {'task_id': 'TASK-1'}
            })),
        'GET /1/clouddrive/task': (_) => _Fixture(jsonEncode({
              'code': 0,
              'data': {
                'status': 2,
                'save_as': {
                  'save_as_top_fids': ['SAVED-FID']
                }
              }
            })),
        'POST /1/clouddrive/file/download': (_) => _Fixture(jsonEncode({
              'code': 0,
              'data': [
                {'download_url': 'https://cdn.example/x.mp4'}
              ]
            })),
      });
      await s.start();
    });
    tearDown(() => s.stop());

    test('夸克：token → 文件树，请求带签名参数与 Referer', () async {
      final ctx = _ctx(s, cookies: {'__pus': 'v1', 'kps': 'v2'});
      final result =
          await QuarkParser().parse('https://pan.quark.cn/s/abc123 提取码: abcd', ctx);

      final tree = result as FileTreeResult;
      expect(tree.roots.length, 2);
      expect(tree.roots[0].directUrl, 'quark-fid://FILE-FID-1|FID1');
      expect(tree.roots[1].children, isNotNull, reason: '目录应递归');

      final req = s.seen.first;
      expect(req.headers.value('cookie'), contains('__pus=v1'),
          reason: '凭证须注入请求头');
      expect(req.uri.queryParameters['__t'], isNotEmpty);
      expect(req.uri.queryParameters['sign'], isNotEmpty);
      expect(req.uri.queryParameters['pr'], 'ucpro');
    });

    test('提取码错误 → needPasscode 分类', () async {
      final s2 = _FixtureServer({
        'POST /1/clouddrive/share/sharepage/token':
            _Fixture(jsonEncode({'code': 41008, 'message': '提取码错误'})),
      });
      await s2.start();
      try {
        await QuarkParser()
            .parse('https://pan.quark.cn/s/abc123 提取码: abcd', _ctx(s2));
        fail('应抛 ParseError');
      } on ParseError catch (e) {
        expect(e.kind, ParseErrorKind.needPasscode);
      } finally {
        await s2.stop();
      }
    });

    test('UC：同族流程（独立域名）', () async {
      final result = await UcParser().parse('https://drive.uc.cn/s/pqrs', _ctx(s));
      final tree = result as FileTreeResult;
      expect(tree.roots.length, 2);
      final req = s.seen.first;
      expect(req.headers.value('referer'), contains('drive.uc.cn'),
          reason: 'UC 请求应带其官方 Referer');
      expect(req.uri.queryParameters['pr'], 'UCBrowser');
    });

    test('免转存下载（默认开）：直接对分享文件取链，不碰 /save', () async {
      final parser = QuarkParser();
      final ctx = _ctx(s, cookies: {'__pus': 'v1'});
      final tree = await parser.parse('https://pan.quark.cn/s/abc123', ctx)
          as FileTreeResult;
      final url = await parser.resolveDirectUrl(ctx, tree.roots[0]);

      expect(url, 'https://cdn.example/x.mp4');
      expect(
        s.seenBodies.any((b) => b.contains('pwd_id') && b.contains('stoken')),
        isTrue,
        reason: '免转存取链要带分享上下文（pwd_id + stoken）',
      );
      expect(s.seen.map((r) => r.uri.path),
          isNot(contains('/1/clouddrive/share/sharepage/save')));
    });

    test('关闭免转存：先转存到自己网盘，再用保存后的 fid 取链', () async {
      final parser = QuarkParser();
      final ctx =
          _ctx(s, cookies: {'__pus': 'v1'}, noTransferDownload: false);
      final tree = await parser.parse('https://pan.quark.cn/s/abc123', ctx)
          as FileTreeResult;
      final url = await parser.resolveDirectUrl(ctx, tree.roots[0]);

      expect(url, 'https://cdn.example/x.mp4');
      final paths = s.seen.map((r) => r.uri.path).toList();
      expect(paths, contains('/1/clouddrive/share/sharepage/save'),
          reason: '关闭免转存应先调用转存接口');
      expect(paths, contains('/1/clouddrive/task'),
          reason: '转存是异步任务，必须轮询完成');
      expect(s.seenBodies.last, contains('SAVED-FID'),
          reason: '最终取链用的是转存后的 fid，而不是分享 fid');
    });

    test('关闭免转存但未登录 → credentialExpired（不能默默改走免转存）', () async {
      final parser = QuarkParser();
      final ctx = _ctx(s, noTransferDownload: false); // 无 Cookie
      final tree = await parser.parse('https://pan.quark.cn/s/abc123', ctx)
          as FileTreeResult;
      try {
        await parser.resolveDirectUrl(ctx, tree.roots[0]);
        fail('未登录时不该走转存');
      } on ParseError catch (e) {
        expect(e.kind, ParseErrorKind.credentialExpired);
      }
    });
  });
}

