import 'dart:convert';

/// 夸克/UC 系（阿里系 UC 浏览器同源）接口参数签名。
///
/// ⚠️ 事实性说明：`sign` 是社区广泛记录的 **DJB2 变体哈希**（魔数 5381），
/// 拼接格式为公开流传的协议行为；本实现为独立编写。
/// 平台随时可能调整拼接细节 —— 签名失败时**只改本文件**（PRD §6.6「规则可热修」）。
/// **必须用真实链接实测校验**（M3 验收项）。
class QuarkSigner {
  QuarkSigner._();

  /// 对请求 url + 可选 JSON body 计算 sign，并返回应附加的 query 参数
  /// （`__t` 时间戳秒、`__dt` 偏移、`sign`）。
  static Map<String, String> signParams(
    Uri url, {
    Map<String, dynamic>? jsonBody,
    required int timestampSec,
    int dt = 0,
  }) {
    // 1. 取 path 与 query：剔除 __t/__dt 本身，其余参数按 key 排序
    final params = <String>[];
    url.queryParameters.forEach((k, v) {
      if (k == '__t' || k == '__dt' || k == 'sign') return;
      params.add('$k=$v');
    });
    params.sort();

    // 2. 拼接待签字符串：path?sortedQuery + | + body
    final sb = StringBuffer(url.path);
    if (params.isNotEmpty) sb.write('?${params.join('&')}');
    if (jsonBody != null && jsonBody.isNotEmpty) {
      sb.write('|${jsonEncode(jsonBody)}');
    }
    sb.write('|$dt');

    // 3. DJB2 变体：hash = ((hash << 5) + hash + code) & 0xFFFFFFFF，取有符号 int 后转字符串
    var hash = 5381;
    for (final cu in sb.toString().codeUnits) {
      // 模拟 JS 的 charCodeAt（UTF-16 码元），与社区实现保持行为一致
      hash = _imul(hash, 33) + cu;
      hash = hash & 0xFFFFFFFF;
      if (hash > 0x7FFFFFFF) hash -= 0x100000000; // 转 JS 风格有符号 32 位
    }

    return {
      '__t': '$timestampSec',
      '__dt': '$dt',
      'sign': '$hash',
    };
  }

  /// JS Math.imul 等价（32 位乘法），保证与社区算法行为一致。
  static int _imul(int a, int b) {
    final ah = (a >> 16) & 0xFFFF;
    final al = a & 0xFFFF;
    final bh = (b >> 16) & 0xFFFF;
    final bl = b & 0xFFFF;
    var r = al * bl + (((ah * bl + al * bh) & 0xFFFF) << 16);
    r = r & 0xFFFFFFFF;
    if (r > 0x7FFFFFFF) r -= 0x100000000;
    return r;
  }
}
