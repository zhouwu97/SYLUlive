import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

List<PostImage> _createTestImages(int count) {
  return List.generate(
    count,
    (index) => PostImage(
      id: index + 1,
      postId: 1,
      fileId: index + 1,
      originUrl: '/uploads/image-$index.jpg',
    ),
  );
}

Widget _buildDetailMedia(List<PostImage> images) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 360,
        child: PostMediaView(
          images: images,
          variant: PostMediaVariant.detail,
        ),
      ),
    ),
  );
}

void main() {
  group('calculateSinglePostImageSize', () {
    test('16:9 横图', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 16 / 9,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(140.625, 0.01));
    });

    test('4:3 横图', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 4 / 3,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(187.5, 0.01));
    });

    test('1:1 方图', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 1.0,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(220.0, 0.01));
      expect(size.height, closeTo(220.0, 0.01));
    });

    test('3:4 竖图', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 3 / 4,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(165.0, 0.01));
      expect(size.height, closeTo(220.0, 0.01));
    });

    test('9:16 长竖图', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 9 / 16,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(123.75, 0.01));
      expect(size.height, closeTo(220.0, 0.01));
    });

    test('极端横图 aspectRatio=3', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 3.0,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(138.89, 0.01));
    });

    test('极端竖图 aspectRatio=0.2', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 400,
        aspectRatio: 0.2,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(121.0, 0.01));
      expect(size.height, closeTo(220.0, 0.01));
    });

    test('detail 模式不受此次修改影响', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 360,
        aspectRatio: 0.75,
        variant: PostMediaVariant.detail,
      );

      expect(size.width, 360);
      expect(size.height, 420);
    });

    test('较窄 availableWidth 时能够按 availableWidth*0.70 自适应', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 300,
        aspectRatio: 16 / 9,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(210.0, 0.01));
      expect(size.height, closeTo(118.125, 0.01));
    });

    test('极窄 availableWidth 下不会发生 clamp 上下界异常', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 80,
        aspectRatio: 1.0,
        variant: PostMediaVariant.feed,
      );

      expect(size.width, closeTo(56.0, 0.01));
      expect(size.height, closeTo(56.0, 0.01));
    });

    test('homeFeed 方图统一预览宽度并保持比例', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 1.0,
        variant: PostMediaVariant.homeFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(250.0, 0.01));
    });

    test('homeFeed 16:9 横图统一预览宽度并保持比例', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 16 / 9,
        variant: PostMediaVariant.homeFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(140.625, 0.01));
    });

    test('homeFeed 4:3 横图统一预览宽度并保持比例', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 4 / 3,
        variant: PostMediaVariant.homeFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(187.5, 0.01));
    });

    test('homeFeed 3:4 竖图保持原比例，不再铺满内容列', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 3 / 4,
        variant: PostMediaVariant.homeFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(333.333, 0.01));
    });

    test('homeFeed 长图封顶为 3:4 竖向预览框', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 9 / 16,
        variant: PostMediaVariant.homeFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(333.333, 0.01));
    });

    test('sectionFeed 与首页共享长图预览规则', () {
      final size = calculateSinglePostImageSize(
        availableWidth: 390,
        aspectRatio: 9 / 16,
        variant: PostMediaVariant.sectionFeed,
      );

      expect(size.width, closeTo(250.0, 0.01));
      expect(size.height, closeTo(333.333, 0.01));
    });
  });

  testWidgets('外层帖子点击回调优先于图片查看器', (tester) async {
    var tapped = false;
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      originUrl: '/uploads/test.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: [image],
              variant: PostMediaVariant.homeFeed,
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('single-post-image-tap-target')),
    );

    expect(tapped, isTrue);
    expect(find.byType(PostMediaView), findsOneWidget);
  });

  testWidgets('帖子图片进入查看器时传递分层资源和原图大小', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1024 * 1024,
        mimeType: 'image/jpeg',
        width: 1600,
        height: 900,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
      viewerUrl: '/uploads/viewer.jpg',
      variantStatus: const {
        'thumb': 'ready',
        'medium': 'ready',
        'viewer': 'ready',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(images: [image]),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('single-post-image-tap-target')),
    );
    await tester.pumpAndSettle();

    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    final item = viewer.items!.single;
    expect(item.useProgressiveLoading, isTrue);
    expect(item.previewUrl, contains('/uploads/medium.jpg'));
    expect(item.viewerUrl, contains('/uploads/viewer.jpg'));
    expect(item.originalUrl, contains('/uploads/origin.jpg'));
    expect(item.originalSizeBytes, 1024 * 1024);
  });

  testWidgets('变体未就绪时进入查看器不把回退 origin 当预览', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1024 * 1024,
        mimeType: 'image/jpeg',
        width: 1600,
        height: 900,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/origin.jpg',
      mediumUrl: '/uploads/origin.jpg',
      viewerUrl: '/uploads/origin.jpg',
      variantStatus: const {
        'thumb': 'pending',
        'medium': 'pending',
        'viewer': 'pending',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(images: [image]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('single-post-image-tap-target')),
    );
    await tester.pumpAndSettle();

    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    final item = viewer.items!.single;
    expect(item.previewUrl, isNull);
    expect(item.viewerUrl, isNull);
    expect(item.thumbUrl, isNull);
    expect(item.originalUrl, contains('/uploads/origin.jpg'));
  });

  testWidgets('低分辨率 Feed 单图使用 thumb 并限制解码尺寸', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);

    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 1600,
        height: 900,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(images: [image]),
          ),
        ),
      ),
    );

    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/thumb.jpg'));
    expect(cached.imageUrl, contains('/uploads/thumb.jpg'));
    expect(cached.memCacheWidth, 288);
    expect(cached.memCacheHeight, 162);
  });

  testWidgets('3x 首页单图使用 medium 并限制解码尺寸', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 1600,
        height: 900,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: [image],
              variant: PostMediaVariant.homeFeed,
            ),
          ),
        ),
      ),
    );

    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/medium.jpg'));
    expect(cached.imageUrl, contains('/uploads/medium.jpg'));
    expect(cached.memCacheWidth, 863);
    expect(cached.memCacheHeight, 486);
  });

  testWidgets('3x 长图解码保持原图比例不压扁', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 900,
        height: 1600,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: [image],
              variant: PostMediaVariant.homeFeed,
            ),
          ),
        ),
      ),
    );

    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/medium.jpg'));
    expect(cached.imageUrl, contains('/uploads/medium.jpg'));
    // 250 宽按 9:16 展开 444.4 逻辑高，×3×1.15 后长边封顶 1280，比例保持 0.5625。
    expect(cached.memCacheWidth, 720);
    expect(cached.memCacheHeight, 1280);
  });

  testWidgets('长图在深色模式和 1.3x 文字缩放下不发生布局异常', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 900,
        height: 1600,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: SizedBox(
                width: 360,
                child: PostMediaView(
                  images: [image],
                  variant: PostMediaVariant.homeFeed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('长图'), findsOneWidget);
    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/medium.jpg'));
    expect(cached.alignment, Alignment.topCenter);
    expect(cached.fit, BoxFit.cover);
    expect(tester.takeException(), isNull);
  });

  testWidgets('homeFeed 普通竖图居中显示且不出现长图角标', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 750,
        height: 1000,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: [image],
              variant: PostMediaVariant.homeFeed,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/medium.jpg'));
    expect(cached.alignment, Alignment.center);
    expect(cached.fit, BoxFit.contain);
    expect(find.text('长图'), findsNothing);
  });

  testWidgets('detail 保持 0.70 长图阈值，0.72 竖图仍居中裁剪', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 1,
        mimeType: 'image/jpeg',
        width: 720,
        height: 1000,
      ),
      originUrl: '/uploads/origin.jpg',
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: [image],
              variant: PostMediaVariant.detail,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final cached = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .firstWhere((image) => image.imageUrl.contains('/uploads/medium.jpg'));
    expect(cached.alignment, Alignment.center);
    expect(cached.fit, BoxFit.cover);
    expect(find.text('长图'), findsNothing);
  });

  testWidgets('Feed/详情大图变体 pending 或 failed 时不请求 origin', (tester) async {
    final image = PostImage(
      id: 1,
      postId: 1,
      fileId: 1,
      file: FileItem(
        id: 1,
        hash: 'pending-hash',
        path: '/uploads/pending-origin.jpg',
        size: 4 * 1024 * 1024,
        mimeType: 'image/jpeg',
        width: 1600,
        height: 900,
      ),
      originUrl: '/uploads/pending-origin.jpg',
      // 服务端未 ready 时会把这些字段回退为 origin URL。
      thumbUrl: '/uploads/pending-origin.jpg',
      mediumUrl: '/uploads/pending-origin.jpg',
      variantStatus: const {
        'thumb': 'pending',
        'medium': 'failed',
        'viewer': 'pending',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(images: [image]),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('homeFeed 多图瓦片顶部对齐并保持原图比例解码', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    final images = List.generate(2, (index) {
      return PostImage(
        id: index + 1,
        postId: 1,
        fileId: index + 1,
        file: FileItem(
          id: index + 1,
          hash: 'hash$index',
          path: '/uploads/img$index.jpg',
          size: 1,
          mimeType: 'image/jpeg',
          width: 1080,
          height: 1920,
        ),
        originUrl: '/uploads/img$index.jpg',
        thumbUrl: '/uploads/img$index-thumb.jpg',
        mediumUrl: '/uploads/img$index-medium.jpg',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: images,
              variant: PostMediaVariant.homeFeed,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final tiles = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .where((image) => image.imageUrl.contains('-medium.jpg'))
        .toList();
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.alignment, Alignment.topCenter);
      expect(tile.fit, BoxFit.cover);
      // 193×195 瓦片按 9:16 源宽度占满展开 (193, 343.11)，×3×1.15 = 666×1184。
      expect(tile.imageUrl, contains('-medium.jpg'));
      expect(tile.memCacheWidth, 666);
      expect(tile.memCacheHeight, 1184);
    }
  });

  testWidgets('homeFeed 横图瓦片按高度占满解码保持比例', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    final images = List.generate(2, (index) {
      return PostImage(
        id: index + 1,
        postId: 1,
        fileId: index + 1,
        file: FileItem(
          id: index + 1,
          hash: 'hash$index',
          path: '/uploads/img$index.jpg',
          size: 1,
          mimeType: 'image/jpeg',
          width: 1920,
          height: 1080,
        ),
        originUrl: '/uploads/img$index.jpg',
        thumbUrl: '/uploads/img$index-thumb.jpg',
        mediumUrl: '/uploads/img$index-medium.jpg',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: images,
              variant: PostMediaVariant.homeFeed,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final tiles = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .where((image) => image.imageUrl.contains('-medium.jpg'))
        .toList();
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      // 16:9 源高度占满 195，展开 (346.67, 195)，×3×1.15 = 1196×673。
      expect(tile.imageUrl, contains('-medium.jpg'));
      expect(tile.memCacheWidth, 1196);
      expect(tile.memCacheHeight, 673);
    }
  });

  testWidgets('feed 多图瓦片保持居中对齐（防越界回归）', (tester) async {
    final images = List.generate(2, (index) {
      return PostImage(
        id: index + 1,
        postId: 1,
        fileId: index + 1,
        file: FileItem(
          id: index + 1,
          hash: 'hash$index',
          path: '/uploads/img$index.jpg',
          size: 1,
          mimeType: 'image/jpeg',
          width: 1080,
          height: 1920,
        ),
        originUrl: '/uploads/img$index.jpg',
        thumbUrl: '/uploads/img$index-thumb.jpg',
        mediumUrl: '/uploads/img$index-medium.jpg',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(images: images),
          ),
        ),
      ),
    );
    await tester.pump();

    final tiles = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.alignment, Alignment.center);
      // feed 瓦片解码保持历史行为：138×140 框比例 ×3×1.15 封顶 480 → 474×480。
      expect(tile.imageUrl, contains('-thumb.jpg'));
      expect(tile.memCacheWidth, 474);
      expect(tile.memCacheHeight, 480);
    }
  });

  testWidgets('detail 多图瓦片解码保持历史行为（防越界回归）', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    final images = List.generate(2, (index) {
      return PostImage(
        id: index + 1,
        postId: 1,
        fileId: index + 1,
        file: FileItem(
          id: index + 1,
          hash: 'hash$index',
          path: '/uploads/img$index.jpg',
          size: 1,
          mimeType: 'image/jpeg',
          width: 1080,
          height: 1920,
        ),
        originUrl: '/uploads/img$index.jpg',
        thumbUrl: '/uploads/img$index-thumb.jpg',
        mediumUrl: '/uploads/img$index-medium.jpg',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: PostMediaView(
              images: images,
              variant: PostMediaVariant.detail,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final tiles = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.alignment, Alignment.center);
      // detail 瓦片解码保持历史行为：193×195 框比例 ×3×1.15 封顶 480 → 475×480。
      expect(tile.imageUrl, contains('-thumb.jpg'));
      expect(tile.memCacheWidth, 475);
      expect(tile.memCacheHeight, 480);
    }
  });

  for (final imageCount in [6, 7, 8, 9]) {
    testWidgets('详情页 $imageCount 张图片完整显示', (tester) async {
      await tester.pumpWidget(_buildDetailMedia(_createTestImages(imageCount)));
      await tester.pump();

      final gridFinder = find.byType(GridView);
      final aspectRatio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      final lastTileFinder = find.byKey(
        ValueKey<String>('post-media-tile-${imageCount - 1}'),
      );

      expect(gridFinder, findsOneWidget);
      expect(lastTileFinder, findsOneWidget);
      expect(aspectRatio.aspectRatio, imageCount <= 6 ? 1.5 : 1.0);

      final gridRect = tester.getRect(gridFinder);
      final lastTileRect = tester.getRect(lastTileFinder);
      expect(lastTileRect.bottom, lessThanOrEqualTo(gridRect.bottom + 0.01));
    });
  }

  testWidgets('详情页点击第 9 张图片会打开完整查看器', (tester) async {
    await tester.pumpWidget(_buildDetailMedia(_createTestImages(9)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('post-media-tile-8')));
    await tester.pumpAndSettle();

    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    expect(viewer.items, hasLength(9));
    expect(viewer.initialIndex, 8);
  });
}
