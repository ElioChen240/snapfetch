import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../domain/parser.dart';
import 'chunk_planner.dart';
import 'task_repository.dart';

/// Range 分片并发下载引擎（M1，核心 C2）。
///
/// 实现要点（对应 PRD §2.1 红线 5 / §4.2）：
/// - HEAD/首请求探测 Content-Length 与 Accept-Ranges；不支持则单分片
/// - 固定分片规划 + 每片独立 `Range: bytes=start-end` 并发下载
/// - 预分配文件 + RandomAccessFile 按偏移写入，各片互不干扰
/// - 每片完成即落盘 written，重启后从未完成处续传
/// - 暂停 / 继续 / 取消、失败自动重试、全局并发上限 32
/// - 禁止云端中转：文件从源站直下本地（红线 4）
class RangeDownloadEngine implements DownloadEngine {
  final Dio dio;
  final ChunkPlanner planner;
  final TaskRepository repository;
  final int concurrency;
  final int maxRetries;
  /// 同时下载的任务数上限
  final int maxConcurrentTasks;
  final void Function(String message)? log;

  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();
  final Map<String, _Running> _running = {};

  /// 排队中的任务（活跃任务数已达上限时暂存）
  final List<DownloadTask> _pendingTasks = [];

  RangeDownloadEngine({
    required this.dio,
    required this.repository,
    this.planner = const ChunkPlanner(),
    this.concurrency = 8,
    this.maxRetries = 3,
    /// 同时下载的任务数上限（原版默认 1，这里给 3 兼顾速度与连接数）
    this.maxConcurrentTasks = 3,
    this.log,
  });

  /// 当前活跃任务数
  int get activeTaskCount => _running.length;

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  @override
  Future<List<DownloadTask>> restoreQueue() async {
    final tasks = await repository.loadAll();
    for (final t in tasks) {
      if (t.status == TaskStatus.running) {
        // 进程被强杀后状态回滚为暂停，等用户/自动恢复
        t.status = TaskStatus.paused;
        await repository.save(t);
      }
    }
    return tasks;
  }

  @override
  Future<void> enqueue(DownloadTask task) async {
    if (_running.containsKey(task.id) ||
        _pendingTasks.any((t) => t.id == task.id)) {
      return; // 重复入队保护
    }
    if (task.chunks.isEmpty) {
      await _prepare(task);
    }
    // ★ 并发上限：勾选上百个文件时不能全部同时开下
    if (_running.length >= maxConcurrentTasks) {
      task.status = TaskStatus.queued;
      _pendingTasks.add(task);
      await repository.save(task);
      _emit(task);
      return;
    }
    _start(task);
  }

  void _start(DownloadTask task) {
    task.status = TaskStatus.running;
    final run = _Running(task);
    _running[task.id] = run;
    _emit(task);
    unawaited(_execute(run));
  }

  /// 从排队队列取下一个启动（任务结束/取消时调用）。
  void _startNextPending() {
    if (_pendingTasks.isEmpty) return;
    if (_running.length >= maxConcurrentTasks) return;
    final next = _pendingTasks.removeAt(0);
    _start(next);
  }

