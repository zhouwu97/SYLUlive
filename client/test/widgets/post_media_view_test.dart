import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

void main() {
  test('信息流单张3x4竖图精简缩小并留白', () {
    final size = calculateSinglePostImageSize(
      availableWidth: 360,
      aspectRatio: 0.75,
      variant: PostMediaVariant.feed,
    );

    expect(size.width, 210.0);
    expect(size.height, 280.0);
    expect(size.width, lessThan(270));
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

  test('信息流横图限制宽度并左对齐留白', () {
    final size = calculateSinglePostImageSize(
      availableWidth: 360,
      aspectRatio: 1.5,
      variant: PostMediaVariant.feed,
    );

    expect(size.width, 270.0);
    expect(size.height, 180.0);
  });
}
