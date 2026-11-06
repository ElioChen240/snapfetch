import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// 轻量设置存储（settings.json）：下载目录 / 并发数 / 主题模式。
/// 接口化便于测试；M4.1 可无感迁到 drift。
abstract class AppSettings {
  String get downloadDir;
  int get concurrency;
  ThemeMode get themeMode;

  /// 上次保存是否失败（内存已生效但磁盘没写进去）——
  /// 界面据此提示「设置已生效，但无法保存到磁盘」。
  bool get saveFailed;

  /// 免转存下载（夸克/UC）：解析出直链后直接下载，不转存进自己的网盘。
  /// 默认开；关闭后走「先转存到我的文件，再下载」。
  bool get noTransferDownload => true;

  Future<void> setDownloadDir(String dir);
  Future<void> setConcurrency(int v);
  Future<void> setThemeMode(ThemeMode mode);
  Future<void> setNoTransferDownload(bool value) async {}

  /// 实际生效的下载目录。
  ///
  /// ★ 用户显式设置的目录严格优先（分发给别人时改到哪就下到哪，不再回退）。
  /// ★ 未设置时的默认：优先「用户\\下载」文件夹（正规软件惯例）；
  ///   若该目录写不了（本机火绒按进程拦截未签名 exe），才用程序目录 downloads。
  ///   这是默认值的择优，不是下载时的静默改存 —— 用户改过的目录永远不被替换。
  String get effectiveDownloadDir {
    if (downloadDir.isNotEmpty) return downloadDir;
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final userDownloads = '$home${Platform.pathSeparator}Downloads';
      try {
        Directory(userDownloads).createSync(recursive: true);
        final probe = File('$userDownloads${Platform.pathSeparator}sf_probe.tmp');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        return userDownloads;
      } catch (_) {
        // 用户目录写不了（安全软件按进程拦截）→ 退回程序目录
      }
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dir = '$exeDir${Platform.pathSeparator}downloads';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {}
    return dir;
  }
}

class JsonAppSettings extends AppSettings {
  final File file;
  Map<String, dynamic>? _cache;
  final void Function()? onChanged;
  bool _saveFailed = false;

  JsonAppSettings(this.file, {this.onChanged});

  @override
  bool get saveFailed => _saveFailed;

  static const _kDownloadDir = 'download_dir';
  static const _kConcurrency = 'concurrency';
  static const _kThemeMode = 'theme_mode';
  static const _kNoTransfer = 'no_transfer_download';

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    if (await file.exists()) {
      try {
        _cache = (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
      } catch (_) {
        _cache = {};
      }
    } else {
      _cache = {};
    }
    return _cache!;
  }

  /// ★ 写盘失败不抛：内存缓存已更新，本次会话生效（否则用户改设置像没反应）。
  ///   失败状态记在 [saveFailed]，由界面提示。
  Future<void> _flush(Map<String, dynamic> c) async {
    try {
      final parent = file.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await file.writeAsString(jsonEncode(c));
      _saveFailed = false;
      onChanged?.call();
    } catch (e) {
      _saveFailed = true;
      debugPrint('[settings] 保存失败（仅本次会话生效）: $e');
    }
  }

  @override
  String get downloadDir => _cache?[_kDownloadDir] as String? ?? '';

  @override
  int get concurrency =>
      ((_cache?[_kConcurrency] as num?)?.toInt() ?? 8).clamp(1, 32);

  @override
  ThemeMode get themeMode =>
      ThemeMode.values.asMap()[(_cache?[_kThemeMode] as num?)?.toInt()] ??
      ThemeMode.system;

  /// 缺省视为 true（免转存），与旧版本 settings.json 无此键时的行为一致。
  @override
  bool get noTransferDownload => _cache?[_kNoTransfer] as bool? ?? true;

  @override
  Future<void> setNoTransferDownload(bool value) async {
    final c = await _load();
    c[_kNoTransfer] = value;
    await _flush(c);
  }

  @override
  Future<void> setDownloadDir(String dir) async {
    final c = await _load();
    c[_kDownloadDir] = dir;
    await _flush(c);
  }

  @override
  Future<void> setConcurrency(int v) async {
    final c = await _load();
    c[_kConcurrency] = v.clamp(1, 32);
    await _flush(c);
  }

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    final c = await _load();
    c[_kThemeMode] = mode.index;
    await _flush(c);
  }

  /// 加载并固化缓存（应用启动时调用一次）。
  Future<void> warm() => _load();
}
