import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PostOriginalCache 配置为 7 天 50 项，与展示缓存隔离', () {
    expect(PostOriginalCache.stalePeriod, const Duration(days: 7));
    expect(PostOriginalCache.maxNrOfCacheObjects, 50);
    expect(PostImageCache.stalePeriod, const Duration(days: 30));
    expect(PostImageCache.maxNrOfCacheObjects, 800);
  });

  test('PostOriginalCache.manager 返回同一实例且可重置', () {
    PostOriginalCache.resetInstance();
    final first = PostOriginalCache.manager;
    expect(identical(first, PostOriginalCache.manager), isTrue);
    PostOriginalCache.resetInstance();
    expect(identical(first, PostOriginalCache.manager), isFalse);
  });
}
