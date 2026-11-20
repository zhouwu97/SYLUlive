import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import 'liquid_bottom_nav.dart';
import 'floating_bottom_nav.dart';
import '../features/theme_pack/theme_manifest.dart';
import '../features/theme_pack/theme_navigation_images.dart';
export 'liquid_glass/bottom_nav_controller.dart';
export 'liquid_glass/liquid_glass_scene.dart';

/// 底栏和侧栏共用材质偏好、交互与业务导航回调。
class BottomNavWrapper extends StatelessWidget {
  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.visualIndexListenable,
    required this.onTap,
    required this.authProvider,
    this.onNavigationCommitted,
    this.onVisualPositionChanged,
    this.onInteractionStart,
    this.badges = const {},
    this.axis = Axis.horizontal,
  });
  final int currentIndex;
  final ValueNotifier<double> visualIndexListenable;
  final ValueChanged<int> onTap;
  final AuthProvider authProvider;
  final ValueChanged<int>? onNavigationCommitted;
  final ValueChanged<double>? onVisualPositionChanged;
  final VoidCallback? onInteractionStart;
  final Map<int, bool> badges;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<ThemeProvider>();
    final navigation = preferences.appearance.group(ThemeGroup.navigation);
    final images = themeNavigationImages(navigation);
    final original = navigation?['iconTint'] == 'original';
    if (preferences.bottomNavStyle != BottomNavStyle.liquidGlass ||
        preferences.bottomNavPerformanceMode == BottomNavPerformanceMode.off) {
      return FloatingBottomNav(
          currentIndex: currentIndex,
          onTap: onTap,
          badges: badges,
          axis: axis,
          docked: preferences.bottomNavStyle == BottomNavStyle.normal,
          themeImages: images,
          originalIcons: original);
    }
    return LiquidBottomNav(
      currentIndex: currentIndex,
      visualIndexListenable: visualIndexListenable,
      onTap: onTap,
      onNavigationCommitted: onNavigationCommitted,
      onInteractionStart: onInteractionStart,
      onVisualPositionChanged: onVisualPositionChanged,
      badges: badges,
      intensity: preferences.bottomNavAnimationIntensity,
      blur: preferences.bottomNavBlur,
      tint: preferences.bottomNavTint,
      shaderEnabled: preferences.bottomNavShaderEnabled,
      axis: axis,
      themeImages: images,
      originalIcons: original,
    );
  }
}
