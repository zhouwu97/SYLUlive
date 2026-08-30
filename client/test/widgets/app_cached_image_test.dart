import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/image_cache_repair.dart';
import 'package:shenliyuan/utils/post_image_cache.dart';
import 'package:shenliyuan/widgets/app_cached_image.dart';

void main() {
  testWidgets('空 URL 不创建网络图片并显示占位', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppCachedImage.public(imageUrl: ''),
        ),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });

  testWidgets('公开图片使用统一缓存管理器和内存尺寸参数', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppCachedImage.public(
            imageUrl: 'https://example.com/thumb.jpg',
            memCacheWidth: 320,
            memCacheHeight: 240,
            maxWidthDiskCache: 640,
            maxHeightDiskCache: 480,
          ),
        ),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.cacheManager, same(PostImageCache.manager));
    expect(image.cacheManager, isA<ImageCacheManager>());
    expect(image.memCacheWidth, 320);
    expect(image.memCacheHeight, 240);
    expect(image.maxWidthDiskCache, 640);
    expect(image.maxHeightDiskCache, 480);
  });

  testWidgets('空 URL 保留调用方占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppCachedImage.public(
            imageUrl: ' ',
            placeholder: (_, __) => const Text('自定义占位'),
          ),
        ),
      ),
    );

    expect(find.text('自定义占位'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('私有图片必须使用调用方提供的缓存、鉴权头和缓存键', (tester) async {
    final customManager = DefaultCacheManager();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppCachedImage.private(
            imageUrl: 'https://example.com/private.jpg',
            cacheManager: customManager,
            httpHeaders: const {'Authorization': 'Bearer private-token'},
            cacheKey: 'private-image-42',
          ),
        ),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.cacheManager, same(customManager));
    expect(image.cacheManager, isNot(same(PostImageCache.manager)));
    expect(image.httpHeaders, const {'Authorization': 'Bearer private-token'});
    expect(image.cacheKey, 'private-image-42');
  });

  test('私有图片拒绝复用公开帖子缓存', () {
    expect(
      () => AppCachedImage.private(
        imageUrl: 'https://example.com/private.jpg',
        cacheManager: PostImageCache.manager,
        httpHeaders: const {'Authorization': 'Bearer private-token'},
        cacheKey: 'private-image-42',
      ),
      throwsArgumentError,
    );
  });

  test('相同缓存文件只会安排一次异步修复', () async {
    final repair = ImageCacheRepair();
    final cacheIdentity = Object();
    var removeCalls = 0;

    repair.scheduleRemove(
      cacheManagerIdentity: cacheIdentity,
      cacheKey: 'broken-image',
      remove: (_) async => removeCalls++,
    );
    repair.scheduleRemove(
      cacheManagerIdentity: cacheIdentity,
      cacheKey: 'broken-image',
      remove: (_) async => removeCalls++,
    );

    await Future<void>.delayed(Duration.zero);

    expect(removeCalls, 1);
  });
}
