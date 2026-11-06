import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/data/parsers/common.dart';
import 'package:snapfetch/data/parsers/douyin.dart';
import 'package:snapfetch/data/parsers/pan123.dart';
import 'package:snapfetch/data/parsers/quark.dart';
import 'package:snapfetch/data/parsers/registry.dart';
import 'package:snapfetch/data/parsers/uc.dart';
import 'package:snapfetch/data/parsers/xiaohongshu.dart';
import 'package:snapfetch/domain/parser.dart';

/// 本地 fixture 服务器：按路径返回预置响应，并记录收到的请求（验证头/参数构造）。
class _FixtureServer {
  late HttpServer _server;
  late String base;
  final Map<String, _Fixture Function(HttpRequest req)> routes;
  final List<HttpRequest> seen = [];

  _FixtureServer(Map<String, _Fixture> staticRoutes)
      : routes = staticRoutes.map((k, v) => MapEntry(k, (_) => v));

  _FixtureServer.dynamic(this.routes);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${_server.address.host}:${_server.port}';
    _server.listen((req) async {
      seen.add(req);
      final f = routes[_matchKey(req.uri.path, req.method)]?.call(req);
      if (f == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (f.redirectTo != null) {
        req.response.statusCode = 302;
        req.response.headers.set('location', f.redirectTo!);
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType(f.mime.split('/')[0], f.mime.split('/')[1]);
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

class _Fixture {
  final String body;
  final String mime;
  final String? redirectTo;
  const _Fixture(this.body, {this.mime = 'application/json', this.redirectTo});
}

/// 用 fixture 服务器组装 ParseContext（走真实 HTTP，而非 mock 函数）。
ParseContext _ctx(_FixtureServer s, {Map<String, String> cookies = const {}}) {
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
  );
}

void main() {
  group('链接识别与提取（ParseUtils）', () {
    final registry = buildDefaultRegistry();

    test('5 家平台注册且路由正确', () {
      expect(registry.all.length, 5);
      expect(registry.route('https://pan.quark.cn/s/abc123#/提取码 abcd')!.id, 'quark');
      expect(registry.route('https://drive.uc.cn/s/pqrs')!.id, 'uc');
      expect(registry.route('https://www.123pan.com/s/kEf9-abc.html')!.id, 'pan123');
      expect(registry.route('7.5 复制打开抖音 https://v.douyin.com/iAbcD/')!.id, 'douyin');
      expect(registry.route('https://www.xiaohongshu.com/explore/0123456789abcdef01234567')!.id,
          'xiaohongshu');
      expect(registry.route('https://example.com/nothing'), isNull);
    });

    test('提取码识别（中文文案/参数/锚点）', () {
      expect(ParseUtils.extractPasscode('链接 https://x.com/s/a 提取码：7g2k'), '7g2k');
      expect(ParseUtils.extractPasscode('https://x.com/s/a?pwd=9z8y'), '9z8y');
      expect(ParseUtils.extractPasscode('https://pan.quark.cn/s/abc123#/b1Z2'), 'b1Z2');
      expect(ParseUtils.extractPasscode('没有提取码'), isNull);
    });
  });

  group('抖音解析器', () {
    late _FixtureServer s;
    setUp(() async {
      s = _FixtureServer({
        'GET /iAbcD/': const _Fixture('', redirectTo: '/share/video/7301234567890123456'),
        'GET /share/video/7301234567890123456': _Fixture(
          '<script>window._ROUTER_DATA = ${jsonEncode(_douyinRouter())}</script>',
          mime: 'text/html',
        ),
      });
      await s.start();
    });
    tearDown(() => s.stop());

    test('短链跟随 → 视频直链（无水印替换）', () async {
      final result = await const DouyinParser()
          .parse('7.5 复制打开抖音 https://v.douyin.com/iAbcD/', _ctx(s));
      expect(result, isA<MediaSetResult>());
      final media = result as MediaSetResult;
      expect(media.items.first.kind, MediaKind.video);
      expect(media.items.first.url, contains('aweme/v1/play/'),
          reason: 'playwm 应替换为 play 去水印');
      expect(media.items.first.url, isNot(contains('playwm')));
      expect(media.author, '测试作者');
    });

    test('图文混合作品：视频 + 图集都输出', () async {
      final result = await const DouyinParser()
          .parse('https://v.douyin.com/iAbcD/', _ctx(s));
      final media = result as MediaSetResult;
      expect(media.items.length, 3, reason: '1 视频 + 2 图');
      expect(media.items[0].kind, MediaKind.video);
      expect(media.items[1].kind, MediaKind.image);
      expect(media.items[2].url, contains('2.jpeg'));
    });
  });

  group('小红书解析器', () {
    late _FixtureServer s;
    setUp(() async {
      s = _FixtureServer({
        'GET /explore/0123456789abcdef01234567': _Fixture(_xhsHtml(), mime: 'text/html'),
      });
      await s.start();
    });
    tearDown(() => s.stop());

    test('页面状态 JSON → 图集直链（取最大变体）', () async {
      final result = await const XiaohongshuParser()
          .parse('https://www.xiaohongshu.com/explore/0123456789abcdef01234567', _ctx(s));
      final media = result as MediaSetResult;
      expect(media.title, '测试笔记标题');
      expect(media.items.length, 2);
      expect(media.items.first.url, contains('sns-img-quality'));
    });

    test('视频笔记给出 h264 流', () async {
      final html = _xhsHtml(withVideo: true);
      final s2 = _FixtureServer({
        'GET /explore/0123456789abcdef01234567': _Fixture(html, mime: 'text/html'),
      });
      await s2.start();
      final result = await const XiaohongshuParser()
          .parse('https://www.xiaohongshu.com/explore/0123456789abcdef01234567', _ctx(s2));
      final media = result as MediaSetResult;
      expect(media.items.any((m) => m.kind == MediaKind.video && m.qualityLabel == 'h264'),
          isTrue);
      await s2.stop();
    });
  });

  group('123 云盘解析器', () {
    late _FixtureServer s;
    setUp(() async {
      s = _FixtureServer.dynamic({
        'POST /api/share/info': (_) => _Fixture(jsonEncode({
              'code': 0,
              'data': {'ShareKey': 'kEf9-abc', 'ShareTitle': '我的分享', 'RootDirID': 100}
            })),
        'GET /api/share/list': (req) {
          // 子目录返回空（防递归 fixture）；根目录返回 2 项
          final inSub = req.uri.queryParameters['parentFileId'] != '0'
              && req.uri.queryParameters['parentFileId'] != '100';
          return _Fixture(jsonEncode({
            'code': 0,
            'data': {
              'Total': inSub ? 0 : 2,
              'InfoList': inSub
                  ? []
                  : [
                      {'FileName': '目录A', 'PdirID': 0, 'FileId': 201, 'dir': true},
                      {'FileName': '文件1.zip', 'FileId': 202, 'Size': 1024},
                    ]
            }
          }));
        },
      });
      await s.start();
    });
    tearDown(() => s.stop());

    test('免登录解析：信息 + 文件树', () async {
      final result = await Pan123Parser()
          .parse('https://www.123pan.com/s/kEf9-abc.html 提取码: abcd', _ctx(s));
      final tree = result as FileTreeResult;
      expect(tree.shareTitle, '我的分享');
      expect(tree.roots.length, 2);
      expect(tree.roots[0].isDirectory, isTrue);
      expect(tree.roots[1].name, '文件1.zip');
      expect(tree.roots[1].size, 1024);
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
  });
}

Map<String, dynamic> _douyinRouter() => {
      'loaderData': {
        'video_(7301234567890123456)/page': {
          'videoInfoRes': {
            'item_list': [
              {
                'aweme_id': '7301234567890123456',
                'desc': '测试视频',
                'author': {'nickname': '测试作者'},
                'video': {
                  'play_addr': {
                    'url_list': ['https://aweme.snssdk.com/aweme/v1/playwm/?video_id=v1']
                  }
                },
                'images': [
                  {
                    'url_list': ['https://p.douyinpic.com/img/1.jpeg']
                  },
                  {
                    'url_list': ['https://p.douyinpic.com/img/2.jpeg']
                  },
                ],
              }
            ]
          }
        }
      }
    };

String _xhsHtml({bool withVideo = false}) {
  final note = {
    'title': '测试笔记标题',
    'user': {'nickname': '小测'},
    'imageList': [
      {
        'infoList': [
          {'url': 'https://sns-img-qc.xhscdn.com/a-small.jpg'},
          {'url': 'https://sns-img-quality.xhscdn.com/a-big.jpg'},
        ]
      },
      {
        'infoList': [
          {'url': 'https://sns-img-quality.xhscdn.com/b-big.jpg'},
        ]
      },
    ],
    if (withVideo)
      'video': {
        'media': {
          'stream': {
            'h264': [
              {'masterUrl': 'https://sns-video.xhscdn.com/v.mp4'}
            ],
            'h265': [
              {'masterUrl': 'https://sns-video.xhscdn.com/v265.mp4'}
            ],
          }
        }
      },
  };
  final state = {
    'note': {
      'noteDetailMap': {
        '0123456789abcdef01234567': {'note': note}
      }
    }
  };
  // 真实页面的 JSON 内含裸 undefined（JS 字面量），解析前须清洗为 null
  final raw = jsonEncode(state).replaceFirst('{', '{"unknownField":undefined,');
  return '<script>window.__INITIAL_STATE__=$raw</script>';
}
