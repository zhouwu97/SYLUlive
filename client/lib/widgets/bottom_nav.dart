import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import 'liquid_bottom_nav.dart';
export 'liquid_glass/bottom_nav_controller.dart';
export 'liquid_glass/liquid_glass_scene.dart';

/// 统一使用完整液态底栏，页面保留业务导航与鉴权。
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
  });
  final int currentIndex;
  final ValueNotifier<double> visualIndexListenable;
  final ValueChanged<int> onTap;
  final AuthProvider authProvider;
  final ValueChanged<int>? onNavigationCommitted;
  final ValueChanged<double>? onVisualPositionChanged;
  final VoidCallback? onInteractionStart;
  final Map<int, bool> badges;

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<ThemeProvider>();
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
    );
  }
}
