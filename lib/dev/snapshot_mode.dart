import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bookmarks.dart';
import '../core/parse_history.dart';
import '../core/settings.dart';
import '../data/auth/credential_vault.dart';
import '../data/download/download_engine.dart';
import '../data/download/task_repository.dart';
import '../data/network/http_client.dart';
import '../domain/parser.dart';
import '../providers.dart';
import '../ui/home_shell.dart';
import '../ui/theme/app_theme.dart';
import '../ui/theme/motion.dart';

/// 文档截图模式：把**真实外壳**逐页渲染成 PNG，然后退出。
///
/// 为什么不用屏幕截图：远程/服务化环境里抓不到交互桌面（实测 PowerShell
/// 无桌面时 `Screen::PrimaryBounds` 返回 null）。而 README 需要的就是
/// 「用户实际看到的那个窗口」—— 让应用自己 RepaintBoundary 导出最可靠，
/// 字体、主题、密度全部走真实渲染路径（flutter test 的 golden 会把中文
/// 渲染成豆腐块，不能用）。
///
/// 用法：`SnapFetch.exe --snapshot=docs/images`

/// 解析 `--snapshot[=目录]`；不是截图模式返回 null。
String? snapshotDirOf(List<String> args) {
  for (final a in args) {
    if (a == '--snapshot') return 'docs/images';
    if (a.startsWith('--snapshot=')) {
      final v = a.substring('--snapshot='.length).trim();
      return v.isEmpty ? 'docs/images' : v;
    }
  }
  return null;
}

/// 依次渲染各场景并写 PNG。完成后进程退出。
Future<void> runSnapshot(String outDir) async {
  final dir = Directory(outDir)..createSync(recursive: true);
  final boundaryKey = GlobalKey(debugLabel: 'snapshot-boundary');
  final pixelRatio = 1.5; // 1360x880 窗口 → 2040x1320，够清晰又不至于太大
  // 截图必须稳定：动效时长归零，避免抓到过渡帧
  Motion.reduce = true;

  for (final scene in _scenes) {
    // ★ 每个场景一个全新 ProviderContainer + 唯一 ValueKey。
    //   直接 runApp 第二遍时根 widget 类型没变 → Flutter 复用同一 element，
    //   ProviderScope 走 updateOverrides（实测抛 Null check），
    //   结果几个场景拍出来是同一张图。换 key 强制整棵子树重挂载。
    final container = ProviderContainer(overrides: scene.overrides());
    runApp(RepaintBoundary(
      key: boundaryKey,
      child: UncontrolledProviderScope(
        key: ValueKey(scene.file),
        container: container,
        child: MaterialApp(
          title: '闪取 SnapFetch',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          themeMode: ThemeMode.light,
          home: const HomeShell(),
        ),
      ),
    ));

    // 等异步 provider（设置/凭证/解析结果）落地并画完
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 260));
      await WidgetsBinding.instance.endOfFrame;
    }

    final ro = boundaryKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      stderr.writeln('[snapshot] ${scene.file} 渲染对象缺失，跳过');
      continue;
    }
    final image = ro.toImageSync(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      stderr.writeln('[snapshot] ${scene.file} 编码失败，跳过');
      continue;
    }
    final out = File('${dir.path}${Platform.pathSeparator}${scene.file}');
    out.writeAsBytesSync(bytes.buffer.asUint8List());
    stdout.writeln('[snapshot] ${scene.file}  '
        '${(bytes.lengthInBytes / 1024).toStringAsFixed(0)} KB');
  }

  stdout.writeln('[snapshot] 完成：${dir.path}');
  exit(0);
}

class _Scene {
  final String file;
  final List<Override> Function() overrides;
  const _Scene(this.file, this.overrides);
}

// ================= 场景数据（只为截图，不碰任何真实接口） =================

List<Override> _baseOverrides() => [
      // 数据目录不覆盖：走应用自己的探测逻辑（实测本机 %TEMP% 被杀软拦，
      // 而程序目录可写 —— 覆盖成 systemTemp 反而会让界面顶部弹出红色错误条）。
      settingsProvider.overrideWith((_) async => _SnapshotSettings()),
      historyRepoProvider.overrideWith((_) async => _history()),
      bookmarkRepoProvider.overrideWith((_) async => _bookmarks()),
      vaultProvider.overrideWith((_) async => _SnapshotVault()),
      registryProvider.overrideWith((_) => _registry()),
      parseContextFactoryProvider.overrideWith((_) => (id) async => _ctx()),
      navIndexProvider.overrideWith((_) => 0),
      startupLinkProvider.overrideWith((_) => ''),
      // 账号页的昵称/容量：给一份像样的假数据（真实接口在截图模式不该被调）
      accountStatProvider.overrideWith((_, id) async => id == 'quark'
          ? const AccountStat(
              nickname: '沫辰',
              used: 704674201, // 672.0 MB
              total: 10737418240, // 10.0 GB
            )
          : null),
    ];

