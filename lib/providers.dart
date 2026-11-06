import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/settings.dart';
import 'data/auth/credential_vault.dart';
import 'data/auth/login_rules.dart';
import 'data/download/download_engine.dart';
import 'data/download/task_repository.dart';
import 'data/network/http_client.dart';
import 'data/parsers/registry.dart';
import 'domain/parser.dart';

/// 全局 Riverpod 依赖注入（延迟初始化的 async provider）。

/// 数据目录是否降级（true = 正式目录不可写，凭证/任务不会持久化）。
/// UI 用它显示醒目提示，引导用户去安全软件放行。
final appDirFallback = ValueNotifier<bool>(false);

/// 数据目录探测结果（供界面向导展示，说明哪些位置可写）。
final appDirProbeLog = ValueNotifier<List<String>>(const []);

/// 应用数据根目录：按候选顺序探测**真实可写**的位置。
///
/// ★ 刻意不用 path_provider 的 getApplicationSupportDirectory：
///   它在 Windows 上用 exe 版本资源(CompanyName/ProductName)拼目录，
///   名称里出现括号/中文时实测会创建失败（errno 5）→ 整树 build 崩 → release 灰屏。
/// ★ 只 create 成功不算数（杀软可能放行建目录但拦写文件），必须写探针文件验证。
/// ★ **exe 同目录优先**：实测火绒 HIPS 会拦截未签名程序向用户目录
///   （APPDATA/LOCALAPPDATA/Documents 全部 errno 5）写入，
///   但允许它写自己所在目录 —— 数据放程序目录既是便携软件惯例，也绕开该限制。
/// ★ 全部失败时返回临时目录（应用仍可用，只是不持久化）。
final appDirProvider = FutureProvider<Directory>((_) async {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  final home = env['USERPROFILE'] ?? '';
  final exeDir = File(Platform.resolvedExecutable).parent.path;

  /// [persistent] = 该位置能可靠持久化（TEMP/Downloads 会被告知用户）
  final candidates = <(String, bool)>[
    // 便携/安装目录：杀软通常放行「程序写自己所在目录」
    if (exeDir.isNotEmpty) ('$exeDir${sep}SnapFetch-data', true),
    if (env['APPDATA'] != null)
      ('${env['APPDATA']}${sep}SnapFetch${sep}data', true),
    if (env['LOCALAPPDATA'] != null)
      ('${env['LOCALAPPDATA']}${sep}SnapFetch${sep}data', true),
    if (home.isNotEmpty) ('$home${sep}Documents${sep}SnapFetch${sep}data', true),
    // 兜底（可能被系统清理，标注为不可靠）
    if (env['TEMP'] != null) ('${env['TEMP']}${sep}SnapFetch-data', false),
    if (home.isNotEmpty) ('$home${sep}Downloads${sep}SnapFetch-data', false),
  ];

  final log = <String>[];
  for (var i = 0; i < candidates.length; i++) {
    final (path, persistent) = candidates[i];
    final dir = Directory(path);
    try {
      await dir.create(recursive: true);
      // 真实写探针：create 成功 ≠ 可写
      final probe = File('$path$sep.snapfetch_write_test');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      log.add('✓ #$i $path');
      appDirProbeLog.value = List.unmodifiable(log);
      // 只有不可靠位置才提示用户
      appDirFallback.value = !persistent;
      debugPrint('[appDir] 选用 #$i: $path');
      return dir;
    } catch (e) {
      log.add('✗ #$i $path → $e');
      appDirProbeLog.value = List.unmodifiable(log);
      debugPrint('[appDir] 不可用 #$i ($path): $e');
    }
  }
  appDirFallback.value = true;
  return Directory.systemTemp;
});

/// 设置（读取失败回退内存设置，绝不抛）。
final settingsProvider = FutureProvider<AppSettings>((ref) async {
  try {
    final dir = await ref.watch(appDirProvider.future);
    final s = JsonAppSettings(File('${dir.path}${Platform.pathSeparator}settings.json'));
    await s.warm();
    return s;
  } catch (e) {
    debugPrint('[settings] 加载失败，使用内存设置: $e');
    return _MemorySettings();
  }
});

/// 内存设置兜底（文件系统完全不可写时保证 UI 可用）。
class _MemorySettings extends AppSettings {
  @override
  String get downloadDir => '';
  @override
  int get concurrency => 8;
  @override
  ThemeMode get themeMode => ThemeMode.system;
  @override
  bool get saveFailed => true; // 内存设置本就无法持久化
  @override
  Future<void> setDownloadDir(String dir) async {}
  @override
  Future<void> setConcurrency(int v) async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
}

/// 凭证保险库。
final vaultProvider = FutureProvider<CredentialVault>((ref) async {
  final dir = await ref.watch(appDirProvider.future);
  return DpapiFileCredentialVault(
      File('${dir.path}${Platform.pathSeparator}credentials.bin'));
});

/// 下载引擎（任务持久化 + 分片并发）。
final downloadEngineProvider = FutureProvider<DownloadEngine>((ref) async {
  final dir = await ref.watch(appDirProvider.future);
  final engine = RangeDownloadEngine(
    dio: SnapHttp.dio,
    repository: JsonTaskRepository(File('${dir.path}${Platform.pathSeparator}tasks.json')),
    concurrency: 8, // 启动值；任务入队时读设置可覆盖
  );
  await engine.restoreQueue(); // 强杀后回滚 running → paused
  ref.onDispose(engine.dispose);
  return engine;
});

/// 解析器注册表（同步、常量）。
final registryProvider = Provider<ParserRegistry>((_) => buildDefaultRegistry());

/// 组装某平台的解析上下文：注入该平台最近一次捕获的 Cookie。
final parseContextFactoryProvider =
    Provider<Future<ParseContext> Function(String platformId)>((ref) {
  return (platformId) async {
    final vault = await ref.watch(vaultProvider.future);
    final creds = await vault.list();
    final cookie = creds
        .where((c) => c.platformId == platformId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final rule = kLoginRules[platformId];
    return SnapHttp.context(
      cookies: cookie.isEmpty ? const {} : cookie.first.cookies,
      referer: rule?.cookieUrl,
      log: (_) {}, // 诊断日志接入点（M4.1：诊断日志默认关、一键导出）
    );
  };
});

/// 下载页任务列表刷新信号（engine 流之外的手动刷新点）。
final tasksTickProvider = StateProvider<int>((_) => 0);

/// 当前导航页索引（0=解析 1=下载 2=账号 3=设置）。
/// 供页面间跳转使用（如解析失败后「去账号页重新登录」）。
final navIndexProvider = StateProvider<int>((_) => 0);
