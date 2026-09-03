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
    return Stack(
      fit: StackFit.expand,
      children: [
        const CustomBackgroundLayer(),
        widget.child,
      ],
    );
  }
}

/// 页面级自定义背景层：与全局壳完全同一套壁纸 / 模糊 / 遮罩处理。
///
/// Navigator.push 出的二级路由盖在全局壳之上，需要自绘背景；
/// 之前各页各自拷贝实现，遮罩与模糊参数漂移导致磨砂观感不统一，
/// 统一收敛到本 widget。
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

  Widget _buildBackgroundImageLayer(BuildContext context,
      ThemeProvider themeProvider, bool isDark) {
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

  bool _isUsingFallbackDirection(
      BuildContext context, ThemeProvider themeProvider) {
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
