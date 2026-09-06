import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class PostImageCache {
  static const stalePeriod = Duration(days: 30);
  static const maxNrOfCacheObjects = 800;

  static CacheManager? _instance;

  static CacheManager get manager => _instance ??= _PostImageCacheManager(
        Config(
          'post_image_cache',
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxNrOfCacheObjects,
        ),
      );

  /// 缓存管理器绑定创建时的磁盘目录；目录被删除后实例会静默失效
  /// （加载不产生任何事件）。测试中 mock 目录随 teardown 删除，必须重建。
  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }
}

/// 公开图片缓存需要支持磁盘尺寸约束；`cached_network_image` 会在收到
/// `maxWidthDiskCache` / `maxHeightDiskCache` 时检查这个能力。
class _PostImageCacheManager extends CacheManager with ImageCacheManager {
  _PostImageCacheManager(super.config);
}

/// “查看原图”独立缓存：短生命周期、小容量，只服务原图下载结果。
/// 与 [PostImageCache]（缩略图/预览，30 天 800 项）隔离，避免大体积
/// 原图把信息流缩略图挤出缓存。
class PostOriginalCache {
  static const stalePeriod = Duration(days: 7);
  static const maxNrOfCacheObjects = 50;

  static CacheManager? _instance;

  static CacheManager get manager => _instance ??= _PostOriginalCacheManager(
        Config(
          'post_original_cache',
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxNrOfCacheObjects,
        ),
      );

  /// 缓存管理器绑定创建时的磁盘目录；目录被删除后实例会静默失效
  /// （加载不产生任何事件）。测试中 mock 目录随 teardown 删除，必须重建。
  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }
}

class _PostOriginalCacheManager extends CacheManager {
  _PostOriginalCacheManager(super.config);
}
