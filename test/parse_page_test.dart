import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:snapfetch/core/settings.dart';
import 'package:snapfetch/data/download/download_engine.dart';
import 'package:snapfetch/data/download/task_repository.dart';
import 'package:snapfetch/data/network/http_client.dart';
import 'package:snapfetch/domain/parser.dart';
import 'package:snapfetch/ui/theme/motion.dart';
import 'package:snapfetch/providers.dart';
import 'package:snapfetch/ui/pages/parse_page.dart';

/// 假解析器：返回 3 层嵌套、共 145 个文件的树（复现用户实测规模）。
class _FakeParser extends LinkParser {
  const _FakeParser();
  @override
  String get id => 'fake';
  @override
  String get displayName => '测试网盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => false;
  @override
  bool matches(String input) => true;

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async {
    final deep = <FileNode>[
      for (var i = 0; i < 140; i++)
        FileNode(
          name: 'FramePack-V1.3.z$i',
          path: 'root/a/b/FramePack-V1.3.z$i',
          isDirectory: false,
          size: 2 * 1024 * 1024 * 1024,
        ),
    ];
    return FileTreeResult(shareTitle: '测试分享', roots: [
      FileNode(name: '整合包大全', path: 'root', isDirectory: true, children: [
        FileNode(name: 'Framepack整合包', path: 'root/a', isDirectory: true, children: [
          FileNode(name: 'FramePack-V1.3', path: 'root/a/b', isDirectory: true, children: deep),
        ]),
        FileNode(name: '说明.txt', path: 'root/readme', isDirectory: false, size: 100),
      ]),
      // 另外 4 个零散文件，凑满 145
      for (var i = 0; i < 4; i++)
        FileNode(name: 'extra$i.mp4', path: 'extra$i', isDirectory: false, size: 1024),
    ]);
  }
}

class _MemSettings extends AppSettings {
  @override
  bool get saveFailed => false;
  @override
  String get downloadDir => '';
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

class _MemRepo implements TaskRepository {
  @override
  Future<List<DownloadTask>> loadAll() async => [];
  @override
  Future<void> remove(String taskId) async {}
  @override
  Future<void> save(DownloadTask task) async {}
}

ParseContext _fakeCtx() => ParseContext(
      httpGet: (url, {headers, query}) async =>
          PHttpResponse(
              statusCode: 200, body: '{}', finalUri: Uri.parse('https://x/')),
      httpPost: (url, {jsonBody, headers, query}) async =>
          PHttpResponse(
              statusCode: 200, body: '{}', finalUri: Uri.parse('https://x/')),
      log: (_) {},
    );

void main() {
  // 测试不依赖动画时序：关掉动效，AnimatedSwitcher 立即完成
  setUp(() => Motion.reduce = true);
  tearDown(() => Motion.reduce = false);

  testWidgets('解析结果：进入式浏览（对齐官方）+ 默认全选 + 目录整选',
      (WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      registryProvider.overrideWith((_) => ParserRegistry()..register(const _FakeParser())),
      parseContextFactoryProvider.overrideWith((_) => (_) async => _fakeCtx()),
      settingsProvider.overrideWith((_) async => _MemSettings()),
      downloadEngineProvider.overrideWith(
          (_) async => RangeDownloadEngine(dio: SnapHttp.dio, repository: _MemRepo())),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ParsePage())),
    ));
    await tester.pump();

    // 输入并解析
    await tester.enterText(find.byType(TextField).first, 'https://pan.quark.cn/s/abc');
    await tester.tap(find.widgetWithText(FilledButton, '解析'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ★ 回归点 1：解析后默认全选
    expect(find.textContaining('145 / 145 已选'), findsOneWidget);

    // ★ 回归点 2：进入式浏览 —— 根目录只显示**直接子项**，深层文件不出现
    expect(find.text('整合包大全'), findsOneWidget);
    expect(find.text('extra0.mp4'), findsOneWidget);
    expect(find.text('FramePack-V1.3.z0'), findsNothing,
        reason: '根目录不应直接展开深层文件（官方是逐层进入）');

    // ★ 回归点 3：点文件夹进入下一层（不是整选）
    await tester.tap(find.text('整合包大全'));
    await tester.pump();
    expect(find.text('Framepack整合包'), findsOneWidget);
    expect(find.text('说明.txt'), findsOneWidget);
    expect(find.textContaining('145 / 145 已选'), findsOneWidget,
        reason: '进入目录不改变选中状态');

    // 再进两层到最深处
    await tester.tap(find.text('Framepack整合包'));
    await tester.pump();
    await tester.tap(find.text('FramePack-V1.3'));
    await tester.pump();
    expect(find.text('FramePack-V1.3.z0'), findsOneWidget);

    // ★ 回归点 4：返回上一级
    await tester.tap(find.byTooltip('返回上一级'));
    await tester.pump();
    expect(find.text('FramePack-V1.3'), findsOneWidget);
    expect(find.text('FramePack-V1.3.z0'), findsNothing);

    // 回到根目录，点文件夹左侧勾选框 → 整目录取消（140 文件 + 1 readme）
    await tester.tap(find.byTooltip('返回上一级'));
    await tester.pump();
    await tester.tap(find.byTooltip('返回上一级'));
    await tester.pump();
    expect(find.text('整合包大全'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first); // 第一个是「整合包大全」的勾选框
    await tester.pump();
    expect(find.textContaining('4 / 145 已选'), findsOneWidget,
        reason: '取消整个目录应只剩根目录 4 个文件');
  });
}
