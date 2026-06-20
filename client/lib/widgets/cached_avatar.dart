import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 统一的头像组件：自动缓存 + 内存尺寸限制，弱网秒开
class CachedAvatar extends StatefulWidget {
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
  State<CachedAvatar> createState() => _CachedAvatarState();
}

class _CachedAvatarState extends State<CachedAvatar> {
  CachedNetworkImageProvider? _imageProvider;
  String? _providerUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareImage();
  }

  @override
  void didUpdateWidget(covariant CachedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _prepareImage();
    }
  }

  void _prepareImage() {
    final url = widget.imageUrl;
    if (url == null || url.isEmpty || url == _providerUrl) return;
    _providerUrl = url;
    _imageProvider = CachedNetworkImageProvider(
      url,
      maxWidth: (widget.radius * 2 * 3).toInt(),
      maxHeight: (widget.radius * 2 * 3).toInt(),
    );
    precacheImage(_imageProvider!, context).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.white12 : Colors.grey[200]!;

    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: bgColor,
        child: widget.fallbackText != null && widget.fallbackText!.isNotEmpty
            ? Text(
                widget.fallbackText![0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: widget.radius * 0.6,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              )
            : null,
      );
    }

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: bgColor,
      child: ClipOval(
        child: Image(
          image: _imageProvider!,
          width: widget.radius * 2,
          height: widget.radius * 2,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildFallback(isDark, bgColor),
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame != null || wasSynchronouslyLoaded) return child;
            return _buildFallback(isDark, bgColor);
          },
        ),
      ),
    );
  }

  Widget _buildFallback(bool isDark, Color bgColor) {
    return ColoredBox(
      color: bgColor,
      child: Center(
        child: widget.fallbackText != null && widget.fallbackText!.isNotEmpty
            ? Text(
                widget.fallbackText![0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: widget.radius * 0.6,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              )
            : const Icon(Icons.person, size: 14, color: Colors.grey),
      ),
    );
  }
}
