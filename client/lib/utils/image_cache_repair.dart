/// 延迟修复确定损坏的磁盘缓存，避免错误构建触发重复删除。
typedef CachedFileRemover = Future<void> Function(String cacheKey);

class ImageCacheRepair {
  final Set<String> _scheduledKeys = <String>{};

  /// 同一个缓存管理器中的文件在一次应用生命周期内只安排一次删除。
  void scheduleRemove({
    required Object cacheManagerIdentity,
    required String cacheKey,
    required CachedFileRemover remove,
  }) {
    final repairKey = '${identityHashCode(cacheManagerIdentity)}:$cacheKey';
    if (!_scheduledKeys.add(repairKey)) return;

    Future<void>.microtask(() async {
      try {
        await remove(cacheKey);
      } catch (_) {
        // 删除失败时允许后续展示周期再次尝试修复。
        _scheduledKeys.remove(repairKey);
      }
    });
  }
}
