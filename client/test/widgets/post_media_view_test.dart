import 'package:flutter_test/flutter_test.dart';
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
  });
}
