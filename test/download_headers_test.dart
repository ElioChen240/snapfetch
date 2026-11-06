import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/domain/parser.dart';

/// 下载请求头回归测试：网盘直链绑定登录 Cookie，缺了会被 CDN 拒。
void main() {
  group('ParseContext.downloadHeaders（下载请求必须携带的头）', () {
    PHttpResponse ok(String url) => PHttpResponse(
          statusCode: 200,
          body: '{}',
          finalUri: Uri.parse(url),
        );

    ParseContext ctx({
      Map<String, String> cookies = const {},
      Map<String, String> baseHeaders = const {},
    }) =>
        ParseContext(
          cookies: cookies,
          baseHeaders: baseHeaders,
          httpGet: (url, {headers, query}) async => ok(url),
          httpPost: (url, {jsonBody, headers, query}) async => ok(url),
          log: (_) {},
        );

    test('有 Cookie 时生成 Cookie 头（分号分隔）', () {
      final h = ctx(cookies: {'__pus': 'a', 'kps': 'b'}).downloadHeaders;
      expect(h['Cookie'], anyOf('__pus=a; kps=b', 'kps=b; __pus=a'));
    });

    test('带上 baseHeaders 里的 Referer', () {
      final h = ctx(
        cookies: {'x': '1'},
        baseHeaders: {'Referer': 'https://pan.quark.cn/'},
      ).downloadHeaders;
      expect(h['Referer'], 'https://pan.quark.cn/');
      expect(h['Cookie'], 'x=1');
    });

    test('无 Cookie 时不生成 Cookie 头（免登录平台）', () {
      final h = ctx().downloadHeaders;
      expect(h.containsKey('Cookie'), isFalse);
    });
  });
}
