import '../../domain/parser.dart';

/// 每平台的登录规则（PRD §6.6：规则可配置、可热修，不写死在核心里）。
///
/// 原则（PRD §2.1 红线 3）：免登录可解析的平台 **不得** 标记为 required，
/// 应用内登录只服务于确实需要凭证的平台。
class LoginRule {
  final String platformId;
  final String displayName;

  /// 平台类型：网盘（登录后可浏览自己账号文件）/ 视频（只需登录态解析）。
  final PlatformKind kind;

  /// 打开的登录页地址（平台官方域名，禁止注入第三方脚本）。
  final String loginUrl;

  /// 捕获 Cookie 时按此 URL 查询（CDP Network.getCookies 按 URL 匹配）。
  final String cookieUrl;

  /// 命中这些 Cookie 名即认为登录成功（平台长期会调整，可热修此表）。
  final List<String> successCookieNames;

  /// 是否必须登录才能使用该平台解析。
  final bool required;

  /// 登录态不在 Cookie 里的平台（如 123 云盘的 token 存 localStorage）：
  /// 填入取值用的 JS 表达式，登录完成时执行一次。
  final String? tokenJsExpression;

  /// token 存入 [ParseContext.cookies] 时使用的键名。
  final String? tokenKey;

  const LoginRule({
    required this.platformId,
    required this.displayName,
    this.kind = PlatformKind.netdisk,
    required this.loginUrl,
    required this.cookieUrl,
    this.successCookieNames = const [],
    this.required = true,
    this.tokenJsExpression,
    this.tokenKey,
  });

  /// 从捕获到的 cookie（含 token）中判定是否登录成功。
  bool isLoginSuccess(Map<String, String> cookies) {
    // localStorage token 优先：有 token 就算登录成功（如 123 云盘）
    final tk = tokenKey;
    if (tk != null && (cookies[tk]?.isNotEmpty ?? false)) return true;
    if (successCookieNames.isEmpty) return cookies.isNotEmpty;
    return successCookieNames.any((name) =>
        cookies.keys.any((k) => k.toLowerCase() == name.toLowerCase()));
  }
}

/// 三家网盘的登录规则（PRD §10 D1）。
/// 网盘分享解析都要登录态才能取直链，故 required 全为 true；
/// 123 云盘例外：分享列表免登录可取，登录后才能取链/浏览自己的文件。
/// Cookie 规则随平台改版更新 —— 只改这里，不动核心。
const Map<String, LoginRule> kLoginRules = {
  'quark': LoginRule(
    platformId: 'quark',
    displayName: '夸克网盘',
    loginUrl: 'https://pan.quark.cn/',
    cookieUrl: 'https://pan.quark.cn/',
    successCookieNames: ['__pus', '__kp', 'kps'],
    required: true,
  ),
  'uc': LoginRule(
    platformId: 'uc',
    displayName: 'UC 网盘',
    loginUrl: 'https://drive.uc.cn/',
    cookieUrl: 'https://drive.uc.cn/',
    successCookieNames: ['__pus', '__kp', 'kps'],
    required: true,
  ),
  'pan123': LoginRule(
    platformId: 'pan123',
    displayName: '123 云盘',
    loginUrl: 'https://yun.123pan.cn/',
    cookieUrl: 'https://yun.123pan.cn/',
    successCookieNames: [],
    required: false, // 分享列表免登录；登录后才能取下载直链 / 浏览自己文件
    // ★ 123 的登录态是 localStorage 里的 authorToken，不是 Cookie
    tokenJsExpression: "localStorage.getItem('authorToken')",
    tokenKey: '__pan123_token',
  ),
};
