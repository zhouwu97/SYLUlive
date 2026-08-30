import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../screens/image_viewer_screen.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../utils/image_decode_size.dart';
import '../../utils/post_image_cache.dart';

enum PostMediaVariant { feed, homeFeed, sectionFeed, detail }

/// homeFeed/sectionFeed 单图统一预览规格：最大宽度、可用宽度系数、长图阈值（3:4）。
const double _kFeedImageMaxWidth = 250.0;
const double _kFeedImageWidthFactor = 0.70;
const double _kLongImageRatio = 0.75;

/// feed/detail 沿用历史长图阈值，行为保持不变。
const double _kLegacyLongImageRatio = 0.70;

/// 所有帖子类型共用的图片布局与预览入口。
class PostMediaView extends StatelessWidget {
  const PostMediaView({
    super.key,
    required this.images,
    this.variant = PostMediaVariant.feed,
    this.onTap,
  });

  final List<PostImage> images;
  final PostMediaVariant variant;

  /// 外层帖子卡片的主点击回调。为空时保留媒体自身的原图预览行为。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final validImages = images
        .where((image) => image.resolvedOriginUrl.trim().isNotEmpty)
        .toList(growable: false);
    if (validImages.isEmpty) return const SizedBox.shrink();

    if (validImages.length == 1) {
      return _SinglePostImage(
        image: validImages.first,
        variant: variant,
        onTap: onTap ?? () => _openPreview(context, validImages, 0),
      );
    }

    final Widget multiChild;
    if (validImages.length == 2) {
      multiChild = _twoImages(context, validImages, onTap);
    } else if (validImages.length == 3) {
      multiChild = _threeImages(context, validImages, onTap);
    } else if (validImages.length == 4) {
      multiChild = _fourImages(context, validImages, onTap);
    } else {
      multiChild = _imageGrid(context, validImages, onTap);
    }

