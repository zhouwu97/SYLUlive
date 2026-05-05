import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class PostImageCache {
  static final CacheManager manager = CacheManager(
    Config(
      'post_image_cache',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 400,
    ),
  );
}