List<Override> _parseIdle() => _baseOverrides();

List<Override> _parseResult() => [
      ..._baseOverrides(),
      startupLinkProvider.overrideWith(
          (_) => 'https://pan.quark.cn/s/8a3f1c7d2b 提取码: 7g2k'),
    ];

List<Override> _accounts() => [      ..._baseOverrides(),
      navIndexProvider.overrideWith((_) => 2),
    ];

List<Override> _downloads() => [
      ..._baseOverrides(),
      navIndexProvider.overrideWith((_) => 1),
      downloadEngineProvider.overrideWith((_) async => RangeDownloadEngine(
            dio: SnapHttp.dio,
            repository: _SnapshotTasks(),
          )),
    ];

List<Override> _settings() => [
      ..._baseOverrides(),
      navIndexProvider.overrideWith((_) => 3),
    ];

List<Override> _videoResult() => [
      ..._baseOverrides(),
      registryProvider.overrideWith((_) => ParserRegistry()..register(_SnapshotVideoParser())),
      startupLinkProvider.overrideWith((_) => 'https://v.douyin.com/iAbcD/'),
    ];

final _scenes = <_Scene>[
  const _Scene('parse.png', _parseIdle),
  const _Scene('parse_result.png', _parseResult),
  const _Scene('parse_media.png', _videoResult),
  const _Scene('accounts.png', _accounts),
  const _Scene('downloads.png', _downloads),
  const _Scene('settings.png', _settings),
];

// ---------- 假实现 ----------

class _SnapshotSettings extends AppSettings {
  @override
  bool get saveFailed => false;
  // 截图里显示一个「像用户机器」的目录；留空会回退到程序目录，
  // 在开发机上就变成 build\windows\...\Release\downloads，放进文档很难看。
  @override
  String get downloadDir => r'C:\Users\demo\Downloads';
  @override
  int get concurrency => 8;
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  bool get noTransferDownload => true;
  @override
  Future<void> setConcurrency(int v) async {}
  @override
  Future<void> setDownloadDir(String dir) async {}
  @override
  Future<void> setNoTransferDownload(bool v) async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
}

class _SnapshotVault implements CredentialVault {
  @override
  Future<void> clear() async {}
  @override
  Future<List<StoredCredential>> list() async => [
        StoredCredential(
          id: 'snap-1',
          platformId: 'quark',
          label: '主账号',
          cookies: const {'__pus': 'snapshot', 'kps': 'snapshot'},
          createdAt: DateTime(2026, 11, 6, 21, 10),
        ),
      ];
  @override
  Future<void> put(StoredCredential c) async {}
  @override
  Future<void> remove(String id) async {}
}

ParseContext _ctx() => ParseContext(
      cookies: const {'__pus': 'snapshot', 'kps': 'snapshot'},
      baseHeaders: const {'Referer': 'https://pan.quark.cn/'},
      httpGet: (_, {headers, query}) async =>
          PHttpResponse(statusCode: 200, body: '{}', finalUri: Uri.parse('https://x/')),
      httpPost: (_, {jsonBody, headers, query}) async =>
          PHttpResponse(statusCode: 200, body: '{}', finalUri: Uri.parse('https://x/')),
      log: (_) {},
    );

/// 假解析器：产出一棵「有目录有文件、大小合理」的树，只为界面截图。
class _SnapshotParser extends LinkParser {
  @override
  String get id => 'quark';
  @override
  String get displayName => '夸克网盘';
  @override
  PlatformKind get kind => PlatformKind.netdisk;
  @override
  bool get requiresAuth => true;
  @override
  bool matches(String input) => input.contains('pan.quark.cn');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async => FileTreeResult(
        shareTitle: '8a3f1c7d2b',
        roots: [
          FileNode(name: '第一季 1080P', path: 's1', isDirectory: true, children: [
            FileNode(
                name: 'E01.合集内附字幕.srt',
                path: 's1/e01.srt',
                isDirectory: false,
                size: 42 * 1024),
            FileNode(
                name: 'E01.中英字幕.1080p.mp4',
                path: 's1/e01.mp4',
                isDirectory: false,
                size: 2411724800),
            FileNode(
                name: 'E02.中英字幕.1080p.mp4',
                path: 's1/e02.mp4',
                isDirectory: false,
                size: 2362232012),
          ]),
          FileNode(name: '说明.txt', path: 'readme', isDirectory: false, size: 1024),
          FileNode(
              name: '原声带.flac',
              path: 'ost.flac',
              isDirectory: false,
              size: 314572800),
        ],
      );
}

