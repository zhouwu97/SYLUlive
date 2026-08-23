import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 商家状态图片：下架只改变客户端渲染，不修改服务端原图或文件记录。
class CanteenStatusImage extends StatelessWidget {
  final String imageUrl;
  final bool offline;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Widget Function(BuildContext, String)? placeholder;

  const CanteenStatusImage({
    super.key,
    required this.imageUrl,
    this.offline = false,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
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
    final child = CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      width: width,
      height: height,
      errorWidget: errorWidget,
      placeholder: placeholder,
    );
    if (!offline) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_grayscaleMatrix),
      child: child,
    );
  }
}
