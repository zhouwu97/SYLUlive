import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

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

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
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

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
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

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
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
    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
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

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
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

    final cached = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(cached.alignment, Alignment.center);
    expect(cached.fit, BoxFit.cover);
    expect(find.text('长图'), findsNothing);
  });

  testWidgets('homeFeed 多图瓦片顶部对齐', (tester) async {
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

    final tiles = tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.alignment, Alignment.topCenter);
      expect(tile.fit, BoxFit.cover);
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
    }
  });
}
