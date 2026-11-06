import 'dart:convert';
import 'dart:io';

/// 一条解析历史：解析过的链接 + 平台 + 结果概要。
///
/// 与收藏夹的区别（对齐手机版）：收藏是**用户主动存**的，历史是**自动记**的，
/// 成功与失败都记，方便回溯「刚才那个链接」而不用再去翻浏览器。
class ParseHistoryEntry {
  final String id;
  final String url;
  final String passcode;
  final String platformId;
  final String platformName;

  /// 结果概要：'3 个文件 · 1.2 GB' / '6 张图片' / 失败原因。
  final String summary;
  final bool ok;
  final DateTime at;

  ParseHistoryEntry({
    required this.id,
    required this.url,
    this.passcode = '',
    this.platformId = '',
    this.platformName = '',
    this.summary = '',
    required this.ok,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'passcode': passcode,
        'platformId': platformId,
        'platformName': platformName,
        'summary': summary,
        'ok': ok,
        'at': at.toIso8601String(),
      };

  static ParseHistoryEntry fromJson(Map<String, dynamic> j) => ParseHistoryEntry(
        id: j['id'] as String,
        url: j['url'] as String,
        passcode: (j['passcode'] ?? '') as String,
        platformId: (j['platformId'] ?? '') as String,
        platformName: (j['platformName'] ?? '') as String,
        summary: (j['summary'] ?? '') as String,
        ok: (j['ok'] ?? true) as bool,
        at: DateTime.parse(j['at'] as String),
      );
}

/// 历史存储接口（与 [TaskRepository] 同思路：UI 只依赖接口，
/// widget 测试可整条替换为内存实现，避免 FakeAsync 下真实 IO 挂起）。
abstract class ParseHistoryStore {
  /// 按时间倒序返回。
  Future<List<ParseHistoryEntry>> all();

  /// 记录一次解析。同链接（同提取码）不新增条目，而是把时间提到最新。
  Future<void> record(ParseHistoryEntry entry);

  Future<void> remove(String id);

  Future<void> clear();
}

/// JSON 文件实现（写失败只丢持久化，不影响使用）。
class FileParseHistoryStore implements ParseHistoryStore {
  /// 上限：超出后丢弃最旧的（历史是便利功能，不该无限膨胀）。
  static const maxEntries = 100;

  final File file;
  List<ParseHistoryEntry>? _cache;

  FileParseHistoryStore(this.file);

  Future<List<ParseHistoryEntry>> _load() async {
    if (_cache != null) return _cache!;
    if (!await file.exists()) return _cache = [];
    try {
      _cache = (jsonDecode(await file.readAsString()) as List)
          .cast<Map<String, dynamic>>()
          .map(ParseHistoryEntry.fromJson)
          .toList();
    } catch (_) {
      _cache = [];
    }
    return _cache!;
  }

  Future<void> _flush() async {
    try {
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsString(
          jsonEncode(_cache!.map((e) => e.toJson()).toList()));
    } catch (_) {
      // 落盘失败保留内存态
    }
  }

  @override
  Future<List<ParseHistoryEntry>> all() async {
    final list = await _load();
    return List<ParseHistoryEntry>.of(list)
      ..sort((a, b) => b.at.compareTo(a.at));
  }

  @override
  Future<void> record(ParseHistoryEntry entry) async {
    final list = await _load();
    list.removeWhere((e) => e.url == entry.url && e.passcode == entry.passcode);
    list.add(entry);
    if (list.length > maxEntries) {
      list.removeRange(0, list.length - maxEntries);
    }
    await _flush();
  }

  @override
  Future<void> remove(String id) async {
    final list = await _load();
    list.removeWhere((e) => e.id == id);
    await _flush();
  }

  @override
  Future<void> clear() async {
    final list = await _load();
    list.clear();
    await _flush();
  }
}

/// 内存实现（测试 / 数据目录完全不可写时）。
class MemoryParseHistoryStore implements ParseHistoryStore {
  final _list = <ParseHistoryEntry>[];

  @override
  Future<List<ParseHistoryEntry>> all() async =>
      List<ParseHistoryEntry>.of(_list)
        ..sort((a, b) => b.at.compareTo(a.at));

  @override
  Future<void> record(ParseHistoryEntry entry) async {
    _list.removeWhere((e) => e.url == entry.url && e.passcode == entry.passcode);
    _list.add(entry);
    if (_list.length > FileParseHistoryStore.maxEntries) {
      _list.removeRange(0, _list.length - FileParseHistoryStore.maxEntries);
    }
  }

  @override
  Future<void> remove(String id) async => _list.removeWhere((e) => e.id == id);

  @override
  Future<void> clear() async => _list.clear();
}
