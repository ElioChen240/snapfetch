import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/data/download/chunk_planner.dart';
import 'package:snapfetch/data/download/download_engine.dart';
import 'package:snapfetch/data/download/task_repository.dart';
import 'package:snapfetch/domain/parser.dart';

/// 本地 Range 文件服务：真实走 HTTP，验证分片下载的落盘正确性。
class _RangeServer {
  late HttpServer _server;
  final List<int> payload;
  late String url;
  int requests = 0;

  _RangeServer(this.payload);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${_server.address.host}:${_server.port}/file.bin';
    _server.listen((req) async {
      requests++;
      final resp = req.response;
      if (req.method == 'HEAD') {
        resp.headers.set(HttpHeaders.contentLengthHeader, payload.length);
        resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        await resp.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isEmpty ? payload.length - 1 : int.parse(parts[1]);
        final slice = payload.sublist(start, end + 1);
        resp.statusCode = HttpStatus.partialContent;
        resp.headers.set(HttpHeaders.contentLengthHeader, slice.length);
        resp.headers.set('Content-Range', 'bytes $start-$end/${payload.length}');
        resp.add(slice);
      } else {
        resp.headers.set(HttpHeaders.contentLengthHeader, payload.length);
        resp.add(payload);
      }
      await resp.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

const int _fileSize = 4 << 20; // 4 MiB，确保触发多分片

DownloadTask _task(String url, String path, int total) => DownloadTask(
      id: 't1',
      url: url,
      savePath: path,
      totalBytes: total,
      chunks: [],
    );

void main() {
  _errorPageGuards();
  group('ChunkPlanner', () {
    const planner = ChunkPlanner();

    test('大文件按体积切分且完整覆盖文件', () {
      final chunks = planner.plan(
          totalBytes: _fileSize, concurrency: 4, supportsRange: true);
      expect(chunks.length, 4);
      expect(chunks.first.start, 0);
      expect(chunks.last.end, _fileSize - 1);
      for (var i = 1; i < chunks.length; i++) {
        expect(chunks[i].start, chunks[i - 1].end + 1,
            reason: '分片必须连续无缝');
      }
    });

    test('小文件退化为单分片（请求开销大于收益）', () {
      final chunks = planner.plan(
          totalBytes: 1000, concurrency: 4, supportsRange: true);
      expect(chunks.length, 1);
      expect(chunks.single.end, 999);
    });

    test('并发上限 32', () {
      final chunks = planner.plan(
          totalBytes: 1 << 30, concurrency: 100, supportsRange: true);
      expect(chunks.length, ChunkPlanner.maxConcurrency);
    });

    test('不支持 Range 时退化为单分片', () {
      final chunks = planner.plan(
          totalBytes: 500, concurrency: 8, supportsRange: false);
      expect(chunks.length, 1);
      expect(chunks.single.end, 499);
    });

    test('remaining 跳过已完成分片', () {
      final c = Chunk(index: 0, start: 0, end: 99, written: 100);
      expect(planner.remaining(c), isNull);
      final c2 = Chunk(index: 1, start: 100, end: 199, written: 30);
      expect(planner.remaining(c2), (start: 130, end: 199));
    });
  });

  group('JsonTaskRepository', () {
    test('保存并恢复分片进度', () async {
      final dir = await Directory.systemTemp.createTemp('sf_repo');
      final repo = JsonTaskRepository(File('${dir.path}/tasks.json'));
      final t = _task('http://x/f', '${dir.path}/f.bin', 100);
      t.chunks.addAll([
        Chunk(index: 0, start: 0, end: 49, written: 50),
        Chunk(index: 1, start: 50, end: 99, written: 12),
      ]);
      t.status = TaskStatus.paused;
      await repo.save(t);

      final restored = await repo.loadAll();
      expect(restored.single.id, 't1');
      expect(restored.single.status, TaskStatus.paused);
      expect(restored.single.chunks[1].written, 12);
      await dir.delete(recursive: true);
    });
  });

  group('RangeDownloadEngine', () {
    late _RangeServer server;
    late Directory dir;
    late TaskRepository repo;
    late RangeDownloadEngine engine;

    setUp(() async {
      final rnd = Random(42);
      final payload = List<int>.generate(_fileSize, (_) => rnd.nextInt(256));
      server = _RangeServer(payload);
      await server.start();
      dir = await Directory.systemTemp.createTemp('sf_dl');
      repo = JsonTaskRepository(File('${dir.path}/tasks.json'));
      engine = RangeDownloadEngine(
        dio: Dio(),
        repository: repo,
        concurrency: 4,
      );
    });

    tearDown(() async {
      await engine.dispose();
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('分片并发下载，落盘字节与源文件完全一致', () async {
      final path = '${dir.path}/out.bin';
      final task = _task(server.url, path, server.payload.length);
      final done = engine.progressStream.firstWhere(
        (t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed,
      );
      await engine.enqueue(task);
      final result = await done.timeout(const Duration(seconds: 30));

      expect(result.status, TaskStatus.completed, reason: '应完整下载完成');
      final bytes = await File(path).readAsBytes();
      expect(bytes.length, server.payload.length);
      expect(bytes, orderedEquals(server.payload),
          reason: '多分片按偏移写入后必须与源文件逐字节一致');
      expect(server.requests, greaterThan(1), reason: '应确实使用了多个 Range 请求');
    });

    test('断点续传：复用已落盘分片，只请求剩余分片', () async {
      final path = '${dir.path}/out.bin';
      final task = _task(server.url, path, server.payload.length);
      task.status = TaskStatus.paused;
      task.chunks.addAll(const ChunkPlanner().plan(
          totalBytes: _fileSize, concurrency: 4, supportsRange: true));
      // 模拟进程被强杀：第 0 片已完整落盘为独立分片文件
      final first = task.chunks[0];
      final part0 = File(RangeDownloadEngine.partPathFor(path, 0));
      await part0.parent.create(recursive: true);
      final expected = server.payload.sublist(first.start, first.end + 1);
      await part0.writeAsBytes(expected);
      first.written = first.end - first.start + 1;
      task.downloadedBytes = first.written;
      await repo.save(task);

      // 前置断言：确认模拟的分片确实写对了
      expect(await part0.readAsBytes(), orderedEquals(expected));

      final before = server.requests;
      final done = engine.progressStream.firstWhere(
        (t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed,
      );
      await engine.resume(task.id);
      final result = await done.timeout(const Duration(seconds: 30));

      expect(result.status, TaskStatus.completed);
      expect(server.requests - before, 3,
          reason: '4 片中第 0 片已完成，只应发 3 个 Range 请求');
      final bytes = await File(path).readAsBytes();
      expect(bytes, orderedEquals(server.payload),
          reason: '续传后整文件仍须与源文件逐字节一致');
    });

    test('单分片任务也能正确落盘', () async {
      final path = '${dir.path}/out.bin';
      final task = DownloadTask(
        id: 'single',
        url: server.url,
        savePath: path,
        totalBytes: server.payload.length,
        chunks: [Chunk(index: 0, start: 0, end: server.payload.length - 1)],
      );
      final done = engine.progressStream.firstWhere(
        (t) => t.id == 'single' &&
            (t.status == TaskStatus.completed || t.status == TaskStatus.failed),
      );
      await engine.enqueue(task);
      final result = await done.timeout(const Duration(seconds: 30));
      expect(result.status, TaskStatus.completed);
      expect(await File(path).readAsBytes(), orderedEquals(server.payload));
    });
  });
}

/// 错误页伪装成 200 的回归测试（用户实测：243KB 图片只下到 262B 却显示已完成）。
void _errorPageGuards() {
  group('错误页拦截', () {
    late HttpServer server;
    late Directory dir;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      dir = await Directory.systemTemp.createTemp('sf_errpage');
      server.listen((req) async {
        final resp = req.response;
        if (req.method == 'HEAD') {
          resp.headers.set(HttpHeaders.contentLengthHeader, '100');
        } else {
          // 200 + JSON 错误页（模拟缺 Cookie 时 CDN 的响应）
          resp.headers.contentType = ContentType.json;
          resp.write('{"code":41001,"message":"need login"}');
        }
        await resp.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('content-type=json 的错误页 → 任务失败，不显示已完成', () async {
      final engine = RangeDownloadEngine(
        dio: Dio(),
        repository: JsonTaskRepository(
            File('${dir.path}${Platform.pathSeparator}tasks.json')),
        concurrency: 2,
      );
      final done = engine.progressStream.firstWhere(
        (t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed,
      );
      await engine.enqueue(DownloadTask(
        id: 'err',
        url: 'http://${server.address.host}:${server.port}/x',
        savePath: '${dir.path}${Platform.pathSeparator}x',
        totalBytes: 0,
      ));
      final result = await done.timeout(const Duration(seconds: 20));
      expect(result.status, TaskStatus.failed,
          reason: '错误页不能被当成成功下载');
      await engine.dispose();
    });
  });
}
