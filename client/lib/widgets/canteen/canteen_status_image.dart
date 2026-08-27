import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../utils/canteen_image_url.dart';

/// 商家状态图片：下架只改变客户端渲染，不修改服务端原图或文件记录。
class CanteenStatusImage extends StatelessWidget {
  final String imageUrl;
  final bool offline;
  final BoxFit fit;
  final double? width;
  final double? height;
  /// 与 CachedNetworkImage 同名的解码尺寸参数；为空时按显示尺寸自动计算。
  final int? memCacheWidth;
  final int? memCacheHeight;
  final int? maxWidthDiskCache;
  // 保留字符串参数兼容现有调用点；新页面应使用 thumb/medium/original。
  final String? variant;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Widget Function(BuildContext, String)? placeholder;

  const CanteenStatusImage({
    super.key,
    required this.imageUrl,
    this.offline = false,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.maxWidthDiskCache,
    this.variant,
    this.errorWidget,
    this.placeholder,
  });

  static const _grayscaleMatrix = <double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  @override
  Widget build(BuildContext context) {
    final selectedVariant = variant == null
        ? CanteenImageVariant.original
        : CanteenImageVariant.fromName(variant!) ??
            CanteenImageVariant.original;
    final originalUrl = canteenImageUrl(
      imageUrl,
      variant: CanteenImageVariant.original,
    );
    final variantUrl = canteenImageUrl(imageUrl, variant: selectedVariant);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = memCacheWidth ??
        _decodeDimension(width, devicePixelRatio, selectedVariant);
    final decodeHeight = memCacheHeight ??
        _decodeDimension(height, devicePixelRatio, selectedVariant);
    final diskWidth = maxWidthDiskCache ?? _diskWidth(selectedVariant);
    final child = variantUrl.isEmpty
        ? _buildPlaceholder(context)
        : _buildNetworkImage(
            context,
            variantUrl,
            originalUrl: originalUrl,
            allowOriginalFallback: variantUrl != originalUrl,
            decodeWidth: decodeWidth,
            decodeHeight: decodeHeight,
            diskWidth: diskWidth,
          );
    if (!offline) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_grayscaleMatrix),
      child: child,
    );
  }

  Widget _buildNetworkImage(
    BuildContext context,
    String url, {
    required String originalUrl,
    required bool allowOriginalFallback,
    required int? decodeWidth,
    required int? decodeHeight,
    required int? diskWidth,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: decodeWidth,
      memCacheHeight: decodeHeight,
      maxWidthDiskCache: diskWidth,
      errorWidget: (context, failedUrl, error) {
        // 缩略图未生成或已被清理时回退原图，不能把整张卡片判定为无图。
        if (allowOriginalFallback && originalUrl.isNotEmpty) {
          return _buildNetworkImage(
            context,
            originalUrl,
            originalUrl: originalUrl,
            allowOriginalFallback: false,
            decodeWidth: decodeWidth,
            decodeHeight: decodeHeight,
            diskWidth: diskWidth,
          );
        }
        return errorWidget?.call(context, failedUrl, error) ??
            _buildPlaceholder(context);
      },
      placeholder: (context, _) =>
          placeholder?.call(context, url) ?? _buildPlaceholder(context),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return placeholder?.call(context, imageUrl) ??
        const ColoredBox(
          color: Color(0x14000000),
          child: Center(child: Icon(Icons.restaurant_rounded)),
        );
  }

  int? _decodeDimension(
    double? logicalDimension,
    double devicePixelRatio,
    CanteenImageVariant variant,
  ) {
    final variantLimit = _diskWidth(variant);
    if (logicalDimension == null || logicalDimension <= 0) {
      return variantLimit;
    }
    final pixels = (logicalDimension * devicePixelRatio).round();
    if (variantLimit == null) return pixels > 0 ? pixels : null;
    return pixels.clamp(1, variantLimit).toInt();
  }

  int? _diskWidth(CanteenImageVariant variant) => switch (variant) {
        CanteenImageVariant.thumb => 480,
        CanteenImageVariant.medium => 1280,
        CanteenImageVariant.original => null,
      };
}
