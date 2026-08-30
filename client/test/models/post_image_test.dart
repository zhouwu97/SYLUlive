import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';

void main() {
  test('PostImage 解析服务端变体状态并区分未就绪 viewer', () {
    final image = PostImage.fromJson({
      'id': 1,
      'post_id': 2,
      'file_id': 3,
      'file': {
        'id': 3,
        'hash': 'hash',
        'path': '/uploads/origin.jpg',
        'size': 1024 * 1024,
        'mime_type': 'image/jpeg',
      },
      'thumb_url': '/uploads/thumb.jpg',
      'medium_url': '/uploads/medium.jpg',
      'viewer_url': '/uploads/origin.jpg',
      'origin_url': '/uploads/origin.jpg',
      'variant_status': {
        'thumb': 'ready',
        'medium': 'ready',
        'viewer': 'pending',
      },
    });

    expect(image.variantStatus['thumb'], 'ready');
    expect(image.isVariantReady('thumb'), isTrue);
    expect(image.isVariantReady('medium'), isTrue);
    expect(image.isVariantReady('viewer'), isFalse);
    expect(image.file?.size, 1024 * 1024);
  });

  test('没有变体状态时兼容旧接口的非回退 URL', () {
    final image = PostImage.fromJson({
      'file': {
        'path': '/uploads/origin.jpg',
      },
      'medium_url': '/uploads/medium.jpg',
      'origin_url': '/uploads/origin.jpg',
    });

    expect(image.isVariantReady('medium'), isTrue);
    expect(image.variantStatus, isEmpty);
  });
}