    if (variant == PostMediaVariant.feed) {
      final double maxWidth = validImages.length == 2
          ? 280.0
          : (validImages.length == 3 ? 280.0 : 290.0);
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: maxWidth,
          child: multiChild,
        ),
      );
    }

    return multiChild;
  }

  Widget _twoImages(
    BuildContext context,
    List<PostImage> images,
    VoidCallback? onTap,
  ) {
    return AspectRatio(
      aspectRatio: 2,
      child: Row(
        children: [
          Expanded(child: _tile(context, images, 0, onTap)),
          const SizedBox(width: 4),
          Expanded(child: _tile(context, images, 1, onTap)),
        ],
      ),
    );
  }

  Widget _threeImages(
    BuildContext context,
    List<PostImage> images,
    VoidCallback? onTap,
  ) {
    return AspectRatio(
      aspectRatio: 3,
      child: Row(
        children: [
          Expanded(child: _tile(context, images, 0, onTap)),
          const SizedBox(width: 6),
          Expanded(child: _tile(context, images, 1, onTap)),
          const SizedBox(width: 6),
          Expanded(child: _tile(context, images, 2, onTap)),
        ],
      ),
    );
  }

  Widget _fourImages(
    BuildContext context,
    List<PostImage> images,
    VoidCallback? onTap,
  ) {
    return AspectRatio(
      aspectRatio: 1,
      child: GridView.builder(
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemCount: 4,
        itemBuilder: (context, index) => _tile(context, images, index, onTap),
      ),
    );
  }

  Widget _imageGrid(
    BuildContext context,
    List<PostImage> images,
    VoidCallback? onTap,
  ) {
    final visibleCount = images.length.clamp(5, 9);
    final rows = (visibleCount / 3).ceil();
    return AspectRatio(
      aspectRatio: rows == 1 ? 3 : 1.5,
      child: GridView.builder(
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: visibleCount,
        itemBuilder: (context, index) {
          final hiddenCount = images.length - visibleCount;
          return Stack(
            fit: StackFit.expand,
            children: [
              _tile(context, images, index, onTap),
              if (index == visibleCount - 1 && hiddenCount > 0)
                IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Text(
                        '+$hiddenCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    List<PostImage> images,
    int index,
    VoidCallback? onTap,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap ?? () => _openPreview(context, images, index),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final target = calculateImageDecodeTarget(
              logicalSize: Size(constraints.maxWidth, constraints.maxHeight),
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              maxLongEdge: imageThumbLongEdge,
              fallbackLogicalSize: const Size(120, 120),
            );
            final selection = _selectResource(images[index], target);
            return _networkImage(
              selection: selection,
              target: target,
              fit: BoxFit.cover,
              alignment: variant == PostMediaVariant.homeFeed ||
                      variant == PostMediaVariant.sectionFeed
                  ? Alignment.topCenter
                  : Alignment.center,
            );
          },
        ),
      ),
    );
  }

  static ImageResourceSelection _selectResource(
    PostImage image,
    ImageDecodeTarget target,
  ) {
    final originUrl = ApiConstants.fullUrl(image.resolvedOriginUrl);
    final mimeType = image.file?.mimeType.toLowerCase() ?? '';
    return selectImageResource(
      target: target,
      thumbUrl: ApiConstants.fullUrl(image.resolvedThumbUrl),
      mediumUrl: ApiConstants.fullUrl(image.resolvedMediumUrl),
      viewerUrl: ApiConstants.fullUrl(image.resolvedViewerUrl),
      originUrl: originUrl,
      isAnimatedGif: mimeType == 'image/gif' ||
          originUrl.toLowerCase().split('?').first.endsWith('.gif'),
    );
  }

  static Widget _networkImage({
    required ImageResourceSelection selection,
    required ImageDecodeTarget target,
    required BoxFit fit,
    Alignment alignment = Alignment.center,
  }) {
    return CachedNetworkImage(
      cacheManager: PostImageCache.manager,
      imageUrl: selection.url,
      width: double.infinity,
      height: double.infinity,
      fit: fit,
      alignment: alignment,
      memCacheWidth: selection.shouldResize ? target.width : null,
      memCacheHeight: selection.shouldResize ? target.height : null,
      placeholder: (_, __) => Container(color: Colors.grey[200]),
      errorWidget: (_, __, ___) {
        return Container(
          color: Colors.grey[200],
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
        );
      },
    );
  }

  /// 全屏预览显示优先使用 viewer 档（长边 2048），保存仍走原图。
  static void _openPreview(
    BuildContext context,
    List<PostImage> images,
    int initialIndex,
  ) {
    final displayUrls = <String>[];
    final downloadUrls = <String?>[];
    for (final image in images) {
      final originUrl = ApiConstants.fullUrl(image.resolvedOriginUrl);
      final viewerUrl = ApiConstants.fullUrl(image.resolvedViewerUrl);
      final mimeType = image.file?.mimeType.toLowerCase() ?? '';
      final isAnimatedGif = mimeType == 'image/gif' ||
          originUrl.toLowerCase().split('?').first.endsWith('.gif');
      displayUrls.add(
        !isAnimatedGif && viewerUrl.isNotEmpty && viewerUrl != originUrl
            ? viewerUrl
            : originUrl,
      );
      downloadUrls.add(originUrl);
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: displayUrls,
          downloadUrls: downloadUrls,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

@visibleForTesting
Size calculateSinglePostImageSize({
  required double availableWidth,
  required double aspectRatio,
  required PostMediaVariant variant,
}) {
  final safeAspectRatio = aspectRatio > 0 ? aspectRatio : 4 / 3;

  if (variant == PostMediaVariant.homeFeed ||
      variant == PostMediaVariant.sectionFeed) {
    // 单图统一预览宽度并完全保持原比例；长图（< 3:4）封顶为 3:4 竖向预览框，
    // 渲染层 cover + topCenter 露出顶部主体。
    final previewWidth = math.min(
      availableWidth * _kFeedImageWidthFactor,
      _kFeedImageMaxWidth,
    );
    if (safeAspectRatio < _kLongImageRatio) {
      return Size(previewWidth, previewWidth / _kLongImageRatio);
    }
    return Size(previewWidth, previewWidth / safeAspectRatio);
  }

  if (variant == PostMediaVariant.feed) {
    // 首页信息流限制单图尺寸，优先控制纵向占用：
    // 最大约 250dp 宽 / 220dp 高，并保持原图宽高比例。
    final clampedRatio = safeAspectRatio.clamp(0.55, 1.8);
    final maxWidth = math.min(availableWidth * 0.70, 250.0);
    const maxHeight = 220.0;

    double width;
    double height;

    if (clampedRatio >= 1.0) {
      width = maxWidth;
      height = width / clampedRatio;
      if (height > maxHeight) {
        height = maxHeight;
        width = height * clampedRatio;
      }
    } else {
      height = maxHeight;
      width = height * clampedRatio;
      if (width > maxWidth) {
        width = maxWidth;
        height = width / clampedRatio;
      }
    }

    final finalWidth = math.min(width, maxWidth);
    final finalHeight = math.min(height, maxHeight);

    final minWidth = math.min(90.0, maxWidth);
    final minHeight = math.min(90.0, finalHeight);

    return Size(
      finalWidth.clamp(minWidth, maxWidth),
      finalHeight.clamp(minHeight, maxHeight),
    );
  }

  final naturalHeight = availableWidth / safeAspectRatio;
  return Size(
    availableWidth,
    naturalHeight.clamp(220.0, 420.0).toDouble(),
  );
}

class _SinglePostImage extends StatefulWidget {
  const _SinglePostImage({
    required this.image,
    required this.variant,
    required this.onTap,
  });

  final PostImage image;
  final PostMediaVariant variant;
  final VoidCallback onTap;

  @override
  State<_SinglePostImage> createState() => _SinglePostImageState();
}

class _SinglePostImageState extends State<_SinglePostImage> {
  double _aspectRatio = 4 / 3;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _applyServerAspectRatio();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasServerDimensions) _resolveFallbackAspectRatio();
  }

  @override
  void didUpdateWidget(covariant _SinglePostImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasChanged =
        oldWidget.image.resolvedOriginUrl != widget.image.resolvedOriginUrl ||
            oldWidget.image.file?.width != widget.image.file?.width ||
            oldWidget.image.file?.height != widget.image.file?.height;
    if (!hasChanged) return;
    _aspectRatio = 4 / 3;
    _applyServerAspectRatio();
    if (!_hasServerDimensions) _resolveFallbackAspectRatio();
  }

  bool get _hasServerDimensions =>
      (widget.image.file?.width ?? 0) > 0 &&
      (widget.image.file?.height ?? 0) > 0;

  void _applyServerAspectRatio() {
    if (!_hasServerDimensions) return;
    _aspectRatio = widget.image.file!.width / widget.image.file!.height;
  }

  void _resolveFallbackAspectRatio() {
    _stream?.removeListener(_listener!);
    final screenSize = MediaQuery.sizeOf(context);
    final imageSize = calculateSinglePostImageSize(
      availableWidth: screenSize.width,
      aspectRatio: _aspectRatio,
      variant: widget.variant,
    );
    final target = calculateImageDecodeTarget(
      logicalSize: imageSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxLongEdge: imageMediumLongEdge,
      fallbackLogicalSize: const Size(250, 220),
    );
    final selection = PostMediaView._selectResource(widget.image, target);
    final provider = CachedNetworkImageProvider(
      selection.url,
      cacheManager: PostImageCache.manager,
    );
    final ImageProvider<Object> resolvedProvider = selection.shouldResize
        ? ResizeImage(
            provider,
            width: target.width,
            height: target.height,
            policy: ResizeImagePolicy.fit,
          ) as ImageProvider<Object>
        : provider as ImageProvider<Object>;
    final stream = resolvedProvider.resolve(
      createLocalImageConfiguration(context),
    );
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted || info.image.height == 0) return;
        final resolvedRatio = info.image.width / info.image.height;
        if ((resolvedRatio - _aspectRatio).abs() < 0.001) return;
        setState(() => _aspectRatio = resolvedRatio);
      },
      onError: (_, __) {},
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHomeSection = widget.variant == PostMediaVariant.homeFeed ||
        widget.variant == PostMediaVariant.sectionFeed;
    final longImageThreshold =
        isHomeSection ? _kLongImageRatio : _kLegacyLongImageRatio;
    final isLongImage = _aspectRatio < longImageThreshold;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final imageSize = calculateSinglePostImageSize(
          availableWidth: availableWidth,
          aspectRatio: _aspectRatio,
          variant: widget.variant,
        );
        // memCacheWidth/Height 走 ResizeImage 精确缩放，目标比例必须与原图一致，
        // 否则长图位图会先被压扁再进入预览框。
        final decodeLogicalSize = Size(
          imageSize.width,
          imageSize.width / _aspectRatio,
        );
        final target = calculateImageDecodeTarget(
          logicalSize: decodeLogicalSize,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          maxLongEdge: imageMediumLongEdge,
          fallbackLogicalSize: const Size(250, 220),
        );
        final selection = PostMediaView._selectResource(widget.image, target);
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: SizedBox(
                key: const ValueKey('single-post-image-tap-target'),
                width: imageSize.width,
                height: imageSize.height,
                child: ColoredBox(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white10
                      : const Color(0xFFF3F4F6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PostMediaView._networkImage(
                        selection: selection,
                        target: target,
                        // 普通图用 contain 兑现“不裁剪”契约；仅长图 cover 裁剪。
                        fit: isHomeSection && !isLongImage
                            ? BoxFit.contain
                            : BoxFit.cover,
                        alignment: isLongImage
                            ? Alignment.topCenter
                            : Alignment.center,
                      ),
                      if (isHomeSection && _aspectRatio < _kLongImageRatio)
                        Positioned(
                          right: AppSpacing.sm,
                          bottom: AppSpacing.sm,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs,
                                ),
                                child: Text(
                                  '长图',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
