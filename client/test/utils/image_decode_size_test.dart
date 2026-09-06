import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/image_decode_size.dart';

void main() {
  group('calculateImageDecodeTarget', () {
    test('按布局尺寸、DPR 和冗余系数计算目标解码尺寸', () {
      final target = calculateImageDecodeTarget(
        logicalSize: const Size(100, 50),
        devicePixelRatio: 3,
        maxLongEdge: 1280,
        fallbackLogicalSize: const Size(200, 100),
      );

      expect(target.width, 345);
      expect(target.height, 173);
    });

    test('超出上限时保持原始宽高比缩小', () {
      final target = calculateImageDecodeTarget(
        logicalSize: const Size(1000, 500),
        devicePixelRatio: 3,
        maxLongEdge: 1280,
        fallbackLogicalSize: const Size(200, 100),
      );

      expect(target.width, 1280);
      expect(target.height, 640);
    });

    test('空或无限约束回退到场景默认尺寸', () {
      final target = calculateImageDecodeTarget(
        logicalSize: const Size(double.infinity, 0),
        devicePixelRatio: 2,
        maxLongEdge: 1280,
        fallbackLogicalSize: const Size(200, 100),
      );

      expect(target.width, 460);
      expect(target.height, 230);
    });
  });

  group('selectImageResource', () {
    const origin = '/uploads/origin.jpg';
    const thumb = '/uploads/thumb.jpg';
    const medium = '/uploads/medium.jpg';

    test('480px 以内使用缩略图', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 480, height: 320),
        thumbUrl: thumb,
        mediumUrl: medium,
        originUrl: origin,
      );

      expect(selection.variant, ImageResourceVariant.thumb);
      expect(selection.url, thumb);
    });

    test('超过缩略图能力时使用中图', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 720, height: 480),
        thumbUrl: thumb,
        mediumUrl: medium,
        originUrl: origin,
      );

      expect(selection.variant, ImageResourceVariant.medium);
      expect(selection.url, medium);
    });

    test('服务端变体回退为原图时直接选择原图', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 480, height: 320),
        thumbUrl: origin,
        mediumUrl: origin,
        originUrl: origin,
      );

      expect(selection.variant, ImageResourceVariant.origin);
      expect(selection.url, origin);
    });

    test('GIF 默认选择原图且不缩放，保持旧调用兼容', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 480, height: 320),
        thumbUrl: thumb,
        mediumUrl: medium,
        originUrl: origin,
        isAnimatedGif: true,
      );

      expect(selection.variant, ImageResourceVariant.origin);
      expect(selection.url, origin);
      expect(selection.shouldResize, isFalse);
    });

    test('静态 GIF 预览启用后选择 ready 变体，不旁路到原图', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 720, height: 480),
        thumbUrl: thumb,
        mediumUrl: medium,
        originUrl: origin,
        isAnimatedGif: true,
        allowStaticAnimatedPreview: true,
        allowOriginFallback: false,
      );

      expect(selection.variant, ImageResourceVariant.medium);
      expect(selection.url, medium);
      expect(selection.shouldResize, isTrue);
    });

    test('大图变体 pending/failed 时返回不可用，不把 origin 当预览', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 480, height: 320),
        thumbUrl: origin,
        mediumUrl: origin,
        originUrl: origin,
        thumbReady: false,
        mediumReady: false,
        viewerReady: false,
        allowOriginFallback: false,
      );

      expect(selection.variant, ImageResourceVariant.unavailable);
      expect(selection.url, isEmpty);
    });

    test('目标档位未 ready 时回退到更低的 ready 变体', () {
      final selection = selectImageResource(
        target: const ImageDecodeTarget(width: 1280, height: 900),
        thumbUrl: thumb,
        mediumUrl: origin,
        originUrl: origin,
        mediumReady: false,
        viewerReady: false,
        allowOriginFallback: false,
      );

      expect(selection.variant, ImageResourceVariant.thumb);
      expect(selection.url, thumb);
    });
  });
}
