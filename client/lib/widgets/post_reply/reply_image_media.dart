import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/reply.dart';
import '../../screens/image_viewer_screen.dart';
import '../../utils/image_decode_size.dart';
import '../../utils/post_image_cache.dart';

/// 回复图片的分层预览组件。
///
/// 普通回复只请求 thumb/medium 变体，并按实际瓦片尺寸限制位图解码；
/// 用户打开查看器后才使用完整的分层资源链路。
class ReplyImageMedia extends StatelessWidget {
  const ReplyImageMedia({
    super.key,
    required this.images,
    this.onImageLongPress,
    this.singleImageSize = 190,
    this.multiImageSize = 88,
    this.maxDecodeLongEdge = imageThumbLongEdge,
  });

  final List<ReplyImage> images;
  final ValueChanged<String>? onImageLongPress;
  final double singleImageSize;
  final double multiImageSize;
  final int maxDecodeLongEdge;

  @override
  Widget build(BuildContext context) {
    final validImages = images.where(hasAnyImageUrl).toList(growable: false);
    if (validImages.isEmpty) return const SizedBox.shrink();

    final imageUrls = validImages
        .map((image) => ApiConstants.fullUrl(_actionUrlFor(image)))
        .toList(growable: false);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(validImages.length, (index) {
        final image = validImages[index];
        final maxSize =
            validImages.length == 1 ? singleImageSize : multiImageSize;
        final displaySize = _displaySize(image, maxSize);
        return GestureDetector(
          key: ValueKey('reply-image-${image.replyId}-${image.id}'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImageViewerScreen(
                items: validImages.map(viewerItemFor).toList(growable: false),
                initialIndex: index,
              ),
            ),
          ),
          onLongPress: onImageLongPress == null
              ? null
              : () => onImageLongPress!(imageUrls[index]),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: _networkImage(
              image: image,
              target: calculateImageDecodeTarget(
                logicalSize: displaySize,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                maxLongEdge: maxDecodeLongEdge,
                fallbackLogicalSize: displaySize,
              ),
              width: displaySize.width,
              height: displaySize.height,
            ),
          ),
        );
      }),
    );
  }

  static ImageResourceSelection resourceForReplyImage(
    ReplyImage image,
    ImageDecodeTarget target,
  ) {
    final originUrl = ApiConstants.fullUrl(image.resolvedOriginUrl);
    final mimeType = image.file?.mimeType.toLowerCase() ?? '';
    final isAnimatedGif = mimeType == 'image/gif' ||
        originUrl.toLowerCase().split('?').first.endsWith('.gif');
    final originalSizeBytes = image.file?.size ?? 0;
    final hasVariantStatus = image.variantStatus.isNotEmpty;
    return selectImageResource(
      target: target,
      thumbUrl: ApiConstants.fullUrl(image.resolvedThumbUrl),
      mediumUrl: ApiConstants.fullUrl(image.resolvedMediumUrl),
      viewerUrl: ApiConstants.fullUrl(image.resolvedViewerUrl),
      originUrl: originUrl,
      isAnimatedGif: isAnimatedGif,
      thumbReady: image.isVariantReady('thumb'),
      mediumReady: image.isVariantReady('medium'),
      viewerReady: image.isVariantReady('viewer'),
      allowOriginFallback: !hasVariantStatus ||
          (originalSizeBytes > 0 &&
              originalSizeBytes < imageOriginalAutoLoadThresholdBytes),
      allowStaticAnimatedPreview: true,
    );
  }

  /// 兼容异常或过渡接口：即使原图字段暂时缺失，只要服务端返回了可展示
  /// 的变体，也应保留图片占位和查看入口，而不是把整条回复静默过滤掉。
  static bool hasAnyImageUrl(ReplyImage image) {
    return image.resolvedOriginUrl.trim().isNotEmpty ||
        image.resolvedViewerUrl.trim().isNotEmpty ||
        image.resolvedMediumUrl.trim().isNotEmpty ||
        image.resolvedThumbUrl.trim().isNotEmpty;
  }

  static String _actionUrlFor(ReplyImage image) {
    final candidates = <String>[
      image.resolvedOriginUrl,
      image.resolvedViewerUrl,
      image.resolvedMediumUrl,
      image.resolvedThumbUrl,
    ];
    return candidates.firstWhere(
      (url) => url.trim().isNotEmpty,
      orElse: () => '',
    );
  }

  static ImageViewerItem viewerItemFor(ReplyImage image) {
    final originUrl = ApiConstants.fullUrl(image.resolvedOriginUrl);
    final originalSizeBytes = image.file?.size ?? 0;
    return ImageViewerItem(
      thumbUrl: _readyVariantUrl(
        image,
        image.resolvedThumbUrl,
        originUrl,
        'thumb',
      ),
      previewUrl: _readyVariantUrl(
        image,
        image.resolvedMediumUrl,
        originUrl,
        'medium',
      ),
      viewerUrl: _readyVariantUrl(
        image,
        image.resolvedViewerUrl,
        originUrl,
        'viewer',
      ),
      originalUrl: originUrl,
      originalSizeBytes: originalSizeBytes,
      width: image.file?.width ?? 0,
      height: image.file?.height ?? 0,
      mimeType: image.file?.mimeType ?? '',
      useProgressiveLoading: true,
      // 旧回复可能没有变体状态，或图片本身小于自动加载阈值；此时列表
      // 已经可以安全使用原图，查看器也不能因过滤 origin 而进入空白页。
      allowOriginalPreviewFallback: image.variantStatus.isEmpty ||
          (originalSizeBytes > 0 &&
              originalSizeBytes < imageOriginalAutoLoadThresholdBytes),
    );
  }

  static Widget _networkImage({
    required ReplyImage image,
    required ImageDecodeTarget target,
    required double width,
    required double height,
  }) {
    final selection = resourceForReplyImage(image, target);
    if (selection.url.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: const Icon(Icons.broken_image_outlined),
      );
    }
    return CachedNetworkImage(
      cacheManager: PostImageCache.manager,
      imageUrl: selection.url,
      width: width,
      height: height,
      // 回复图片按原始比例显示，避免固定瓦片把竖图裁掉后看起来像被挤压。
      fit: BoxFit.contain,
      memCacheWidth: selection.shouldResize ? target.width : null,
      memCacheHeight: selection.shouldResize ? target.height : null,
      placeholder: (_, __) => SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(color: Color(0xFFEDEEF0)),
      ),
      errorWidget: (_, __, ___) => SizedBox(
        width: width,
        height: height,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }

  static String? _readyVariantUrl(
    ReplyImage image,
    String rawUrl,
    String originUrl,
    String variant,
  ) {
    final url = ApiConstants.fullUrl(rawUrl);
    if (url.isEmpty || url == originUrl || !image.isVariantReady(variant)) {
      return null;
    }
    return url;
  }

  static Size _displaySize(ReplyImage image, double maxSize) {
    final width = image.file?.width ?? 0;
    final height = image.file?.height ?? 0;
    if (width <= 0 || height <= 0) return Size.square(maxSize);
    final scale = maxSize / (width > height ? width : height);
    return Size(width * scale, height * scale);
  }
}
