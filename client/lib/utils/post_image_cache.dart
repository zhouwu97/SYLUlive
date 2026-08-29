import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class PostImageCache {
  static const stalePeriod = Duration(days: 30);
  static const maxNrOfCacheObjects = 800;

  static final CacheManager manager = _PostImageCacheManager(
    Config(
      'post_image_cache',
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxNrOfCacheObjects,
    ),
  );
}

/// 公开图片缓存需要支持磁盘尺寸约束；`cached_network_image` 会在收到
/// `maxWidthDiskCache` / `maxHeightDiskCache` 时检查这个能力。
class _PostImageCacheManager extends CacheManager with ImageCacheManager {
  _PostImageCacheManager(super.config);
}
