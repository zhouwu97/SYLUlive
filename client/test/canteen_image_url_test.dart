import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/canteen_image_url.dart';
import 'package:shenliyuan/widgets/canteen/canteen_status_image.dart';

void main() {
  test('食堂图片变体只改写 uploads 文件名并保留查询参数', () {
    final url = canteenImageUrl(
      '/uploads/canteen/photo_medium.jpg?version=2',
      variant: CanteenImageVariant.thumb,
    );

    expect(url, contains('/uploads/canteen/photo_thumb.jpg?version=2'));
  });

  test('外部图片地址和原图请求不改写', () {
    const external = 'https://cdn.example.com/photo.jpg?version=2';
    expect(
      canteenImageUrl(external, variant: CanteenImageVariant.thumb),
      external,
    );
    expect(
      canteenImageUrl('/uploads/photo.jpg', variant: CanteenImageVariant.original),
      contains('/uploads/photo.jpg'),
    );
  });

  testWidgets('食堂图片把显示尺寸传给缓存解码器', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 148,
          height: 104,
          child: CanteenStatusImage(
            imageUrl: '/uploads/photo.jpg',
            variant: 'thumb',
            width: 148,
            height: 104,
          ),
        ),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, contains('/uploads/photo_thumb.jpg'));
    expect(image.memCacheWidth, 444);
    expect(image.memCacheHeight, 312);
    expect(image.maxWidthDiskCache, 480);
  });
}
