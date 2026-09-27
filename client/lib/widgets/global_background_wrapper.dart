import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../services/wallpaper_prefetch_service.dart';

final GlobalKey<BackgroundWrapperState> backgroundWrapperKey =
    GlobalKey<BackgroundWrapperState>();

class GlobalBackgroundWrapper extends StatefulWidget {
  final Widget child;

  const GlobalBackgroundWrapper({super.key, required this.child});

  @override
  State<GlobalBackgroundWrapper> createState() => BackgroundWrapperState();
}

class BackgroundWrapperState extends State<GlobalBackgroundWrapper> {
  String _currentScreen = 'shuitie';

  void updateScreen(String screen) {
    if (_currentScreen != screen && mounted) {
      setState(() => _currentScreen = screen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const CustomBackgroundLayer(),
        widget.child,
      ],
    );
  }
}

/// 页面级自定义背景层，与全局壳共享同一套壁纸、模糊和遮罩策略。
///
/// 二级路由覆盖全局壳时必须自行绘制背景；集中实现可避免不同页面的
/// 模糊半径、明暗遮罩与横竖屏回退出现漂移。
class CustomBackgroundLayer extends StatelessWidget {
  const CustomBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (themeProvider.shouldShowCustomBackground) {
      return _buildBackgroundImageLayer(context, themeProvider, isDark);
    }
    return _buildCleanBackground(isDark);
  }

  Widget _buildBackgroundImageLayer(
    BuildContext context,
    ThemeProvider themeProvider,
    bool isDark,
  ) {
    final bgPath = themeProvider.getCustomBackgroundImageFor(context);
    if (bgPath == null || bgPath.isEmpty) {
      return _buildCleanBackground(isDark);
    }

    final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
    final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
    final resolvedPath =
        isAsset ? ThemeProvider.resolveBundledAssetPath(bgPath) : bgPath;
    const alignment = Alignment.center;
    final fillScreen =
        themeProvider.getCustomBackgroundFillScreenFor(context) ||
            _isUsingFallbackDirection(context, themeProvider);
    final baseProvider = isAsset
        ? AssetImage(resolvedPath) as ImageProvider
        : isLocalFile
            ? FileImage(File(bgPath)) as ImageProvider
            : CachedNetworkImageProvider(bgPath) as ImageProvider;

    final targetSize =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final targetWidth = targetSize.width.round().clamp(100, 3840);
    final targetHeight = targetSize.height.round().clamp(100, 3840);

    final imageProvider = AspectPreservingResizeImage(
      baseProvider,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      fit: fillScreen ? BoxFit.cover : BoxFit.contain,
      maxDimension: WallpaperPrefetchService.maxDecodeDimension,
      maxDecodedPixels: WallpaperPrefetchService.maxDecodedPixels,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: imageProvider,
          alignment: alignment,
          isDark: isDark,
          fillScreen: fillScreen,
          blur: themeProvider.backgroundBlur,
          bgPath: isLocalFile ? bgPath : null,
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  bool _isUsingFallbackDirection(
    BuildContext context,
    ThemeProvider themeProvider,
  ) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return (isWide && !themeProvider.hasLandscapeBackground) ||
        (!isWide && !themeProvider.hasBackground);
  }

  Widget _buildBackgroundImage({
    required ImageProvider imageProvider,
    required Alignment alignment,
    required bool isDark,
    required bool fillScreen,
    required double blur,
    String? bgPath,
  }) {
    void handleDecodeError() {
      if (bgPath != null && bgPath.isNotEmpty) {
        try {
          final file = File(bgPath);
          if (file.existsSync()) {
            file.deleteSync();
            final marker = File('$bgPath.verified');
            if (marker.existsSync()) marker.deleteSync();
            debugPrint(
                '[Background] Evicted corrupted background file: $bgPath');
          }
        } catch (_) {}
      }
    }

    Widget imageLayer;
    if (fillScreen) {
      imageLayer = Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) {
          handleDecodeError();
          return Container(
            color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
          );
        },
      );
    } else {
      imageLayer = Stack(
        fit: StackFit.expand,
        children: [
          Image(
            image: imageProvider,
            fit: BoxFit.cover,
            alignment: alignment,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) {
              handleDecodeError();
              return Container(
                color:
                    isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
              );
            },
          ),
          Image(
            image: imageProvider,
            fit: BoxFit.contain,
            alignment: alignment,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ],
      );
    }

    final effectiveBlur = blur.clamp(0.0, 30.0);
    if (effectiveBlur <= 0.01) return imageLayer;

    final scale = 1.0 + effectiveBlur / 300.0;
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: effectiveBlur,
          sigmaY: effectiveBlur,
        ),
        child: Transform.scale(scale: scale, child: imageLayer),
      ),
    );
  }

  Widget _buildCleanBackground(bool isDark) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? kCleanWarmBackgroundDark : kCleanWarmBackgroundLight,
      ),
    );
  }
}

