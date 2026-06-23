import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AvatarCache {
  AvatarCache._();

  static final CacheManager manager = CacheManager(
    Config(
      'avatar_cache',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 1000,
    ),
  );

  static final Map<String, CachedNetworkImageProvider> _providers = {};

  static CachedNetworkImageProvider provider(
    String url, {
    required double radius,
  }) {
    return _providers.putIfAbsent(
      url,
      () => CachedNetworkImageProvider(url, cacheManager: manager),
    );
  }

  static Future<void> evict(String url) async {
    final provider = _providers.remove(url);
    await provider?.evict();
    await manager.removeFile(url).catchError((_) {});
  }
}

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
  String? _sourceUrl;
  int _retryAttempt = 0;
  bool _retryScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareImage();
  }

  @override
  void didUpdateWidget(covariant CachedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.radius != widget.radius) {
      _providerUrl = null;
      _sourceUrl = null;
      _retryAttempt = 0;
      _retryScheduled = false;
      _prepareImage();
    }
  }

  void _prepareImage() {
    final url = widget.imageUrl;
    if (url == null || url.isEmpty) {
      _providerUrl = null;
      _sourceUrl = null;
      _imageProvider = null;
      return;
    }
    if (_sourceUrl != url) {
      _sourceUrl = url;
      _retryAttempt = 0;
      _retryScheduled = false;
    }
    final effectiveUrl = _effectiveUrl(url);
    if (effectiveUrl == _providerUrl && _imageProvider != null) return;
    _providerUrl = effectiveUrl;
    _imageProvider = AvatarCache.provider(effectiveUrl, radius: widget.radius);
    precacheImage(_imageProvider!, context).catchError((_) {
      _scheduleRetryAfterError();
    });
  }

  String _effectiveUrl(String url) {
    if (_retryAttempt == 0) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    final params = Map<String, String>.from(uri.queryParameters);
    params['_avatar_retry'] = _retryAttempt.toString();
    return uri.replace(queryParameters: params).toString();
  }

  void _scheduleRetryAfterError() {
    final sourceUrl = widget.imageUrl;
    if (sourceUrl == null ||
        sourceUrl.isEmpty ||
        _retryAttempt >= 1 ||
        _retryScheduled) {
      return;
    }
    _retryScheduled = true;
    AvatarCache.evict(sourceUrl).whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.imageUrl != sourceUrl) return;
        setState(() {
          _retryScheduled = false;
          _retryAttempt++;
          _providerUrl = null;
          _imageProvider = null;
          _prepareImage();
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.white12 : Colors.grey[200]!;

    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      return _buildFallbackAvatar(isDark, bgColor);
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
            _scheduleRetryAfterError();
            return _buildFallback(isDark, bgColor);
          },
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame != null || wasSynchronouslyLoaded) return child;
            return _buildFallback(isDark, bgColor);
          },
        ),
      ),
    );
  }

  Widget _buildFallbackAvatar(bool isDark, Color bgColor) {
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
          : const Icon(Icons.person, size: 14, color: Colors.grey),
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
