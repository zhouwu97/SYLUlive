import 'dart:io' show File;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';

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
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundLayer(themeProvider, isDark),
        widget.child,
      ],
    );
  }

  Widget _buildBackgroundLayer(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.shouldShowCustomBackground) {
      return _buildBackgroundImageLayer(themeProvider, isDark);
    }
    return _buildCleanBackground(isDark);
  }

  Widget _buildBackgroundImageLayer(ThemeProvider themeProvider, bool isDark) {
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
            _isUsingFallbackDirection(themeProvider);
    final imageProvider = isAsset
        ? AssetImage(resolvedPath) as ImageProvider
        : isLocalFile
            ? FileImage(File(bgPath)) as ImageProvider
            : NetworkImage(bgPath) as ImageProvider;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: imageProvider,
          alignment: alignment,
          isDark: isDark,
          fillScreen: fillScreen,
          blur: themeProvider.backgroundBlur,
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  bool _isUsingFallbackDirection(ThemeProvider themeProvider) {
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
  }) {
    Widget imageLayer;
    if (fillScreen) {
      imageLayer = Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        ),
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
            errorBuilder: (_, __, ___) => Container(
              color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
            ),
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
