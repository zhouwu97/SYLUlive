import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 统一的头像组件：自动缓存 + 内存尺寸限制，弱网秒开
class CachedAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final String? fallbackText;

  const CachedAvatar({
    super.key,
    this.imageUrl,
    this.radius = 18,
    this.fallbackText,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.white12 : Colors.grey[200]!;

    if (imageUrl == null || imageUrl!.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bgColor,
        child: fallbackText != null && fallbackText!.isNotEmpty
            ? Text(
                fallbackText![0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: radius * 0.6,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              )
            : null,
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl!,
      memCacheWidth: (radius * 2 * 3).toInt(), // 3x 像素密度足够清晰
      memCacheHeight: (radius * 2 * 3).toInt(),
      maxWidthDiskCache: (radius * 2 * 2).toInt(),
      maxHeightDiskCache: (radius * 2 * 2).toInt(),
      fadeOutDuration: Duration.zero,
      fadeInDuration: Duration.zero,
      useOldImageOnUrlChange: true,
      imageBuilder: (context, imageProvider) => CircleAvatar(
        radius: radius,
        backgroundColor: bgColor,
        backgroundImage: imageProvider,
      ),
      placeholder: (context, url) => CircleAvatar(
        radius: radius,
        backgroundColor: bgColor,
        child: fallbackText != null && fallbackText!.isNotEmpty
            ? Text(
                fallbackText![0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: radius * 0.6,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              )
            : const Icon(Icons.person, size: 14, color: Colors.grey),
      ),
      errorWidget: (context, url, error) => CircleAvatar(
        radius: radius,
        backgroundColor: bgColor,
        child: fallbackText != null && fallbackText!.isNotEmpty
            ? Text(
                fallbackText![0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: radius * 0.6,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              )
            : const Icon(Icons.person, size: 14, color: Colors.grey),
      ),
    );
  }
}
