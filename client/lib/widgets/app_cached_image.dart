import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/post_image_cache.dart';

/// 公开网络图片的统一入口：持久化缓存、占位和错误状态。
///
/// 私有图片必须使用 [AppCachedImage.private]，不得复用公开帖子缓存。
class AppCachedImage extends StatelessWidget {
  const AppCachedImage.public({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
  })  : cacheManager = null,
        httpHeaders = null,
        cacheKey = null,
        _isPrivate = false;

  factory AppCachedImage.private({
    Key? key,
    required String imageUrl,
    required BaseCacheManager cacheManager,
    required Map<String, String> httpHeaders,
    required String cacheKey,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    double? width,
    double? height,
    int? memCacheWidth,
    int? memCacheHeight,
    Widget Function(BuildContext, String)? placeholder,
    Widget Function(BuildContext, String, Object)? errorWidget,
  }) {
    if (identical(cacheManager, PostImageCache.manager)) {
      throw ArgumentError.value(
        cacheManager,
        'cacheManager',
        '私有图片不能使用公开帖子缓存',
      );
    }
    return AppCachedImage._private(
      key: key,
      imageUrl: imageUrl,
      cacheManager: cacheManager,
      httpHeaders: httpHeaders,
      cacheKey: cacheKey,
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }

  const AppCachedImage._private({
    super.key,
    required this.imageUrl,
    required BaseCacheManager this.cacheManager,
    required Map<String, String> this.httpHeaders,
    required String this.cacheKey,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
  }) : _isPrivate = true;

  final String imageUrl;
  final BaseCacheManager? cacheManager;
  final Map<String, String>? httpHeaders;
  final String? cacheKey;
  final bool _isPrivate;
  final BoxFit fit;
  final Alignment alignment;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl.trim();
    if (url.isEmpty) {
      return placeholder?.call(context, url) ?? _defaultPlaceholder(context);
    }

    return CachedNetworkImage(
      cacheManager: _isPrivate ? cacheManager! : PostImageCache.manager,
      imageUrl: url,
      httpHeaders: httpHeaders,
      cacheKey: cacheKey,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: placeholder ?? (_, __) => _defaultPlaceholder(context),
      errorWidget: (context, failedUrl, error) {
        return errorWidget?.call(context, failedUrl, error) ??
            _defaultError(context);
      },
    );
  }

  Widget _defaultPlaceholder(BuildContext context) {
    return const ColoredBox(
      color: Color(0x0F000000),
      child: Center(child: Icon(Icons.image_not_supported_outlined)),
    );
  }

  Widget _defaultError(BuildContext context) {
    return const ColoredBox(
      color: Color(0x14000000),
      child: Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}