ParserRegistry _registry() => ParserRegistry()..register(_SnapshotParser());

/// 假视频解析器：产出「媒体集」形态，用来证明视频链路 + 播放入口都在。
/// 只给视频条目（不给图片）：图片缩略图会真的去联网加载，
/// 截图里会出现加载失败的样子，反而误导。
class _SnapshotVideoParser extends LinkParser {
  @override
  String get id => 'douyin';
  @override
  String get displayName => '抖音';
  @override
  PlatformKind get kind => PlatformKind.video;
  @override
  bool get requiresAuth => false;
  @override
  bool matches(String input) => input.contains('v.douyin.com');

  @override
  Future<ParseResult> parse(String input, ParseContext ctx) async => MediaSetResult(
        title: '【官方】这部电影值得二刷',
        author: '示例作者',
        items: [
          MediaItem(
            url: 'https://example.com/snapshot/original.mp4',
            kind: MediaKind.video,
            qualityLabel: '原画（无水印）',
            size: 28 * 1024 * 1024,
            headers: const {'Referer': 'https://www.douyin.com/'},
          ),
          MediaItem(
            url: 'https://example.com/snapshot/720p.mp4',
            kind: MediaKind.video,
            qualityLabel: '720p',
            size: 14 * 1024 * 1024,
            headers: const {'Referer': 'https://www.douyin.com/'},
          ),
        ],
      );
}

Future<ParseHistoryStore> _history() async {
  final s = MemoryParseHistoryStore();
  final now = DateTime(2026, 11, 6, 21, 40);
  await s.record(ParseHistoryEntry(
      id: 'h1',
      url: 'https://pan.quark.cn/s/8a3f1c7d2b',
      passcode: '7g2k',
      platformId: 'quark',
      platformName: '夸克网盘',
      summary: '5 个文件 · 4.8 GB',
      ok: true,
      at: now));
  await s.record(ParseHistoryEntry(
      id: 'h2',
      url: 'https://www.123pan.com/s/AbCdE-EfGhI.html',
      platformId: 'pan123',
      platformName: '123 云盘',
      summary: '12 个文件 · 1.2 GB',
      ok: true,
      at: now.subtract(const Duration(minutes: 23))));
  await s.record(ParseHistoryEntry(
      id: 'h3',
      url: 'https://drive.uc.cn/s/9f8e7d6c',
      platformId: 'uc',
      platformName: 'UC 网盘',
      summary: '提取码错误',
      ok: false,
      at: now.subtract(const Duration(hours: 3))));
  return s;
}

Future<BookmarkRepository> _bookmarks() async {
  final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}sf_snap_bm.json');
  final repo = BookmarkRepository(f);
  await repo.add(Bookmark(
      id: 'b1',
      url: 'https://pan.quark.cn/s/8a3f1c7d2b',
      passcode: '7g2k',
      platformName: '夸克网盘',
      createdAt: DateTime(2026, 11, 6)));
  return repo;
}

class _SnapshotTasks implements TaskRepository {
  static DownloadTask _t(String name, double mb, TaskStatus s, double done) =>
      DownloadTask(
        id: 'snap-$name',
        url: 'https://cdn.example/$name',
        savePath: 'C:\\Users\\demo\\Downloads\\$name',
        totalBytes: (mb * 1024 * 1024).round(),
        downloadedBytes: (mb * 1024 * 1024 * done).round(),
        status: s,
        chunks: const [],
      );

  @override
  Future<List<DownloadTask>> loadAll() async => [
        _t('E01.中英字幕.1080p.mp4', 2300, TaskStatus.running, 0.62),
        _t('原声带.flac', 300, TaskStatus.paused, 0.35),
        _t('说明.txt', 0.001, TaskStatus.completed, 1.0),
      ];
  @override
  Future<void> remove(String taskId) async {}
  @override
  Future<void> save(DownloadTask task) async {}
}
