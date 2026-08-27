import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 图片内存解码目标。宽高始终为有效的物理像素。
class ImageDecodeTarget {
  const ImageDecodeTarget({required this.width, required this.height});

  final int width;
  final int height;

  int get longEdge => math.max(width, height);
}

/// 帖子图片的展示资源档位。
enum ImageResourceVariant { thumb, medium, origin }

/// 已按显示像素选择的图片资源及其解码规则。
class ImageResourceSelection {
  const ImageResourceSelection({
    required this.variant,
    required this.url,
    required this.shouldResize,
  });

  final ImageResourceVariant variant;
  final String url;
  final bool shouldResize;
}

const double _decodeOverscan = 1.15;
const int imageThumbLongEdge = 480;
const int imageMediumLongEdge = 1280;
const int imageViewerLongEdge = 2048;

/// 按布局尺寸、设备 DPR 和冗余系数计算目标解码尺寸。
///
/// 无效或无限约束使用 [fallbackLogicalSize]，并在 [maxLongEdge] 内等比缩小。
ImageDecodeTarget calculateImageDecodeTarget({
  required Size logicalSize,
  required double devicePixelRatio,
  required int maxLongEdge,
  required Size fallbackLogicalSize,
}) {
  final sourceSize = _isUsableSize(logicalSize)
      ? logicalSize
      : (_isUsableSize(fallbackLogicalSize)
          ? fallbackLogicalSize
          : const Size(1, 1));
  final safeDpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  final safeMaxLongEdge = math.max(1, maxLongEdge);
  final rawWidth = math.max(
    1,
    (sourceSize.width * safeDpr * _decodeOverscan).ceil(),
  );
  final rawHeight = math.max(
    1,
    (sourceSize.height * safeDpr * _decodeOverscan).ceil(),
  );
  final rawLongEdge = math.max(rawWidth, rawHeight);

  if (rawLongEdge <= safeMaxLongEdge) {
    return ImageDecodeTarget(width: rawWidth, height: rawHeight);
  }

  final scale = safeMaxLongEdge / rawLongEdge;
  return ImageDecodeTarget(
    width: math.max(1, (rawWidth * scale).round()),
    height: math.max(1, (rawHeight * scale).round()),
  );
}

/// 按实际需要的物理长边选择帖子图片资源。
///
/// 服务端未生成变体时会将变体 URL 回退为原图 URL；此处直接返回原图，
/// 避免客户端把回退资源误判为可用的缩略图。GIF 必须保留原图动画。
ImageResourceSelection selectImageResource({
  required ImageDecodeTarget target,
  required String thumbUrl,
  required String mediumUrl,
  required String originUrl,
  bool isAnimatedGif = false,
}) {
  if (isAnimatedGif || originUrl.isEmpty) {
    return ImageResourceSelection(
      variant: ImageResourceVariant.origin,
      url: originUrl,
      shouldResize: false,
    );
  }

  if (target.longEdge <= imageThumbLongEdge &&
      thumbUrl.isNotEmpty &&
      thumbUrl != originUrl) {
    return ImageResourceSelection(
      variant: ImageResourceVariant.thumb,
      url: thumbUrl,
      shouldResize: true,
    );
  }

  if (target.longEdge <= imageMediumLongEdge &&
      mediumUrl.isNotEmpty &&
      mediumUrl != originUrl) {
    return ImageResourceSelection(
      variant: ImageResourceVariant.medium,
      url: mediumUrl,
      shouldResize: true,
    );
  }

  return ImageResourceSelection(
    variant: ImageResourceVariant.origin,
    url: originUrl,
    shouldResize: true,
  );
}

bool _isUsableSize(Size size) {
  return size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;
}
