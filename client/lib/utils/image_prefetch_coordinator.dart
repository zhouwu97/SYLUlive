import 'dart:collection';

/// 单个图片预取任务。调用方必须传入与实际展示一致的缓存检查与预取逻辑。
class ImagePrefetchTask {
  const ImagePrefetchTask({
    required this.cacheKey,
    required this.isCached,
    required this.preload,
  });

  final String cacheKey;
  final Future<bool> Function() isCached;
  final Future<void> Function() preload;
}

class _QueuedImagePrefetchTask {
  const _QueuedImagePrefetchTask({
    required this.generation,
    required this.task,
  });

  final int generation;
  final ImagePrefetchTask task;
}

/// 串行执行有限图片预取，并用 generation 丢弃页面失效后的排队任务。
class ImagePrefetchCoordinator {
  final Queue<_QueuedImagePrefetchTask> _queue =
      Queue<_QueuedImagePrefetchTask>();
  final Set<String> _scheduledKeys = <String>{};
  int _generation = 0;
  Future<void>? _drainFuture;

  /// 最多接收 [limit] 个新任务。同一页面 generation 内相同 key 只入队一次。
  Future<void> enqueue(
    Iterable<ImagePrefetchTask> tasks, {
    int limit = 4,
  }) {
    if (limit <= 0) return Future<void>.value();

    var added = 0;
    for (final task in tasks) {
      if (added >= limit) break;
      final scheduledKey = '$_generation:${task.cacheKey}';
      if (!_scheduledKeys.add(scheduledKey)) continue;
      _queue.add(
        _QueuedImagePrefetchTask(generation: _generation, task: task),
      );
      added++;
    }

    _drainFuture ??= _drain();
    return _drainFuture!;
  }

  /// 页面离开或数据源失效时，取消尚未开始的任务。
  void invalidate() {
    _generation++;
    _queue.clear();
    _scheduledKeys.clear();
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final queued = _queue.removeFirst();
        if (queued.generation != _generation) continue;

        var isCached = false;
        try {
          isCached = await queued.task.isCached();
        } catch (_) {
          // 缓存状态不可读时仍允许尝试预取。
        }
        if (isCached || queued.generation != _generation) continue;

        try {
          await queued.task.preload();
        } catch (_) {
          // 单张图片预取失败不能中断后续任务或影响页面展示。
        }
      }
    } finally {
      _drainFuture = null;
    }
  }
}

/// 返回查看器当前页的相邻页下标，最多各一页。
List<int> adjacentImageIndexes({
  required int currentIndex,
  required int itemCount,
  int priorityDirection = 1,
}) {
  if (itemCount <= 1 || currentIndex < 0 || currentIndex >= itemCount) {
    return const <int>[];
  }

  final indexes = <int>[];
  final nextIndex = currentIndex + 1;
  final previousIndex = currentIndex - 1;
  final first = priorityDirection < 0 ? previousIndex : nextIndex;
  final second = priorityDirection < 0 ? nextIndex : previousIndex;
  if (first >= 0 && first < itemCount) indexes.add(first);
  if (second >= 0 && second < itemCount && second != first) {
    indexes.add(second);
  }
  return indexes;
}
