import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/image_prefetch_coordinator.dart';

void main() {
  ImagePrefetchTask task({
    required String key,
    Future<bool> Function()? isCached,
    Future<void> Function()? preload,
  }) {
    return ImagePrefetchTask(
      cacheKey: key,
      isCached: isCached ?? () async => false,
      preload: preload ?? () async {},
    );
  }

  test('每次入队最多接收请求限制内的任务', () async {
    final coordinator = ImagePrefetchCoordinator();
    final executed = <String>[];

    await coordinator.enqueue(
      List<ImagePrefetchTask>.generate(
        6,
        (index) => task(
          key: 'image-$index',
          preload: () async => executed.add('image-$index'),
        ),
      ),
      limit: 4,
    );

    expect(executed, ['image-0', 'image-1', 'image-2', 'image-3']);
  });

  test('磁盘缓存命中时不重复预取', () async {
    final coordinator = ImagePrefetchCoordinator();
    var preloadCalls = 0;

    await coordinator.enqueue([
      task(
        key: 'cached-image',
        isCached: () async => true,
        preload: () async => preloadCalls++,
      ),
    ]);

    expect(preloadCalls, 0);
  });

  test('页面失效后跳过尚未开始的预取任务', () async {
    final coordinator = ImagePrefetchCoordinator();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final executed = <String>[];

    final pending = coordinator.enqueue([
      task(
        key: 'first',
        preload: () async {
          executed.add('first');
          firstStarted.complete();
          await releaseFirst.future;
        },
      ),
      task(
        key: 'second',
        preload: () async => executed.add('second'),
      ),
    ]);

    await firstStarted.future;
    coordinator.invalidate();
    releaseFirst.complete();
    await pending;

    expect(executed, ['first']);
  });

  test('查看器只返回当前页相邻一页', () {
    expect(adjacentImageIndexes(currentIndex: 0, itemCount: 3), [1]);
    expect(adjacentImageIndexes(currentIndex: 1, itemCount: 3), [0, 2]);
    expect(adjacentImageIndexes(currentIndex: 2, itemCount: 3), [1]);
    expect(adjacentImageIndexes(currentIndex: 0, itemCount: 1), isEmpty);
  });
}