/// 预测性返回手势开关门控。
///
/// 当前由子页面按需拦截；保留统一壳，确保各入口使用同一返回策略。
class PredictiveBackGate extends StatelessWidget {
  final Widget child;

  const PredictiveBackGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}

@immutable
class AspectPreservingResizeImageKey {
  const AspectPreservingResizeImageKey(
    this.providerCacheKey,
    this.targetWidth,
    this.targetHeight,
    this.fit,
    this.maxDimension,
    this.maxDecodedPixels,
  );

  final Object providerCacheKey;
  final int targetWidth;
  final int targetHeight;
  final BoxFit fit;
  final int maxDimension;
  final int maxDecodedPixels;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AspectPreservingResizeImageKey) return false;
    return other.providerCacheKey == providerCacheKey &&
        other.targetWidth == targetWidth &&
        other.targetHeight == targetHeight &&
        other.fit == fit &&
        other.maxDimension == maxDimension &&
        other.maxDecodedPixels == maxDecodedPixels;
  }

  @override
  int get hashCode => Object.hash(
        providerCacheKey,
        targetWidth,
        targetHeight,
        fit,
        maxDimension,
        maxDecodedPixels,
      );
}

/// 保持原图宽高比的图片解码尺寸缩放器。
///
/// 相比默认的 [ResizeImage.resizeIfNeeded]（policy: exact），
/// 本类在 Cover 填满模式下保证解码尺寸不低于目标显示尺寸，且长宽比例恒定；
/// 在 Contain 包含模式下缩进目标矩形内，防止原图构图比例被硬性压缩拉伸。
class AspectPreservingResizeImage
    extends ImageProvider<AspectPreservingResizeImageKey> {
  const AspectPreservingResizeImage(
    this.imageProvider, {
    required this.targetWidth,
    required this.targetHeight,
    required this.fit,
    this.maxDimension = WallpaperPrefetchService.maxDecodeDimension,
    this.maxDecodedPixels = WallpaperPrefetchService.maxDecodedPixels,
  });

  final ImageProvider imageProvider;
  final int targetWidth;
  final int targetHeight;
  final BoxFit fit;
  final int maxDimension;
  final int maxDecodedPixels;

  static ui.TargetImageSize calculateTargetSize({
    required int intrinsicWidth,
    required int intrinsicHeight,
    required int targetWidth,
    required int targetHeight,
    required BoxFit fit,
    int maxDimension = WallpaperPrefetchService.maxDecodeDimension,
    int maxDecodedPixels = WallpaperPrefetchService.maxDecodedPixels,
  }) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return ui.TargetImageSize(width: targetWidth, height: targetHeight);
    }
    final intrinsicAspect = intrinsicWidth / intrinsicHeight;
    final targetAspect = targetWidth / targetHeight;

    int w;
    int h;

    if (fit == BoxFit.cover) {
      // 填满模式 (Cover)：必须完全覆盖目标尺寸，两边都不留黑边
      if (intrinsicAspect >= targetAspect) {
        // 原图比目标更宽（如横图放到竖屏）：以高度为准覆盖，宽度向外延伸
        h = math.min(intrinsicHeight, targetHeight);
        w = (h * intrinsicAspect).round();
      } else {
        // 原图比目标更窄（如竖图放到横屏）：以宽度为准覆盖，高度向外延伸
        w = math.min(intrinsicWidth, targetWidth);
        h = (w / intrinsicAspect).round();
      }
    } else {
      // 包含模式 (Contain)：完全缩进目标框内，完整显示整张图
      if (intrinsicAspect >= targetAspect) {
        // 原图比目标更宽：宽度受限在 targetWidth 内
        w = math.min(intrinsicWidth, targetWidth);
        h = (w / intrinsicAspect).round();
      } else {
        // 原图比目标更窄：高度受限在 targetHeight 内
        h = math.min(intrinsicHeight, targetHeight);
        w = (h * intrinsicAspect).round();
      }
    }

    // Cover 在常规图片上尽量保留覆盖目标的尺寸；极端宽高比仍必须服从
    // 像素预算，不能为了避免低清而把整张原图无界解码。
    var cappedWidth = w;
    var cappedHeight = h;
    if (cappedWidth > maxDimension) {
      cappedWidth = maxDimension;
      cappedHeight = (cappedWidth / intrinsicAspect).round();
    }
    if (cappedHeight > maxDimension) {
      cappedHeight = maxDimension;
      cappedWidth = (cappedHeight * intrinsicAspect).round();
    }
    final coverWouldUndersize = fit == BoxFit.cover &&
        (cappedWidth < targetWidth || cappedHeight < targetHeight);
    if (!coverWouldUndersize) {
      w = cappedWidth;
      h = cappedHeight;
    }

    if (w * h > maxDecodedPixels) {
      final scale = math.sqrt(maxDecodedPixels / (w * h));
      w = (w * scale).floor();
      h = (h * scale).floor();
    }

    w = math.max(1, w);
    h = math.max(1, h);

    return ui.TargetImageSize(width: w, height: h);
  }

  @override
  Future<AspectPreservingResizeImageKey> obtainKey(
      ImageConfiguration configuration) {
    Completer<AspectPreservingResizeImageKey>? completer;
    SynchronousFuture<AspectPreservingResizeImageKey>? result;
    imageProvider.obtainKey(configuration).then((Object key) {
      final targetKey = AspectPreservingResizeImageKey(
        key,
        targetWidth,
        targetHeight,
        fit,
        maxDimension,
        maxDecodedPixels,
      );
      if (completer == null) {
        result = SynchronousFuture<AspectPreservingResizeImageKey>(targetKey);
      } else {
        completer.complete(targetKey);
      }
    });
    if (result != null) {
      return result!;
    }
    completer = Completer<AspectPreservingResizeImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    AspectPreservingResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeResize(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'AspectPreservingResizeImage cannot be composed with another ImageProvider that applies getTargetSize.',
      );
      return decode(
        buffer,
        getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
          return calculateTargetSize(
            intrinsicWidth: intrinsicWidth,
            intrinsicHeight: intrinsicHeight,
            targetWidth: key.targetWidth,
            targetHeight: key.targetHeight,
            fit: key.fit,
            maxDimension: key.maxDimension,
            maxDecodedPixels: key.maxDecodedPixels,
          );
        },
      );
    }

    final completer = imageProvider.loadImage(
      key.providerCacheKey,
      decodeResize,
    );
    completer.addEphemeralErrorListener((exception, stackTrace) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
    });
    return completer;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AspectPreservingResizeImage) return false;
    return other.imageProvider == imageProvider &&
        other.targetWidth == targetWidth &&
        other.targetHeight == targetHeight &&
        other.fit == fit &&
        other.maxDimension == maxDimension &&
        other.maxDecodedPixels == maxDecodedPixels;
  }

  @override
  int get hashCode => Object.hash(
        imageProvider,
        targetWidth,
        targetHeight,
        fit,
        maxDimension,
        maxDecodedPixels,
      );
}
