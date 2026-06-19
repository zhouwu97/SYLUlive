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

  void _debugLog(String msg) {
    debugPrint('[CachedAvatar] ' + msg);
  }

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
      _debugLog('prepareImage: url=' + (url ?? 'null'));
      _debugLog('prepareImage: providerUrl=' + (_providerUrl ?? 'null') + ' radius=' + widget.radius.toString());
    if (url == null || url.isEmpty) {
      _debugLog('_prepareImage: url is null/empty, clearing provider');
      _imageProvider = null;
      _providerUrl = null;
      return;
    }
    if (url == _providerUrl) {
      _debugLog('_prepareImage: url unchanged, skipping');
      return;
    }
    _providerUrl = url;
      _debugLog('prepareImage: creating CachedNetworkImageProvider for url=' + url);
    _imageProvider = CachedNetworkImageProvider(
      url,
      maxWidth: (widget.radius * 2 * 3).toInt(),
      maxHeight: (widget.radius * 2 * 3).toInt(),
    );
    precacheImage(_imageProvider!, context).ignore();
  }

  @override
  Widget build(BuildContext context) {
    _debugLog('build: imageUrl=' + (widget.imageUrl ?? 'null'));
    _debugLog('build: hasProvider=' + (_imageProvider != null).toString() + ' providerUrl=' + (_providerUrl ?? 'null'));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.white12 : Colors.grey[200]!;

    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      _debugLog('build: showing fallback (empty url)');
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

    if (_imageProvider == null) {
      _debugLog('build: WARNING _imageProvider is null, calling _prepareImage');
      _prepareImage();
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
          errorBuilder: (_, __, ___) {
            _debugLog('build: image error, showing fallback');
            return _buildFallback(isDark, bgColor);
          },
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            final loaded = frame != null || wasSynchronouslyLoaded;
            if (loaded) {
              _debugLog('build: frame loaded, showing image');
              return child;
            }
            _debugLog('build: frame not yet loaded, showing fallback');
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