  /// 探测元信息并生成/复用固定分片规划。
  /// 诊断日志（落盘到程序目录，供用户反馈时提供）。
  Future<void> _diag(String message) async {
    try {
      final f = File('${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.pathSeparator}download_debug.log');
      await f.writeAsString(
          '${DateTime.now().toIso8601String()} $message\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<void> _prepare(DownloadTask task) async {
    int total = task.totalBytes;
    bool range = true;
    if (total <= 0) {
      try {
        await _diag('HEAD ${task.url}\nheaders=${jsonEncode(task.headers)}');
        final head = await dio.headUri(Uri.parse(task.url),
            options: Options(headers: task.headers));
        final len = head.headers.value(HttpHeaders.contentLengthHeader);
        total = len == null ? 0 : int.tryParse(len) ?? 0;
        final accept = head.headers.value(HttpHeaders.acceptRangesHeader);
        range = accept == null || accept.toLowerCase() != 'none';
        await _diag('HEAD ok status=${head.statusCode} len=$len '
            'ct=${head.headers.value(HttpHeaders.contentTypeHeader)}');
      } catch (e) {
        await _diag('HEAD FAIL: $e');
        // ★ HEAD 常被 CDN 拒绝（403/405）；改用 GET 带 Range 首字节探测，
        //   从 Content-Range 解析总长度。仍失败才报错并带出真实原因。
        try {
          final get = await dio.getUri<List<int>>(
            Uri.parse(task.url),
            options: Options(
              headers: {...task.headers, HttpHeaders.rangeHeader: 'bytes=0-0'},
              responseType: ResponseType.bytes,
            ),
          );
          final cr = get.headers.value('content-range'); // bytes 0-0/248789
          if (cr != null && cr.contains('/')) {
            total = int.tryParse(cr.split('/').last.trim()) ?? 0;
          }
          await _diag('GET probe ok status=${get.statusCode} cr=$cr total=$total');
          range = cr != null;
        } catch (e2) {
          await _diag('GET probe FAIL: $e2');
          throw StateError('探测文件信息失败：HEAD=$e；GET=$e2'
              '（直链可能已过期或缺少登录 Cookie，请重新解析/取链）');
        }
      }
    }
    task.chunks.addAll(planner.plan(
      totalBytes: total,
      concurrency: concurrency,
      supportsRange: range,
    ));
    if (total > 0) task.totalBytes = total;
  }

  Future<void> _execute(_Running run) async {
    final task = run.task;
    try {
      final parent = File(task.savePath).parent;
      if (!await parent.exists()) await parent.create(recursive: true);

      // ★ 分片写独立临时文件，全部完成后按序合并成最终文件。
      //   原因：Dart 的 RandomAccessFile 不允许同一句柄并发异步操作，
      //   且 FileMode.writeOnly 会 truncate 已存在文件（会抹掉续传时已落盘的分片）。
      //   独立分片文件天然支持并发，也让「断点续传」变成「分片文件已存在即跳过」。
      final pending = <Chunk>[];
      for (final c in task.chunks) {
        final part = File(_partPath(task.savePath, c.index));
        final expected = c.end - c.start + 1;
        if (await part.exists() && await part.length() == expected) {
          c.written = expected; // 续传：复用已落盘分片
        } else if (c.written < expected) {
          c.written = 0;
          pending.add(c);
        }
      }

      var cursor = 0;
      Future<Chunk?> next() {
        if (cursor >= pending.length) return Future.value(null);
        return Future.value(pending[cursor++]);
      }

      final slots = concurrency.clamp(1, ChunkPlanner.maxConcurrency);
      final workers = <Future<void>>[
        for (var i = 0; i < slots && i < pending.length; i++)
          _worker(run, task.savePath, next),
      ];
      await Future.wait(workers);

      if (run.cancelled) return;
      final done = task.chunks.every((c) => c.written >= (c.end - c.start + 1));
      // 所有分片都在程序目录，必须 merge 才能落到用户目录
      if (done) {
        await _merge(task);
        // ★ 落盘后核对最终文件大小，防止「分片写完但合并失败/写空」显示假完成
        final out = File(task.savePath);
        final size = await out.exists() ? await out.length() : 0;
        if (task.totalBytes > 0 && size != task.totalBytes) {
          throw StateError('落盘大小不符：期望 ${task.totalBytes}，实际 $size');
        }
      }
      task.status = done ? TaskStatus.completed : TaskStatus.failed;
      task.downloadedBytes = planner.totalWritten(task.chunks);
      await repository.save(task);
      _emit(task);
      log?.call('任务 ${task.id} ${task.status.name}, ${task.downloadedBytes} bytes');
    } catch (e) {
      if (!run.cancelled) {
        task.status = TaskStatus.failed;
        task.errorMessage = e.toString();
        await repository.save(task);
        _emit(task);
        log?.call('任务 ${task.id} 失败：$e');
      }
    } finally {
      _running.remove(task.id);
      // ★ 释放并发槽位：拉起排队中的下一个任务
      _startNextPending();
    }
  }

  /// 分片临时文件位置。
  ///
  /// ★ 实测：安全软件会拦截本程序在**用户目录**创建 `xxx.part0`
  ///   （PathAccessException errno 5，用户截图实锤），但允许写「程序目录 / 临时目录」。
  ///   所以分片一律放到程序目录下的临时区，只有最终合并那一次写用户目录。
  /// ★ 单分片时直接写目标文件，完全不建 .part（243KB 这类小文件最常见）。
  String _partPath(String savePath, int index) =>
      partPathFor(savePath, index);

  /// 公开：测试/外部预置已落盘分片时使用（与引擎内部一致）。
  static String partPathFor(String savePath, int index) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final id = savePath.hashCode.abs();
    return '$exeDir${Platform.pathSeparator}sf-parts${Platform.pathSeparator}$id-$index.part';
  }

  /// 把程序目录里的分片落到用户目录。
  ///
  /// ★ 单分片用 `File.copy`（常规文件复制，安全软件通常放行）；
  ///   多分片才逐片写入。若目标目录写入被拒，抛带明确路径的错误（用户能看到）。
  Future<void> _merge(DownloadTask task) async {
    final out = File(task.savePath);
    try {
      if (task.chunks.length == 1) {
        final part = File(_partPath(task.savePath, 0));
        await part.copy(out.path);
      } else {
        final sink = await out.open(mode: FileMode.write);
        try {
          for (final c in task.chunks) {
            final part = File(_partPath(task.savePath, c.index));
            await sink.writeFrom(await part.readAsBytes());
          }
        } finally {
          await sink.close();
        }
      }
    } on FileSystemException catch (e) {
      throw StateError('写入下载目录失败（${e.message}）：${out.path}\n'
          '安全软件可能拦截了本程序写该目录，请把它加入信任区，或在设置里换一个目录');
    }
    for (final c in task.chunks) {
      final part = File(_partPath(task.savePath, c.index));
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> _worker(
    _Running run,
    String savePath,
    Future<Chunk?> Function() next,
  ) async {
    while (!run.cancelled) {
      final chunk = await next();
      if (chunk == null) return;
      await _downloadChunk(run, savePath, chunk);
    }
  }

  Future<void> _downloadChunk(
    _Running run,
    String savePath,
    Chunk chunk,
  ) async {
    final task = run.task;
    // ★ 所有临时写入一律放程序目录（安全软件允许本程序写自身目录），
    //   完成后由 _merge 用 File.copy 落到用户目录 —— 用户实测 errno 5 就发生在
    //   在用户目录创建 xxx.jpg.part0 时。
    final partPath = _partPath(savePath, chunk.index);
    await File(partPath).parent.create(recursive: true);
    final raf = await File(partPath).open(mode: FileMode.write);
    try {
      int attempt = 0;
      while (attempt < maxRetries && !run.cancelled) {
        attempt++;
        final rem = planner.remaining(chunk);
        if (rem == null) return;
        try {
          final headers = <String, dynamic>{
            ...task.headers,
            HttpHeaders.rangeHeader: 'bytes=${rem.start}-${rem.end}',
          };
          final resp = await dio.getUri<List<int>>(
            Uri.parse(task.url),
            options: Options(headers: headers, responseType: ResponseType.bytes),
            cancelToken: run.cancelToken,
            onReceiveProgress: (received, _) {
              if (received <= 0) return;
              // 进度仅用于展示：以「已完成分片 + 本片已收」估算，
              // 不写回 chunk.written（那是断点持久化的已完成字节数，语义不同）。
              final inFlight = received.clamp(0, rem.end - rem.start + 1);
              _emitProgress(task, inFlight);
            },
          );
          // ★ 识别「错误页伪装成 200」：网盘直链缺 Cookie / 已过期时，
          //   CDN 会返回 200 + 几百字节的 JSON/HTML 错误页。
          //   不拦下来用户会看到「已完成 262 B」却打不开文件（实测踩坑）。
          final ct = (resp.headers.value('content-type') ?? '').toLowerCase();
          await _diag('GET chunk${chunk.index} status=${resp.statusCode} '
              'ct=$ct len=${resp.data?.length}');
          if (ct.contains('text/html') || ct.contains('application/json')) {
            throw StateError(
                '服务器返回的是错误页（content-type: $ct），不是文件内容 —— '
                '通常是直链已过期或缺少登录 Cookie');
          }
          final data = resp.data;
          if (data == null) throw StateError('空响应体');
          if (data.length != (rem.end - rem.start + 1)) {
            throw StateError(
                '分片长度不符：期望 ${rem.end - rem.start + 1}，实得 ${data.length}');
          }
          // 分片文件内部从「本片已写字节数」处追加（续传时 >0）
          await raf.setPosition(chunk.written);
          await raf.writeFrom(data);
          chunk.written = rem.end - chunk.start + 1;
          task.downloadedBytes = planner.totalWritten(task.chunks);
          await repository.save(task);
          _emit(task);
          return;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel || run.cancelled) return;
          log?.call('分片 ${chunk.index} 第 $attempt 次失败：${e.message}');
          if (attempt >= maxRetries) rethrow;
          await Future.delayed(Duration(milliseconds: 200 * attempt));
        }
      }
    } finally {
      await raf.close();
    }
  }

  /// 展示用进度（不修改持久化状态，避免并发计数错乱）。
  void _emitProgress(DownloadTask task, int inFlight) {
    final done = planner.totalWritten(task.chunks);
    task.downloadedBytes = done + inFlight;
    _emit(task);
  }

  @override
  Future<void> pause(String taskId) async {
    final run = _running[taskId];
    if (run == null) return;
    run.cancelToken.cancel('paused');
    run.cancelled = true;
    run.task.status = TaskStatus.paused;
    await repository.save(run.task);
    _emit(run.task);
  }

  @override
  Future<void> resume(String taskId) async {
    final run = _running.remove(taskId);
    if (run != null) {
      run.cancelToken.cancel('resumed');
    }
    final tasks = await repository.loadAll();
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    if (task == null) return;
    // 用新 cancelToken 重跑，复用已持久化的分片 written；同样遵守并发上限
    if (_running.length >= maxConcurrentTasks) {
      task.status = TaskStatus.queued;
      _pendingTasks.add(task);
      await repository.save(task);
      _emit(task);
      return;
    }
    _start(task);
  }

  @override
  Future<void> cancel(String taskId, {bool deleteFile = false}) async {
    final run = _running[taskId];
    if (run != null) {
      run.cancelToken.cancel('cancelled');
      run.cancelled = true;
      _running.remove(taskId);
    }
    _pendingTasks.removeWhere((t) => t.id == taskId);

    // ★ 顺序修正：必须先取出任务（拿 savePath）再删记录。
    //   此前先 remove 再 loadAll 查，永远查不到 → deleteFile 静默失效。
    final tasks = await repository.loadAll();
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    await repository.remove(taskId);

    if (deleteFile && task != null) {
      final f = File(task.savePath);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {
          // 文件被占用时忽略：至少任务已移除
        }
      }
      // 顺带清理可能残留的分片
      for (final c in task.chunks) {
        final part = File(_partPath(task.savePath, c.index));
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
    }
    _startNextPending();
  }

  void _emit(DownloadTask task) {
    if (!_progressController.isClosed) _progressController.add(task);
  }

  Future<void> dispose() async {
    for (final r in _running.values) {
      r.cancelToken.cancel('disposed');
      r.cancelled = true;
    }
    _running.clear();
    await _progressController.close();
  }
}

class _Running {
  final DownloadTask task;
  final CancelToken cancelToken = CancelToken();
  bool cancelled = false;
  _Running(this.task);
}
