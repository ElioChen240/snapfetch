import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/data/auth/credential_vault.dart';
import 'package:snapfetch/data/download/download_engine.dart';
import 'package:snapfetch/data/download/task_repository.dart';
import 'package:snapfetch/data/network/http_client.dart';
import 'package:snapfetch/data/parsers/quark.dart';
import 'package:snapfetch/domain/parser.dart';

/// M4 端到端闭环（真实 IO，普通 test 非 testWidgets）：
/// 登录凭证 → 解析分享（fixture）→ resolveDirectUrl 换真直链 → 引擎分片下载 → 落盘校验。
/// 对应 PRD §12 第 0 条验收：「链接 → 解析 → 直链 → 下载 → 本地文件」。
void main() {
  late HttpServer server;
  late Directory dir;
  final payload = List<int>.generate(2 << 20, (i) => (i * 7) % 256); // 2 MiB

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://${server.address.host}:${server.port}';
    // 一个服务器同时扮演：夸克 API（解析/取链）与文件直链下载
    server.listen((req) async {
      final resp = req.response;
      final path = req.uri.path;
      if (path == '/1/clouddrive/share/sharepage/token') {
        resp.add(utf8.encode(
            jsonEncode({'code': 0, 'data': {'stoken': 'STOKEN-E2E'}})));
      } else if (path == '/1/clouddrive/share/sharepage/detail') {
        resp.add(utf8.encode(jsonEncode({
          'code': 0,
          'data': {
            '_total': 1,
            'list': [
              {
                'file_name': 'e2e-movie.bin',
                'dir': false,
                'fid': 'FILE-FID-E2E',
                'share_fid_token': 'FID-E2E',
                'size': payload.length
              }
            ]
          }
        })));
      } else if (path == '/1/clouddrive/file/download') {
        // 官方端点；校验取链请求带了 Cookie（登录态）+ 分享参数
        if (req.headers.value('cookie') == null) {
          resp.statusCode = 401;
        } else {
          resp.add(utf8.encode(jsonEncode({
            'code': 0,
            // ★ 官方响应 data 是数组
            'data': [
              {'fid': 'FILE-FID-E2E', 'download_url': '$base/direct/e2e-movie.bin'}
            ]
          })));
        }
      } else if (path == '/direct/e2e-movie.bin') {
        // 直链下载：支持 Range（引擎会用）
        final range = req.headers.value('range');
        if (range != null && range.startsWith('bytes=')) {
          final p = range.substring(6).split('-');
          final s = int.parse(p[0]);
          final e = p[1].isEmpty ? payload.length - 1 : int.parse(p[1]);
          resp.statusCode = 206;
          resp.headers.set('content-length', '${e - s + 1}');
          resp.add(payload.sublist(s, e + 1));
        } else {
          resp.headers.set('content-length', '${payload.length}');
          resp.add(payload);
        }
      } else {
        resp.statusCode = 404;
      }
      await resp.close();
    });
    dir = await Directory.systemTemp.createTemp('sf_e2e');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('闭环：解析 → 直链 → 分片下载 → 落盘逐字节一致', () async {
    final base = 'http://${server.address.host}:${server.port}';

    // 1. 凭证入库（模拟用户已在账号页完成应用内登录）
    final vault = DpapiFileCredentialVault(File('${dir.path}/credentials.bin'));
    await vault.put(StoredCredential(
      id: 'c1',
      platformId: 'quark',
      label: '主号',
      cookies: {'__pus': 'v1', 'kps': 'v2'},
      createdAt: DateTime.now(),
    ));

    // 2. 组装解析上下文（SnapHttp 与生产同一套 Cookie 注入逻辑）
    final creds = await vault.list();
    final ctx = SnapHttp.context(
      cookies: creds.first.cookies,
      referer: 'https://pan.quark.cn/',
      log: (_) {},
    );

    // 3. 解析分享 → 文件树
    //    （把 quark API 域名重写到 fixture：解析器 base 常量不可注入，
    //     这里直接用本地地址构造输入会被域名识别拦住 —— 因此用 Dio 拦截器
    //     级别的重写：把生产域名映射到 fixture）
    final parser = QuarkParser();
    expect(parser.matches('https://pan.quark.cn/s/e2e123'), isTrue);
    final rewrittenCtx = _rewrite(ctx, {
      'https://drive-pc.quark.cn': base,
    });

    final result = await parser.parse(
        'https://pan.quark.cn/s/e2e123 提取码: abcd', rewrittenCtx);
    final tree = result as FileTreeResult;
    final file = tree.roots.single;
    expect(file.name, 'e2e-movie.bin');

    // 4. 按需换直链（应带上登录 Cookie → fixture 校验）
    final directUrl = await parser.resolveDirectUrl(rewrittenCtx, file);
    expect(directUrl, startsWith('$base/direct/'));

    // 5. 引擎分片下载到磁盘
    final engine = RangeDownloadEngine(
      dio: Dio(),
      repository: JsonTaskRepository(File('${dir.path}/tasks.json')),
      concurrency: 4,
    );
    final savePath = '${dir.path}${Platform.pathSeparator}e2e-movie.bin';
    final task = DownloadTask(
      id: 'e2e',
      url: directUrl,
      savePath: savePath,
      headers: const {'Referer': 'https://pan.quark.cn/'},
      totalBytes: 0,
      chunks: const [],
    );
    final done = engine.progressStream.firstWhere(
      (t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed,
    );
    await engine.enqueue(task);
    final finished = await done.timeout(const Duration(seconds: 30));
    expect(finished.status, TaskStatus.completed);

    // 6. 落盘逐字节校验（核心红线 C2/C3 的自动化验收）
    final bytes = await File(savePath).readAsBytes();
    expect(bytes, orderedEquals(payload));
    await engine.dispose();
  });
}

/// 把指定生产域名重写到 fixture 服务器的解析上下文（仅测试用）。
ParseContext _rewrite(ParseContext inner, Map<String, String> mapping) {
  String map(String url) {
    for (final e in mapping.entries) {
      if (url.startsWith(e.key)) return url.replaceFirst(e.key, e.value);
    }
    return url;
  }

  return ParseContext(
    cookies: inner.cookies,
    baseHeaders: inner.baseHeaders,
    log: inner.log,
    httpGet: (url, {headers, query}) =>
        inner.httpGet(map(url), headers: headers, query: query),
    httpPost: (url, {jsonBody, headers, query}) =>
        inner.httpPost(map(url), jsonBody: jsonBody, headers: headers, query: query),
  );
}
