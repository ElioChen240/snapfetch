import 'dart:convert';

import '../../domain/parser.dart';

/// 解析器公共工具：链接识别与参数提取。
///
/// 只做「事实性」的 URL/口令结构处理，不涉及任何平台私有代码。
class ParseUtils {
  ParseUtils._();

  /// 从任意文本中提取第一条 http(s) 链接（口令/整段文案场景）。
  static String? firstUrl(String input) {
    final m = RegExp(r'https?://[^\s，。,；;）)】\]]+').firstMatch(input);
    return m?.group(0);
  }

  /// 提取提取码：支持「提取码: xxxx」「密码 xxxx」「?pwd=xxxx」与 #/xxxx。
  static String? extractPasscode(String input) {
    for (final p in [
      RegExp(r'提取码[：:\s]*([0-9a-zA-Z]{4})'),
      RegExp(r'密码[：:\s]*([0-9a-zA-Z]{4})'),
      RegExp(r'[?&]pwd=([0-9a-zA-Z]{4})'),
      RegExp(r'#/?([0-9a-zA-Z]{4})\s*$'),
    ]) {
      final m = p.firstMatch(input);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static Map<String, String> jsonHeaders({String? referer}) => {
        'Accept': 'application/json, text/plain, */*',
        'Referer': ?referer,
      };

  /// 解析 JSON，失败抛 [ParseError]。
  static dynamic json(String body, {String platform = ''}) {
    try {
      return jsonDecode(body);
    } catch (_) {
      throw ParseError('$platform 响应不是有效 JSON');
    }
  }

  /// 平台接口 code != 0 时的错误归类。
  static ParseError classifyApiError(String platform, int? code, String msg) {
    if (msg.contains('提取码') || code == 41008 || code == 41034) {
      return ParseError('$platform: 提取码错误或缺失',
          kind: ParseErrorKind.needPasscode);
    }
    if (msg.contains('失效') || msg.contains('不存在')) {
      return ParseError('$platform: 分享已失效或不存在',
          kind: ParseErrorKind.notFound);
    }
    if (msg.contains('频繁') || msg.contains('风控') || code == 42909) {
      return ParseError('$platform: 触发风控/限流，请稍后再试',
          kind: ParseErrorKind.rateLimited);
    }
    return ParseError('$platform: $msg (code=$code)');
  }

  /// 断言接口成功（code == 0），否则抛归类后的 [ParseError]。
  static Map<String, dynamic> expectOk(
    dynamic json,
    String platform, {
    String codeKey = 'code',
    String msgKey = 'message',
  }) {
    final map = (json as Map).cast<String, dynamic>();
    final code = (map[codeKey] as num?)?.toInt();
    if (code != null && code != 0) {
      final msg = (map[msgKey] ?? '未知错误').toString();
      throw classifyApiError(platform, code, msg);
    }
    return map;
  }
}
