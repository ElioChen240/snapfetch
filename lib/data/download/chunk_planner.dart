import '../../domain/parser.dart';

/// 分片规划（PRD §2.1 红线 5）：规划必须固定并持久化，
/// 否则重启后分片边界变化会让断点续传失效。
///
/// 规则：
/// - 目标分片数 = min(并发上限, ceil(totalBytes / minChunkSize))，至少 1
/// - 每片 [start, end] 闭区间，最后一片吃到 totalBytes-1
/// - 不支持 Range 的源站退化为单分片
class ChunkPlanner {
  /// 单片目标体积：小于 1 MiB 的文件不拆片（请求开销大于收益），
  /// 大文件按此体积切分，最多 [maxConcurrency] 片。
  static const int minChunkSize = 1 << 20; // 1 MiB

  /// 全局并发上限（官方行为，PRD §4.1 第 4 项）。
  static const int maxConcurrency = 32;

  const ChunkPlanner();

  List<Chunk> plan({
    required int totalBytes,
    required int concurrency,
    required bool supportsRange,
  }) {
    if (totalBytes <= 0) {
      return [Chunk(index: 0, start: 0, end: -1)];
    }
    if (!supportsRange) {
      return [Chunk(index: 0, start: 0, end: totalBytes - 1)];
    }

    final c = concurrency.clamp(1, maxConcurrency).toInt();
    // 每约 1 MiB 一片，最多 c 片；小文件自然退化为 1 片。
    final count = (totalBytes / minChunkSize).ceil().clamp(1, c).toInt();
    final size = (totalBytes / count).ceil();

    final chunks = <Chunk>[];
    for (var i = 0; i < count; i++) {
      final start = i * size;
      if (start >= totalBytes) break;
      final end = (start + size - 1).clamp(0, totalBytes - 1).toInt();
      chunks.add(Chunk(index: chunks.length, start: start, end: end));
    }
    return chunks;
  }

  /// 续传时复用的规划：保留已完成分片的 written，其余从 start+written 继续。
  /// 返回每片实际需要发起的 Range 请求区间；null 表示该片已完成。
  ({int start, int end})? remaining(Chunk c) {
    final from = c.start + c.written;
    if (from > c.end) return null;
    return (start: from, end: c.end);
  }

  int totalWritten(List<Chunk> chunks) =>
      chunks.fold<int>(0, (sum, c) => sum + c.written);
}
