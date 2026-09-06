import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/utils/image_decode_size.dart';
import 'package:shenliyuan/widgets/post_reply/reply_image_media.dart';

void main() {
  test('ReplyImage 解析服务端变体、状态和文件尺寸', () {
    final image = ReplyImage.fromJson({
      'id': 1,
      'reply_id': 2,
      'file_id': 3,
      'file': {
        'id': 3,
        'hash': 'hash',
        'path': '/uploads/origin.jpg',
        'size': 1024 * 1024,
        'mime_type': 'image/jpeg',
        'width': 4000,
        'height': 3000,
      },
      'thumb_url': '/uploads/thumb.jpg',
      'medium_url': '/uploads/medium.jpg',
      'viewer_url': '/uploads/viewer.jpg',
      'origin_url': '/uploads/origin.jpg',
      'variant_status': {
        'thumb': 'ready',
        'medium': 'ready',
        'viewer': 'pending',
      },
    });

    expect(image.resolvedThumbUrl, '/uploads/thumb.jpg');
    expect(image.resolvedMediumUrl, '/uploads/medium.jpg');
    expect(image.resolvedViewerUrl, '/uploads/viewer.jpg');
    expect(image.resolvedOriginUrl, '/uploads/origin.jpg');
    expect(image.file?.width, 4000);
    expect(image.file?.height, 3000);
    expect(image.isVariantReady('thumb'), isTrue);
    expect(image.isVariantReady('viewer'), isFalse);
  });

  testWidgets('回复图片使用缩略图并限制内存解码尺寸', (tester) async {
    final image = ReplyImage(
      id: 1,
      replyId: 2,
      fileId: 3,
      file: FileItem(
        id: 3,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 4 * 1024 * 1024,
        mimeType: 'image/jpeg',
        width: 4000,
        height: 3000,
      ),
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
      originUrl: '/uploads/origin.jpg',
      variantStatus: const {
        'thumb': 'ready',
        'medium': 'ready',
        'viewer': 'pending',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReplyImageMedia(images: [image]),
        ),
      ),
    );

    final rendered = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(rendered.imageUrl, endsWith('/uploads/thumb.jpg'));
    expect(rendered.memCacheWidth, greaterThan(0));
    expect(rendered.memCacheHeight, greaterThan(0));
    expect(rendered.memCacheWidth, lessThanOrEqualTo(480));
    expect(rendered.memCacheHeight, lessThanOrEqualTo(480));
  });

  testWidgets('详情回复图片在高 DPR 下使用 medium 变体', (tester) async {
    final image = ReplyImage(
      id: 1,
      replyId: 2,
      fileId: 3,
      file: FileItem(
        id: 3,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 4 * 1024 * 1024,
        mimeType: 'image/jpeg',
        width: 4000,
        height: 3000,
      ),
      thumbUrl: '/uploads/thumb.jpg',
      mediumUrl: '/uploads/medium.jpg',
      originUrl: '/uploads/origin.jpg',
      variantStatus: const {
        'thumb': 'ready',
        'medium': 'ready',
        'viewer': 'pending',
      },
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3),
        child: MaterialApp(
          home: Scaffold(
            body: ReplyImageMedia(
              images: [image],
              maxDecodeLongEdge: imageMediumLongEdge,
            ),
          ),
        ),
      ),
    );

    final rendered = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(rendered.imageUrl, endsWith('/uploads/medium.jpg'));
    expect(rendered.memCacheWidth, greaterThan(480));
  });

  test('大图变体未就绪时不旁路请求原图', () {
    final image = ReplyImage(
      id: 1,
      replyId: 2,
      fileId: 3,
      file: FileItem(
        id: 3,
        hash: 'hash',
        path: '/uploads/origin.jpg',
        size: 4 * 1024 * 1024,
        mimeType: 'image/jpeg',
      ),
      originUrl: '/uploads/origin.jpg',
      variantStatus: const {
        'thumb': 'pending',
        'medium': 'failed',
        'viewer': 'pending',
      },
    );

    final selection = ReplyImageMedia.resourceForReplyImage(
      image,
      const ImageDecodeTarget(width: 190, height: 190),
    );
    expect(selection.url, isEmpty);
  });
}
