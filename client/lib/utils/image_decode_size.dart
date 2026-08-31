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
enum ImageResourceVariant { thumb, medium, viewer, origin, unavailable }

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
/// 服务端未生成变体时会将变体 URL 回退为原图 URL；调用方应通过 *Ready
/// 参数明确告诉选择器哪些档位可用，避免把回退资源误判为可用的缩略图。
///
/// 默认参数保留旧调用方的“没有额外状态信息时允许原图兜底”行为。Feed/详情
/// 等掌握 `variant_status` 的入口应关闭原图兜底，以免 pending/failed 变体把大
/// 原图带入普通信息流。GIF 默认仍选择原图；服务端提供 JPEG 静态首帧时，
/// 入口可通过 [allowStaticAnimatedPreview] 显式开启静态预览。
ImageResourceSelection selectImageResource({
  required ImageDecodeTarget target,
  required String thumbUrl,
  required String mediumUrl,
  required String originUrl,
  String viewerUrl = '',
  bool isAnimatedGif = false,
  bool thumbReady = true,
  bool mediumReady = true,
  bool viewerReady = true,
  bool allowOriginFallback = true,
  bool allowStaticAnimatedPreview = false,
}) {
  final canUseAnimatedPreview = !isAnimatedGif || allowStaticAnimatedPreview;
  final candidates = <ImageResourceSelection>[];

  void addCandidate({
    required ImageResourceVariant variant,
    required String url,
    required bool ready,
  }) {
    if (!canUseAnimatedPreview || !ready || url.isEmpty || url == originUrl) {
      return;
    }
    candidates.add(
      ImageResourceSelection(
        variant: variant,
        url: url,
        shouldResize: true,
      ),
    );
  }

  void addFallbackCandidates() {
    addCandidate(
      variant: ImageResourceVariant.viewer,
      url: viewerUrl,
      ready: viewerReady,
    );
    addCandidate(
      variant: ImageResourceVariant.medium,
      url: mediumUrl,
      ready: mediumReady,
    );
    addCandidate(
      variant: ImageResourceVariant.thumb,
      url: thumbUrl,
      ready: thumbReady,
    );
  }

  if (target.longEdge <= imageThumbLongEdge) {
    addCandidate(
      variant: ImageResourceVariant.thumb,
      url: thumbUrl,
      ready: thumbReady,
    );
    addCandidate(
      variant: ImageResourceVariant.medium,
      url: mediumUrl,
      ready: mediumReady,
    );
    addCandidate(
      variant: ImageResourceVariant.viewer,
      url: viewerUrl,
      ready: viewerReady,
    );
  } else if (target.longEdge <= imageMediumLongEdge) {
    addCandidate(
      variant: ImageResourceVariant.medium,
      url: mediumUrl,
      ready: mediumReady,
    );
    addCandidate(
      variant: ImageResourceVariant.viewer,
      url: viewerUrl,
      ready: viewerReady,
    );
    addCandidate(
      variant: ImageResourceVariant.thumb,
      url: thumbUrl,
      ready: thumbReady,
    );
  } else {
    addFallbackCandidates();
  }

  if (candidates.isNotEmpty) return candidates.first;

  if (allowOriginFallback && originUrl.isNotEmpty) {
    return ImageResourceSelection(
      variant: ImageResourceVariant.origin,
      url: originUrl,
      shouldResize: !isAnimatedGif,
    );
  }

  return const ImageResourceSelection(
    variant: ImageResourceVariant.unavailable,
    url: '',
    shouldResize: false,
  );
}

bool _isUsableSize(Size size) {
  return size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;
}
