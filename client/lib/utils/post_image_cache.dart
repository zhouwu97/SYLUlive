import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class PostImageCache {
  static const stalePeriod = Duration(days: 30);
  static const maxNrOfCacheObjects = 800;

  static final CacheManager manager = CacheManager(
    Config(
      'post_image_cache',
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxNrOfCacheObjects,
    ),
  );
}
