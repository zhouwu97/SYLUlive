import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';

class _NavItemVisualState {
  const _NavItemVisualState({
    required this.color,
    required this.scale,
    required this.opacity,
    required this.fontWeight,
  });

  final Color color;
  final double scale;
  final double opacity;
  final FontWeight fontWeight;
}

class BottomNavWrapper extends StatelessWidget {
  final int currentIndex;
  final double visualIndex;
  final Function(int) onTap;
  final AuthProvider authProvider;

  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.visualIndex,
    required this.onTap,
    required this.authProvider,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    if (themeProvider.floatingNavBar) {
      return _buildFloatingNav(context, isDark);
    }

    return _buildBlurNav(context, isDark);
  }

  // 标准模式：毛玻璃底栏 紧贴底部 + 紧凑
  Widget _buildBlurNav(BuildContext context, bool isDark) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final primaryColor = Theme.of(context).primaryColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / 5;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  padding: EdgeInsets.only(
                    top: 2,
                    bottom: bottomSafe > 0 ? bottomSafe : 2,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? const Color(0xFF1A1A2E) : Colors.white)
                        .withValues(alpha: 0.85),
                    border: Border(
                      top: BorderSide(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.06),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 指示器位置由 HomeScreen 的连续进度统一驱动。
                      Positioned(
                        left: itemWidth * visualIndex,
                        width: itemWidth,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 48,
                            height: 44,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _labeledItem(
                            Icons.home_rounded,
                            '首页',
                            0,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _labeledItem(
                            Icons.storefront_rounded,
                            '集市',
                            1,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _labeledItem(
                            Icons.calendar_month_rounded,
                            '课表',
                            2,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _labeledItem(
                            Icons.apartment_rounded,
                            '校园',
                            3,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _labeledItem(
                            Icons.person_rounded,
                            '我',
                            4,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // 悬浮模式：连成一块的弧形 Dock
  Widget _buildFloatingNav(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1E2226).withValues(alpha: 0.86)
                    : Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFE2EFEA),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth / 5;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // 选中项的背景指示器
                      Positioned(
                        left: itemWidth * visualIndex,
                        width: itemWidth,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 56,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isDark 
                                  ? const Color(0xFF147C72).withValues(alpha: 0.2) 
                                  : const Color(0xFFEAF6F3),
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _iconOnly(
                            Icons.home_rounded,
                            0,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _iconOnly(
                            Icons.storefront_rounded,
                            1,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _iconOnly(
                            Icons.calendar_month_rounded,
                            2,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _iconOnly(
                            Icons.apartment_rounded,
                            3,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                          _iconOnly(
                            Icons.person_rounded,
                            4,
                            context,
                            primaryColor,
                            itemWidth,
                            visualIndex,
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 标准模式 Item（图标+文字）
  Widget _labeledItem(
    IconData icon,
    String label,
    int index,
    BuildContext context,
    Color primaryColor,
    double width,
    double visualIndex,
  ) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      primaryColor: primaryColor,
      visualIndex: visualIndex,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.scale(
                scale: visualState.scale,
                alignment: Alignment.center,
                child: Opacity(
                  opacity: visualState.opacity,
                  child: Icon(icon, color: visualState.color, size: 22),
                ),
              ),
              const SizedBox(height: 2),
              Opacity(
                opacity: visualState.opacity,
                child: Text(
                  label,
                  style: TextStyle(
                    color: visualState.color,
                    fontWeight: visualState.fontWeight,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 悬浮模式 Item（纯图标）
  Widget _iconOnly(
    IconData icon,
    int index,
    BuildContext context,
    Color primaryColor,
    double width,
    double visualIndex,
  ) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      primaryColor: primaryColor,
      visualIndex: visualIndex,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: SizedBox(
        width: width,
        height: 44,
        child: Center(
          child: Transform.scale(
            scale: visualState.scale,
            alignment: Alignment.center,
            child: Opacity(
              opacity: visualState.opacity,
              child: Icon(icon, color: visualState.color, size: 24),
            ),
          ),
        ),
      ),
    );
  }

  _NavItemVisualState _visualStateFor({
    required BuildContext context,
    required int index,
    required Color primaryColor,
    required double visualIndex,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
    final softenedT = Curves.easeOutCubic.transform(activeT);
    final inactiveColor = isDark ? Colors.white54 : Colors.grey;

    return _NavItemVisualState(
      color: Color.lerp(inactiveColor, const Color(0xFF147C72), softenedT)!,
      scale: 1.0 + 0.08 * softenedT,
      opacity: 0.72 + 0.28 * softenedT,
      fontWeight: softenedT > 0.55 ? FontWeight.w700 : FontWeight.w500,
    );
  }
}
