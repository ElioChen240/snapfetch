import 'dart:convert';
import 'dart:io';

import '../../domain/parser.dart';

/// 任务/分片规划持久化（PRD §2.1 红线 5、§6.4）。
///
/// M1 用 JSON 文件实现（轻量、可测、无需代码生成）；
/// 接口与 drift 存储解耦，M1.1 可无感替换为 SQLite。
abstract class TaskRepository {
  Future<void> save(DownloadTask task);
  Future<void> remove(String taskId);
  Future<List<DownloadTask>> loadAll();
}

class JsonTaskRepository implements TaskRepository {
  final File file;
  final Map<String, DownloadTask> _cache = {};

  JsonTaskRepository(this.file);

  Future<void> _ensureLoaded() async {
    if (_cache.isNotEmpty || !await file.exists()) return;
    final text = await file.readAsString();
    if (text.trim().isEmpty) return;
    final list = jsonDecode(text) as List<dynamic>;
    for (final e in list) {
      final t = _fromJson(e as Map<String, dynamic>);
      _cache[t.id] = t;
    }
  }

  Future<void> _flush() async {
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final data = _cache.values.map(_toJson).toList();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  @override
  Future<void> save(DownloadTask task) async {
    await _ensureLoaded();
    _cache[task.id] = task;
    await _flush();
  }

  @override
  Future<void> remove(String taskId) async {
    await _ensureLoaded();
    _cache.remove(taskId);
    await _flush();
  }

  @override
  Future<List<DownloadTask>> loadAll() async {
    await _ensureLoaded();
    return _cache.values.toList();
  }

  Map<String, dynamic> _toJson(DownloadTask t) => {
        'id': t.id,
        'url': t.url,
        'savePath': t.savePath,
        'headers': t.headers,
        'totalBytes': t.totalBytes,
        'downloadedBytes': t.downloadedBytes,
        'status': t.status.name,
        'chunks': [
          for (final c in t.chunks)
            {'index': c.index, 'start': c.start, 'end': c.end, 'written': c.written}
        ],
      };

  DownloadTask _fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        savePath: j['savePath'] as String,
        headers: (j['headers'] as Map?)?.cast<String, String>() ?? const {},
        totalBytes: (j['totalBytes'] as num).toInt(),
        downloadedBytes: (j['downloadedBytes'] as num?)?.toInt() ?? 0,
        status: TaskStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => TaskStatus.queued,
        ),
        chunks: [
          for (final c in (j['chunks'] as List? ?? const []))
            Chunk(
              index: (c['index'] as num).toInt(),
              start: (c['start'] as num).toInt(),
              end: (c['end'] as num).toInt(),
              written: (c['written'] as num?)?.toInt() ?? 0,
            )
        ],
      );
}
