import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/app_info.dart';

/// 版本号防漂移：pubspec 改了、代码没改（或反之）时，CI 必须红。
/// 此前版本串散在 5 处，发出去的包「关于」显示旧版本就是这么来的。
void main() {
  test('AppInfo.version 与 pubspec.yaml 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 必须有 version: 字段');
    final fromPubspec = m!.group(1)!.split('+').first;
    expect(AppInfo.version, fromPubspec,
        reason: '改版本只改 pubspec，然后同步 lib/core/app_info.dart');
  });

  test('安装包脚本的版本号可被命令行覆盖（不再是第二处真源）', () {
    final iss = File('installer/SnapFetch.iss').readAsStringSync();
    expect(iss, contains('#ifdef MyAppVersion'),
        reason: '必须支持 /DMyAppVersion= 注入，否则 .iss 里的版本会变成第二处真源');
    expect(RegExp(r'MyAppVersion\s+"[\d.]+"').hasMatch(iss), isFalse,
        reason: '不应把版本硬编码成 MyAppVersion 的默认值（默认值走 AppVersion）');
  });

  test('元信息字段非空（关于对话框与侧边栏依赖）', () {
    expect(AppInfo.nameZh, isNotEmpty);
    expect(AppInfo.nameEn, isNotEmpty);
    expect(AppInfo.tagline, isNotEmpty);
    expect(AppInfo.displayVersion, startsWith('v'));
    expect(AppInfo.repoUrl, startsWith('https://'),
        reason: '发布前必须填真实仓库地址，README/关于都要用');
  });
}
