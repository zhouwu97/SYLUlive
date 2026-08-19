import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../screens/image_viewer_screen.dart';
import '../../utils/post_image_cache.dart';

enum PostMediaVariant { feed, detail }

/// 所有帖子类型共用的图片布局与预览入口。
class PostMediaView extends StatelessWidget {
  const PostMediaView({
    super.key,
    required this.images,
    this.variant = PostMediaVariant.feed,
  });

  final List<PostImage> images;
  final PostMediaVariant variant;

  @override
  Widget build(BuildContext context) {
    final validImages = images
        .where((image) => image.resolvedOriginUrl.trim().isNotEmpty)
        .toList(growable: false);
    if (validImages.isEmpty) return const SizedBox.shrink();

    final displayUrls = validImages
        .map(
          (image) => ApiConstants.fullUrl(
            variant == PostMediaVariant.feed
                ? image.resolvedThumbUrl
                : image.resolvedMediumUrl,
          ),
        )
        .toList(growable: false);
    final previewUrls = validImages
        .map((image) => ApiConstants.fullUrl(image.resolvedOriginUrl))
        .toList(growable: false);

    if (displayUrls.length == 1) {
      return _SinglePostImage(
        url: displayUrls.first,
        variant: variant,
        onTap: () => _openPreview(context, previewUrls, 0),
      );
    }

    final Widget multiChild;
    if (displayUrls.length == 2) {
      multiChild = _twoImages(context, displayUrls, previewUrls);
    } else if (displayUrls.length == 3) {
      multiChild = _threeImages(context, displayUrls, previewUrls);
    } else {
      multiChild = _imageGrid(context, displayUrls, previewUrls);
    }

    if (variant == PostMediaVariant.feed) {
      final double maxWidth = displayUrls.length == 2
          ? 280.0
          : (displayUrls.length == 3 ? 280.0 : 290.0);
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
    List<String> urls,
    List<String> previewUrls,
  ) {
    return AspectRatio(
      aspectRatio: 2,
      child: Row(
        children: [
          Expanded(child: _tile(context, urls, previewUrls, 0)),
          const SizedBox(width: 4),
          Expanded(child: _tile(context, urls, previewUrls, 1)),
        ],
      ),
    );
  }

  Widget _threeImages(
    BuildContext context,
    List<String> urls,
    List<String> previewUrls,
  ) {
    return AspectRatio(
      aspectRatio: 1.18,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(context, urls, previewUrls, 0)),
                const SizedBox(width: 4),
                Expanded(child: _tile(context, urls, previewUrls, 1)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _tile(context, urls, previewUrls, 2)),
        ],
      ),
    );
  }

  Widget _imageGrid(
    BuildContext context,
    List<String> urls,
    List<String> previewUrls,
  ) {
    final visibleCount = urls.length.clamp(4, 6);
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
          final hiddenCount = urls.length - visibleCount;
          return Stack(
            fit: StackFit.expand,
            children: [
              _tile(context, urls, previewUrls, index),
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
    List<String> urls,
    List<String> previewUrls,
    int index,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openPreview(context, previewUrls, index),
        child: _networkImage(urls[index], fit: BoxFit.cover),
      ),
    );
  }

  static Widget _networkImage(String url, {required BoxFit fit}) {
    return CachedNetworkImage(
      cacheManager: PostImageCache.manager,
      imageUrl: url,
      width: double.infinity,
      height: double.infinity,
      fit: fit,
      placeholder: (_, __) => Container(color: Colors.grey[200]),
      errorWidget: (_, failedUrl, __) {
        Future.microtask(() => PostImageCache.manager.removeFile(failedUrl));
        return Container(
          color: Colors.grey[200],
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
        );
      },
    );
  }

  static void _openPreview(
    BuildContext context,
    List<String> urls,
    int initialIndex,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: urls,
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
    required this.url,
    required this.variant,
    required this.onTap,
  });

  final String url;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspectRatio();
  }

  @override
  void didUpdateWidget(covariant _SinglePostImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolveAspectRatio();
  }

  void _resolveAspectRatio() {
    _stream?.removeListener(_listener!);
    final provider = CachedNetworkImageProvider(
      widget.url,
      cacheManager: PostImageCache.manager,
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      if (!mounted || info.image.height == 0) return;
      setState(() => _aspectRatio = info.image.width / info.image.height);
    });
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageSize = calculateSinglePostImageSize(
          availableWidth: constraints.maxWidth,
          aspectRatio: _aspectRatio,
          variant: widget.variant,
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: ColoredBox(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white10
                    : const Color(0xFFF3F4F6),
                child: SizedBox(
                  key: const ValueKey('single-post-image-tap-target'),
                  width: imageSize.width,
                  height: imageSize.height,
                  child: PostMediaView._networkImage(
                    widget.url,
                    fit: BoxFit.cover,
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
