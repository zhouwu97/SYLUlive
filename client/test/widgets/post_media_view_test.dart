import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

void main() {
  test('信息流竖图缩小并保留右侧帖子点击区域', () {
    final size = calculateSinglePostImageSize(
      availableWidth: 360,
      aspectRatio: 0.75,
      variant: PostMediaVariant.feed,
    );

    expect(size.width, 292.5);
    expect(size.height, 390);
    expect(size.width, lessThan(360));
  });

  test('帖子详情竖图维持原有宽度', () {
    final size = calculateSinglePostImageSize(
      availableWidth: 360,
      aspectRatio: 0.75,
      variant: PostMediaVariant.detail,
    );

    expect(size.width, 360);
    expect(size.height, 420);
  });

  test('信息流横图维持整行宽度', () {
    final size = calculateSinglePostImageSize(
      availableWidth: 360,
      aspectRatio: 1.5,
      variant: PostMediaVariant.feed,
    );

    expect(size.width, 360);
    expect(size.height, 240);
  });
}
