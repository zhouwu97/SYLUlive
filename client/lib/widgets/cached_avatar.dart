import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class _AvatarCacheManager extends CacheManager with ImageCacheManager {
  _AvatarCacheManager()
      : super(
          Config(
            'avatar_cache',
            stalePeriod: const Duration(days: 30),
            maxNrOfCacheObjects: 1000,
          ),
        );
}

class AvatarCache {
  AvatarCache._();

  static final BaseCacheManager manager = _AvatarCacheManager();

  static final Map<String, Map<int, CachedNetworkImageProvider>> _providers =
      {};

  static CachedNetworkImageProvider provider(
    String url, {
    required double radius,
    double devicePixelRatio = 1,
  }) {
    var targetSize = (radius * 2 * devicePixelRatio).round();
    if (targetSize < 1) targetSize = 1;
    if (targetSize > 512) targetSize = 512;

    final providersBySize = _providers.putIfAbsent(url, () => {});
    return providersBySize.putIfAbsent(
      targetSize,
      () => CachedNetworkImageProvider(
        url,
        cacheKey: url,
        cacheManager: manager,
        maxWidth: targetSize,
        maxHeight: targetSize,
      ),
    );
  }

  static Future<void> evict(String url) async {
    final providersBySize = _providers.remove(url);
    if (providersBySize != null) {
      await Future.wait(
        providersBySize.entries.map((entry) async {
          await entry.value.evict();
          await manager.removeFile('resized_w${entry.key}_h${entry.key}_$url');
        }),
      );
    }
    await manager.removeFile(url).catchError((_) {});
  }
}

/// 统一的头像组件：自动缓存 + 内存尺寸限制，弱网秒开
class CachedAvatar extends StatefulWidget {
  final String? imageUrl;
  final double radius;
  final String? fallbackText;
  final IconData? fallbackIcon;
  final Color? fallbackBackgroundColor;
  final Color? fallbackIconColor;

  const CachedAvatar({
    super.key,
    this.imageUrl,
    this.radius = 18,
    this.fallbackText,
    this.fallbackIcon,
    this.fallbackBackgroundColor,
    this.fallbackIconColor,
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
    _imageProvider = AvatarCache.provider(
      effectiveUrl,
      radius: widget.radius,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
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
    final bgColor = widget.fallbackBackgroundColor ??
        (isDark ? Colors.white12 : Colors.grey[200]!);

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
      child: _buildFallbackChild(isDark),
    );
  }

  Widget _buildFallback(bool isDark, Color bgColor) {
    return ColoredBox(
      color: bgColor,
      child: Center(child: _buildFallbackChild(isDark)),
    );
  }

  Widget _buildFallbackChild(bool isDark) {
    final iconColor = widget.fallbackIconColor ??
        (isDark ? Colors.white60 : Colors.grey[600]!);
    if (widget.fallbackIcon != null) {
      return Icon(
        widget.fallbackIcon,
        size: widget.radius * 1.05,
        color: iconColor,
      );
    }
    if (widget.fallbackText != null && widget.fallbackText!.isNotEmpty) {
      return Text(
        widget.fallbackText![0].toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: widget.radius * 0.6,
          color: iconColor,
        ),
      );
    }
    return Icon(Icons.person, size: widget.radius * 0.8, color: iconColor);
  }
}
