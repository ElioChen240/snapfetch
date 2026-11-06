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

  const LoginRule({
    required this.platformId,
    required this.displayName,
    this.kind = PlatformKind.netdisk,
    required this.loginUrl,
    required this.cookieUrl,
    this.successCookieNames = const [],
    this.required = true,
  });

  /// 从捕获到的 cookie 中判定是否登录成功。
  bool isLoginSuccess(Map<String, String> cookies) {
    if (successCookieNames.isEmpty) return cookies.isNotEmpty;
    return successCookieNames.any((name) =>
        cookies.keys.any((k) => k.toLowerCase() == name.toLowerCase()));
  }
}

/// 首批平台登录规则（PRD §10 D1）。
/// 抖音 / 小红书免登录直出直链，required=false；
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
    loginUrl: 'https://www.123pan.com/',
    cookieUrl: 'https://www.123pan.com/',
    successCookieNames: ['passport', 'userInfo'],
    required: false, // 免登录分享可解析；登录后可取更大文件/更快直链
  ),
  'douyin': LoginRule(
    platformId: 'douyin',
    kind: PlatformKind.video,
    displayName: '抖音',
    loginUrl: 'https://www.douyin.com/',
    cookieUrl: 'https://www.douyin.com/',
    successCookieNames: [],
    required: false, // 免登录直出直链（PRD §5 第 3 项）
  ),
  'xiaohongshu': LoginRule(
    platformId: 'xiaohongshu',
    kind: PlatformKind.video,
    displayName: '小红书',
    loginUrl: 'https://www.xiaohongshu.com/',
    cookieUrl: 'https://www.xiaohongshu.com/',
    successCookieNames: [],
    required: false, // 免登录直出直链 + 图集
  ),
};
