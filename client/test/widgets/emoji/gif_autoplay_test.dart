import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart' as post_model;
import 'package:shenliyuan/models/reply.dart' as reply_model;
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/utils/image_decode_size.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';
import 'package:shenliyuan/widgets/post_reply/reply_image_media.dart';

import '../../helpers/mock_public_image_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('帖子和回复选择 GIF 原图自动播放，查看器不受静态图大小阈值限制', () {
    final file = post_model.FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/motion.gif',
        size: 634590,
        mimeType: 'image/gif',
        width: 300,
        height: 300);
    final post = post_model.PostImage(
        id: 1,
        postId: 1,
        fileId: 1,
        file: file,
        originUrl: file.path,
        thumbUrl: '/uploads/thumb.png',
        variantStatus: const {'thumb': 'ready'});
    final reply = reply_model.ReplyImage(
        id: 1,
        replyId: 1,
        fileId: 1,
        file: reply_model.FileItem(
            id: 1,
            hash: file.hash,
            path: file.path,
            size: file.size,
            mimeType: file.mimeType,
            width: file.width,
            height: file.height),
        originUrl: file.path,
        thumbUrl: '/uploads/thumb.png',
        variantStatus: const {'thumb': 'ready'});
    const target = ImageDecodeTarget(width: 190, height: 190);
    for (final selection in [
      PostMediaView.resourceForPostImage(post, target),
      ReplyImageMedia.resourceForReplyImage(reply, target),
    ]) {
      expect(selection.variant, ImageResourceVariant.origin);
      expect(selection.url, endsWith('/uploads/motion.gif'));
      expect(selection.shouldResize, isFalse);
    }
    expect(ReplyImageMedia.viewerItemFor(reply).shouldUseOriginalByDefault,
        isTrue);
    expect(
        shouldAutoLoadOriginalByDefault(
            originalSizeBytes: 0, isAnimatedGif: true),
        isTrue);
  });

  testWidgets('本地及内存 GIF 查看器使用原始动画图片源', (tester) async {
    final source = File(
        '../server/internal/handlers/sticker_assets/4093d7cdb944076e0a8e4e06be2e2776.gif');
    final local = ImageViewerItem(localPath: source.absolute.path);
    expect(local.isAnimatedGif, isTrue);
    await tester
        .pumpWidget(MaterialApp(home: ImageViewerScreen(items: [local])));
    final localImage = tester
        .widget<Image>(find.byKey(const ValueKey('viewer-local-image-0')));
    expect(localImage.image, isA<FileImage>());
    final bytes = await tester.runAsync(source.readAsBytes);
    final memory = ImageViewerItem(bytes: bytes!);
    expect(memory.isAnimatedGif, isTrue);
    await tester.pumpWidget(MaterialApp(
        home:
            ImageViewerScreen(key: const ValueKey('memory'), items: [memory])));
    final memoryImage = tester
        .widget<Image>(find.byKey(const ValueKey('viewer-memory-image-0')));
    expect(memoryImage.image, isA<MemoryImage>());
  });

  testWidgets('撒动图在 Flutter 解码时保留所有帧并从稀疏开场播放到完整画面', (tester) async {
    final result = await tester.runAsync(() async {
      final bytes = await File(
              '../server/internal/handlers/sticker_assets/4093d7cdb944076e0a8e4e06be2e2776.gif')
          .readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      expect(codec.frameCount, 62);
      var firstVisible = 0;
      var middleVisible = 0;
      for (var index = 0; index <= 30; index++) {
        final frame = await codec.getNextFrame();
        if (index == 0 || index == 30) {
          final rgba =
              await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
          var count = 0;
          for (var offset = 3; offset < rgba!.lengthInBytes; offset += 4) {
            if (rgba.getUint8(offset) > 0) count++;
          }
          if (index == 0) {
            firstVisible = count;
          } else {
            middleVisible = count;
          }
        }
        frame.image.dispose();
      }
      codec.dispose();
      return (firstVisible, middleVisible);
    });
    expect(result, isNotNull);
    expect(result!.$1, lessThan(5000));
    expect(result.$2, greaterThan(20000));
  });

  testWidgets('评论真实图片组件自动播放网络 GIF', (tester) async {
    final source = File(
        '../server/internal/handlers/sticker_assets/4093d7cdb944076e0a8e4e06be2e2776.gif');
    await tester.runAsync(() async => installMockPublicImageHttp(
        imageBytes: await source.readAsBytes(), imageContentType: 'image/gif'));
    try {
    final file = reply_model.FileItem(
        id: 1,
        hash: 'hash',
        path: '/uploads/playing.gif',
        size: 634590,
        mimeType: 'image/gif',
        width: 300,
        height: 300);
    final reply = reply_model.ReplyImage(
        id: 1,
        replyId: 1,
        fileId: 1,
        file: file,
        originUrl: file.path,
        thumbUrl: '/uploads/preview.png',
        variantStatus: const {'thumb': 'ready'});
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ReplyImageMedia(images: [reply]))));
    await driveMockPublicImageLoads(tester,
        until: () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
    Future<String> pixels() async {
      final frame = tester.widget<RawImage>(find.byType(RawImage)).image!;
      final data = await tester
          .runAsync(() => frame.toByteData(format: ui.ImageByteFormat.rawRgba));
      return sha256
          .convert(
              data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))
          .toString();
    }

    final before = await pixels();
    for (var index = 0; index < 18; index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 35));
    }
    expect(await pixels(), isNot(before), reason: '界面上的 GIF 应随时间切换帧');

      final postFile = post_model.FileItem(id: 1, hash: 'hash', path: file.path,
          size: file.size, mimeType: file.mimeType, width: 300, height: 300);
      final post = post_model.PostImage(id: 1, postId: 1, fileId: 1, file: postFile,
          originUrl: file.path, thumbUrl: '/uploads/preview.png',
          variantStatus: const {'thumb': 'ready'});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
          width: 300, child: PostMediaView(images: [post])))));
      await driveMockPublicImageLoads(tester,
          until: () => find.byType(RawImage).evaluate().isNotEmpty);
      final postImages = tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(postImages.map((image) => image.imageUrl),
          [endsWith('/uploads/playing.gif')], reason: '动画加载完成后不能将静态图叠在透明区域下方');

      final viewerItem = ReplyImageMedia.viewerItemFor(reply);
      await tester.pumpWidget(MaterialApp(home: ImageViewerScreen(items: [viewerItem])));
      final original = find.byKey(const ValueKey('viewer-original-image-0'));
      await driveMockPublicImageLoads(tester, until: () =>
          find.descendant(of: original, matching: find.byType(RawImage)).evaluate().isNotEmpty);
      expect(find.descendant(of: original, matching: find.byType(RawImage)), findsOneWidget);
      expect(find.byType(Image), findsOneWidget,
          reason: '查看器加载完成后不能留下静态预览造成重影');

      final missingFile = reply_model.FileItem(id: 2, hash: 'missing',
          path: '/uploads/missing.gif', size: file.size, mimeType: 'image/gif');
      final unavailable = reply_model.ReplyImage(id: 2, replyId: 1, fileId: 2,
          file: missingFile, originUrl: missingFile.path,
          thumbUrl: '/uploads/preview.png', variantStatus: const {'thumb': 'ready'});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReplyImageMedia(images: [unavailable]))));
      await driveMockPublicImageLoads(tester, until: () => tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .any((image) => image.imageUrl.endsWith('/uploads/preview.png')));
      expect(tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .any((image) => image.imageUrl.endsWith('/uploads/preview.png')), isTrue,
          reason: '动图原图加载失败时应回退已就绪的静态预览');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await flushMockPublicImageTimers(tester);
      uninstallMockPublicImageHttp();
    }
  });
}
