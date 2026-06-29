import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';

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

  // 悬浮模式：胶囊毛玻璃（纯图标）
  Widget _buildFloatingNav(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: EdgeInsets.only(
            top: 12,
            bottom: bottomSafe > 0 ? bottomSafe : 16,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(50),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 0,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.grey[900]! : Colors.white)
                        .withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(50),
                    border: Border.all(
                      color: isDark
                          ? Colors.white10
                          : Colors.black.withValues(alpha: 0.05),
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final itemWidth = constraints.maxWidth / 5;
                      return Stack(
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
                                width: 56,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: primaryColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(16),
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
        ),
      ],
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
    final inactiveColor = isDark ? Colors.white54 : Colors.grey;
    final color = Color.lerp(inactiveColor, primaryColor, activeT)!;
    final scale = 1.0 + 0.08 * activeT;
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
                scale: scale,
                alignment: Alignment.center,
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: activeT > 0.5 ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 10,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
    final inactiveColor = isDark ? Colors.white54 : Colors.grey;
    final color = Color.lerp(inactiveColor, primaryColor, activeT)!;
    final scale = 1.0 + 0.08 * activeT;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: SizedBox(
        width: width,
        height: 44,
        child: Center(
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 24),
          ),
        ),
      ),
    );
  }
}
