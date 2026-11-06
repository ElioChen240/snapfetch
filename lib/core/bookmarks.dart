import 'dart:convert';
import 'dart:io';

/// 收藏的链接（对应原版右上角书签功能）。
class Bookmark {
  final String id;
  final String url;
  final String passcode;
  final String platformName;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.url,
    this.passcode = '',
    this.platformName = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'passcode': passcode,
        'platformName': platformName,
        'createdAt': createdAt.toIso8601String(),
      };

  static Bookmark fromJson(Map<String, dynamic> j) => Bookmark(
        id: j['id'] as String,
        url: j['url'] as String,
        passcode: (j['passcode'] ?? '') as String,
        platformName: (j['platformName'] ?? '') as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// 收藏仓库（JSON 文件，写入失败不影响使用）。
class BookmarkRepository {
  final File file;
  List<Bookmark>? _cache;

  BookmarkRepository(this.file);

  Future<List<Bookmark>> _load() async {
    if (_cache != null) return _cache!;
    if (!await file.exists()) return _cache = [];
    try {
      final list = (jsonDecode(await file.readAsString()) as List)
          .cast<Map<String, dynamic>>()
          .map(Bookmark.fromJson)
          .toList();
      _cache = list;
    } catch (_) {
      _cache = [];
    }
    return _cache!;
  }

  Future<void> _flush() async {
    try {
      final p = file.parent;
      if (!await p.exists()) await p.create(recursive: true);
      await file.writeAsString(
          jsonEncode(_cache!.map((b) => b.toJson()).toList()));
    } catch (_) {
      // 写不进去也保留内存态
    }
  }

  Future<List<Bookmark>> all() async {
    final list = await _load();
    return List<Bookmark>.of(list)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 同一链接已收藏时更新提取码，避免重复条目。
  Future<void> add(Bookmark bookmark) async {
    final list = await _load();
    final i = list.indexWhere((b) => b.url == bookmark.url);
    if (i >= 0) {
      list[i] = bookmark;
    } else {
      list.add(bookmark);
    }
    await _flush();
  }

  Future<void> remove(String id) async {
    final list = await _load();
    list.removeWhere((b) => b.id == id);
    await _flush();
  }
}
