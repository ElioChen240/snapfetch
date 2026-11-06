import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sf_settings');
    file = File('${dir.path}${Platform.pathSeparator}settings.json');
  });
  tearDown(() async => dir.delete(recursive: true));

  test('默认值：免转存开、并发 8、主题跟随系统', () async {
    final s = JsonAppSettings(file);
    await s.warm();
    expect(s.noTransferDownload, isTrue,
        reason: '默认免转存：不把用户网盘塞满（与手机版一致）');
    expect(s.concurrency, 8);
    expect(s.themeMode, ThemeMode.system);
  });

  test('免转存开关可持久化（重启后保持）', () async {
    final s1 = JsonAppSettings(file);
    await s1.warm();
    await s1.setNoTransferDownload(false);
    expect(s1.noTransferDownload, isFalse);

    final s2 = JsonAppSettings(file); // 新实例 = 应用重启
    await s2.warm();
    expect(s2.noTransferDownload, isFalse);
  });

  test('旧版 settings.json（没有该键）不报错，按默认开处理', () async {
    await file.writeAsString('{"download_dir":"D:\\\\x","concurrency":16}');
    final s = JsonAppSettings(file);
    await s.warm();
    expect(s.noTransferDownload, isTrue);
    expect(s.concurrency, 16);
  });

  test('写盘失败时内存生效并标记 saveFailed（界面据此提示）', () async {
    // 父路径是个普通文件 → 目录建不出来，写入必然失败
    final blocker = File('${dir.path}${Platform.pathSeparator}blocker')
      ..createSync();
    final bad = JsonAppSettings(
        File('${blocker.path}${Platform.pathSeparator}nested${Platform.pathSeparator}settings.json'));
    await bad.warm();
    await bad.setNoTransferDownload(false);
    expect(bad.noTransferDownload, isFalse, reason: '本次会话应已生效');
    expect(bad.saveFailed, isTrue);
  });
}
