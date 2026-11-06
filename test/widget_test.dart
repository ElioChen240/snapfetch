import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:snapfetch/core/settings.dart';
import 'package:snapfetch/data/auth/credential_vault.dart';
import 'package:snapfetch/data/download/task_repository.dart';
import 'package:snapfetch/data/download/download_engine.dart';
import 'package:snapfetch/data/network/http_client.dart';
import 'package:snapfetch/domain/parser.dart';
import 'package:snapfetch/main.dart';
import 'package:snapfetch/providers.dart';

/// 测试用内存实现（widget 测试的 FakeAsync zone 里真实文件 IO 会永久挂起，
/// 数据层必须全部 override 为内存版；真实 IO 闭环由 parsers/download 的普通 test 覆盖）。

class _MemorySettings extends AppSettings {
  @override
  bool get saveFailed => false;
  @override
  String get downloadDir => Directory.systemTemp.path;
  @override
  int get concurrency => 8;
  @override
  ThemeMode get themeMode => ThemeMode.system;
  @override
  Future<void> setDownloadDir(String dir) async {}
  @override
  Future<void> setConcurrency(int v) async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
}

class _MemoryVault implements CredentialVault {
  final list0 = <StoredCredential>[];
  @override
  Future<List<StoredCredential>> list() async => list0;
  @override
  Future<void> put(StoredCredential c) async => list0.add(c);
  @override
  Future<void> remove(String id) async => list0.removeWhere((c) => c.id == id);
  @override
  Future<void> clear() async => list0.clear();
}

class _MemoryTaskRepo implements TaskRepository {
  @override
  Future<List<DownloadTask>> loadAll() async => [];
  @override
  Future<void> remove(String taskId) async {}
  @override
  Future<void> save(DownloadTask task) async {}
}

/// 主链路外壳冒烟：解析/下载/设置页可切换渲染（零 IO）。
void main() {
  testWidgets('外壳渲染：解析页输入框 + 切换下载/设置页', (WidgetTester tester) async {
    // SnapFetchApp 会自定义 ErrorWidget.builder（release 防灰屏）；
    // flutter_test 要求测试结束时还原 —— 用 finally 保证断言失败也还原
    final savedErrorWidgetBuilder = ErrorWidget.builder;
    try {
      final container = ProviderContainer(overrides: [
        settingsProvider.overrideWith((_) async => _MemorySettings()),
        vaultProvider.overrideWith((_) async => _MemoryVault()),
        downloadEngineProvider.overrideWith((_) async => RangeDownloadEngine(
              dio: SnapHttp.dio,
              repository: _MemoryTaskRepo(),
            )),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const SnapFetchApp()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 品牌区拆成「闪取」+「SnapFetch」两行（桌面侧边栏形态）
      expect(find.text('闪取'), findsOneWidget);
      expect(find.text('SnapFetch'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget, reason: '解析页应有输入框');

      // 切到下载页（空状态）
      await tester.tap(find.text('下载').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('暂无下载任务'), findsOneWidget);

      // 切到设置页
      await tester.tap(find.text('设置').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('下载分片并发数'), findsOneWidget);
      expect(find.text('下载目录'), findsOneWidget);
    } finally {
      ErrorWidget.builder = savedErrorWidgetBuilder;
    }
  });
}
