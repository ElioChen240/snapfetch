/// 应用元信息的**唯一 Dart 侧来源**。
///
/// ★ 为什么要有这个文件：版本号此前散在 pubspec / 侧边栏 / 设置页 / 安装包脚本
///   共 5 处，改一处漏四处，发出去的包里「关于」显示旧版本。
///   现在 UI 只读这里；`test/app_info_test.dart` 断言本文件与 pubspec.yaml
///   的 version 一致 —— 忘了同步，CI 直接红。
///   安装包版本由 `tools/build-installer.ps1` 从 pubspec 读出后用
///   `/DMyAppVersion=` 传给 Inno Setup，不再手改 .iss。
class AppInfo {
  /// 必须与 pubspec.yaml 的 `version:` 主版本号一致（有测试把关）。
  static const String version = '0.2.0';

  static const String nameZh = '闪取';
  static const String nameEn = 'SnapFetch';

  /// 侧边栏 / 关于对话框里的定位说明：独立实现、非官方。
  static const String tagline = '独立实现 · 非官方';

  /// 关于对话框正文。
  static const String licenseLine = '开源免费 · AGPL-3.0 License';

  static const String repoUrl = 'https://github.com/ElioChen240/snapfetch';

  static String get displayVersion => 'v$version';

  /// 侧边栏底部一行。
  static String get sidebarFooter => 'v$version · 独立非官方';

  const AppInfo._();
}
