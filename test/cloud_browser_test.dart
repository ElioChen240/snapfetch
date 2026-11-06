import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/data/network/http_client.dart';
import 'package:snapfetch/data/parsers/quark.dart';
import 'package:snapfetch/domain/parser.dart';

/// 云盘浏览（CloudBrowser）测试：验证「浏览自己账号文件」的请求构造与响应解析。
void main() {
  late HttpServer server;
  late String base;
  final seen = <Uri>[];

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      seen.add(req.uri);
      final resp = req.response;
      final path = req.uri.path;
      if (path == '/1/clouddrive/file/sort') {
        final pdir = req.uri.queryParameters['pdir_fid'] ?? '0';
        final inSub = pdir != '0';
        resp.add(utf8.encode(jsonEncode({
          'code': 0,
          'data': {
            '_total': inSub ? 1 : 2,
            'list': inSub
                ? [
                    {'fid': 'F3', 'file_name': 'inside.txt', 'dir': false, 'size': 10}
                  ]
                : [
                    {'fid': 'D1', 'file_name': '视频', 'dir': true},
                    {'fid': 'F1', 'file_name': '电影.mp4', 'dir': false, 'size': 1234},
                  ]
          }
        })));
      } else if (path == '/1/clouddrive/file/download') {
        resp.add(utf8.encode(jsonEncode({
          'code': 0,
          // 与官方一致：data 是数组
          'data': [
            {'fid': 'F1', 'download_url': 'https://dl.quark.cn/x?sig=abc'}
          ]
        })));
      } else if (path == '/1/clouddrive/member') {
        resp.add(utf8.encode(jsonEncode({
          'code': 0,
          'data': {'use_capacity': 100, 'total_capacity': 1000}
        })));
      } else if (path == '/account/info') {
        resp.add(utf8.encode(
            jsonEncode({'success': true, 'data': {'nickname': '测试昵称'}})));
      } else {
        resp.statusCode = 404;
      }
      await resp.close();
    });
  });

  tearDown(() => server.close(force: true));

  ParseContext ctx() {
    // 把生产域名重写到本地 fixture
    ParseContext inner = SnapHttp.context(
      cookies: {'__pus': 'v'},
      referer: 'https://pan.quark.cn/',
      log: (_) {},
    );
    String map(String u) => u.replaceFirst('https://drive-pc.quark.cn', base)
        .replaceFirst('https://pan.quark.cn', base);
    return ParseContext(
      cookies: inner.cookies,
      baseHeaders: inner.baseHeaders,
      log: inner.log,
      httpGet: (u, {headers, query}) => inner.httpGet(map(u), headers: headers, query: query),
      httpPost: (u, {jsonBody, headers, query}) =>
          inner.httpPost(map(u), jsonBody: jsonBody, headers: headers, query: query),
    );
  }

  test('CloudBrowser 接口：夸克已实现', () {
    final p = QuarkParser();
    expect(p, isA<CloudBrowser>());
  });

  test('listMyFiles：根目录返回文件夹+文件，带 Cookie 与必要参数', () async {
    final p = QuarkParser();
    final files = await p.listMyFiles(ctx());

    expect(files.length, 2);
    expect(files[0].isDirectory, isTrue);
    expect(files[0].name, '视频');
    expect(files[0].path, 'D1', reason: '云盘内用 fid 作为唯一标识');
    expect(files[1].name, '电影.mp4');
    expect(files[1].size, 1234);
    expect(files[1].directUrl, 'quark-cloud-fid://F1');

    final req = seen.first;
    expect(req.queryParameters['pdir_fid'], '0');
    expect(req.queryParameters['_size'], '100');
    expect(req.queryParameters['_fetch_total'], '1');
    expect(req.queryParameters['pr'], 'ucpro');
  });

  test('listMyFiles：子目录用 parentId 作为 pdir_fid', () async {
    final p = QuarkParser();
    final files = await p.listMyFiles(ctx(), parentId: 'D1');
    expect(files.single.name, 'inside.txt');
    expect(seen.last.queryParameters['pdir_fid'], 'D1');
  });

  test('getMyFileDownloadUrl：从 fid 换直链', () async {
    final p = QuarkParser();
    final node = FileNode(
      name: '电影.mp4',
      path: 'F1',
      isDirectory: false,
      directUrl: 'quark-cloud-fid://F1',
    );
    final url = await p.getMyFileDownloadUrl(ctx(), node);
    expect(url, startsWith('https://dl.quark.cn/'));
  });

  test('fetchNickname / fetchQuota', () async {
    final p = QuarkParser();
    expect(await p.fetchNickname(ctx()), '测试昵称');
    final q = await p.fetchQuota(ctx());
    expect(q, isNotNull);
    expect(q!.used, 100);
    expect(q.total, 1000);
  });

  test('未登录（接口报错）时抛 ParseError', () async {
    final failServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    failServer.listen((req) async {
      req.response.add(utf8.encode(jsonEncode({'code': 31001, 'message': '未登录'})));
      await req.response.close();
    });
    final fb = 'http://${failServer.address.host}:${failServer.port}';
    final inner = SnapHttp.context(cookies: const {}, log: (_) {});
    final c = ParseContext(
      httpGet: (u, {headers, query}) => inner.httpGet(
          u.replaceFirst('https://drive-pc.quark.cn', fb), headers: headers, query: query),
      httpPost: (u, {jsonBody, headers, query}) => inner.httpPost(
          u.replaceFirst('https://drive-pc.quark.cn', fb),
          jsonBody: jsonBody, headers: headers, query: query),
      log: (_) {},
    );
    await expectLater(
      QuarkParser().listMyFiles(c),
      throwsA(isA<ParseError>()),
    );
    await failServer.close(force: true);
  });
}
